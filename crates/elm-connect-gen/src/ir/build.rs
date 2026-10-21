//! Building the IR from a descriptor pool: naming every type, resolving
//! every field's type, and reporting what has no Elm form.

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};

use prost_reflect::{
    DescriptorPool, DynamicMessage, EnumDescriptor, EnumValueDescriptor, FieldDescriptor,
    FileDescriptor, Kind, MessageDescriptor, MethodDescriptor, Value,
};

use super::comments::Comments;
use super::graph::strongly_connected;
use super::{
    Annotations, Cardinality, Doc, Enum, EnumValue, Field, FieldBehavior, HttpRule, HttpVerb,
    Idempotency, JsType, MapKey, Message, Method, ModuleName, Oneof, OneofVariant, Package,
    ScalarKind, Service, TypeName, TypeRef, WellKnown, Wrapper,
};
use super::{declaration, rename};
use crate::diagnostics::{Diagnostics, Problem, Referrer, Site, Spans, closest, tag};
use crate::naming::{self, NameError};
use crate::options::{Options, Spelling, Streaming};
use crate::route::{self, Route};

/// What a rename's help names in place of the proto element's full name.
const RENAME_PLACEHOLDER: &str = "<proto full name>";

/// The package whose types are well-known types, never generated.
const WELL_KNOWN_PACKAGE: &str = "google.protobuf";

/// Builds one [`Package`] per proto package declared by the files in
/// `generate` (protoc's `file_to_generate`: names as the pool knows them),
/// sorted by package name. Each is built in full, from every file of the
/// pool that declares it, so a package's module is the same whichever of
/// its files were asked for (design §3.1).
///
/// Every type those packages refer to must be in a generated package or be
/// a supported well-known type: a package with no file in `generate` is
/// not generated, and a reference to it is a diagnostic naming the ways to
/// add it (design §3.1, §3.8). Files of `google.protobuf` in `generate` are
/// skipped. Every method must be unary, and its request and response types
/// are held to the same rule.
///
/// On any error, returns every error found instead.
///
/// This is [`build_with`] under the default options, without its
/// warnings.
pub fn build(pool: &DescriptorPool, generate: &[&str]) -> Result<Vec<Package>, Diagnostics> {
    build_with(pool, generate, &Options::default()).map(|built| built.packages)
}

/// A built IR, and what building it warned about.
#[derive(Clone, Debug)]
pub struct Built {
    /// One package per proto package, as [`build`] gives them.
    pub packages: Vec<Package>,
    /// The warnings, in the order found: what `options` left out, and the
    /// module names that compile but put the application at risk.
    pub warnings: Diagnostics,
}

/// [`build`], under the options that shape the IR: `streaming=skip`
/// leaves streaming methods out of their services, each a warning, and
/// the rename map gives Elm names in place of derived ones, each checked
/// against what it renames (design §3.7), and `module_prefix` puts every
/// generated module inside it (design §3.1).
///
/// On any error, returns every error found instead.
pub fn build_with(
    pool: &DescriptorPool,
    generate: &[&str],
    options: &Options,
) -> Result<Built, Diagnostics> {
    build_with_imports(pool, generate, &[], options)
}

/// [`build_with`], and also the packages of the files in `imports`
/// (names as `pool` knows them), each built from those files alone rather
/// than from every file declaring it, unless a file in `generate` declares
/// it too: the CLI's `--include-imports`, which asks for the imports that
/// declare what the requested packages refer to, and not for the other
/// files of their packages (design §6).
///
/// On any error, returns every error found instead.
pub fn build_with_imports(
    pool: &DescriptorPool,
    generate: &[&str],
    imports: &[&str],
    options: &Options,
) -> Result<Built, Diagnostics> {
    let mut builder = Builder {
        streaming: options.streaming,
        spelling: options.spelling,
        ..Builder::default()
    };

    // Files are checked in the order asked for, then the rest of their
    // packages'.
    let mut asked = BTreeSet::new();
    let mut checked = BTreeSet::new();
    let mut requested = Vec::new();
    for &name in generate {
        if !asked.insert(name) {
            continue;
        }
        let Some(file) = pool.get_file_by_name(name) else {
            builder.diagnostics.push(Problem::unknown_file(name));
            continue;
        };
        if file.package_name() != WELL_KNOWN_PACKAGE {
            checked.insert(name.to_owned());
            builder.check_file(&file);
            requested.push(file);
        }
    }
    let mut by_package = whole_packages(pool, requested);
    let imported: Vec<FileDescriptor> = imports
        .iter()
        .filter_map(|&name| pool.get_file_by_name(name))
        .filter(|file| !by_package.contains_key(file.package_name()))
        .collect();
    for file in imported {
        let files = by_package
            .entry(file.package_name().to_owned())
            .or_default();
        if !files.iter().any(|f| f.name() == file.name()) {
            files.push(file);
            files.sort_by(|a, b| a.name().cmp(b.name()));
        }
    }
    builder.generated = by_package.keys().cloned().collect();
    for file in by_package.values().flatten() {
        if checked.insert(file.name().to_owned()) {
            builder.check_file(file);
        }
    }
    builder.check_renames(pool, &options.rename, &by_package);

    for (package, files) in &by_package {
        let module = match builder.renames.get(package) {
            Some(given) => ModuleName::parse(given).ok_or(NameError::EmptyPackage),
            None => naming::module_name(package),
        };
        // The prefix goes in front of every package module, a renamed one
        // too; service modules, inside their package's, follow.
        let module = match &options.module_prefix {
            Some(prefix) => module.map(|module| module.under(prefix)),
            None => module,
        };
        match module {
            Ok(module) => {
                let what = format!("package `{package}`");
                let origin = builder.origin(
                    &files[0],
                    &[],
                    tag::FILE_PACKAGE,
                    what,
                    Some(package.as_str()),
                );
                builder.claim_module(&module, origin, package);
                builder.modules.insert(package.clone(), module);
            }
            Err(NameError::InvalidSegment { segment }) => {
                let site = builder.site(&files[0], &[tag::FILE_PACKAGE], "this package".into());
                builder.diagnostics.push(Problem::invalid_module(
                    package,
                    &segment,
                    site,
                    &builder.spelling.rename(package),
                ));
            }
            Err(_) => {
                for file in files {
                    let site = Site {
                        file: file.name().to_owned(),
                        span: None,
                        label: String::new(),
                        within: Vec::new(),
                    };
                    builder.diagnostics.push(Problem::missing_package(site));
                }
            }
        }
    }

    for (package, files) in &by_package {
        if let Some(module) = builder.modules.get(package).cloned() {
            for file in files {
                builder.name_types(file, &module);
            }
        }
    }

    let mut packages = Vec::new();
    for (package, files) in &by_package {
        if let Some(module) = builder.modules.get(package).cloned() {
            packages.push(builder.package(package, &module, files));
        }
    }

    mark_cycles(&mut packages);
    builder.check_import_cycles(&by_package);
    if !builder.runtime_namespace.is_empty() {
        let modules: Vec<String> = builder.runtime_namespace.iter().cloned().collect();
        builder.diagnostics.push(Problem::runtime_namespace(
            &modules,
            builder.spelling.module_prefix(),
            &builder.spelling.rename("<package>"),
        ));
    }

    let (errors, warnings) = builder.diagnostics.split_warnings();
    assert!(
        !builder.unnamed_route || !errors.is_empty(),
        "internal error: a route named a field without an Elm name, and no problem reports it"
    );
    if errors.is_empty() {
        Ok(Built { packages, warnings })
    } else {
        Err(errors)
    }
}

/// The label of a problem `error` in the binding `binding` (the rule
/// itself at `index` 0, else its additional binding `index`), and the
/// literals that find what it is about in the rule's text (see
/// [`Site::within`]): the quoted path, `body`, `response_body` or custom
/// kind, or the binding's block.
fn route_literal(
    index: usize,
    binding: &HttpRule,
    error: &route::RouteError,
) -> (&'static str, Vec<String>) {
    use route::RouteError as E;
    // As the text format writes the string in double quotes, so that a
    // value with escapes (`"GET\r\n"`) is found as written.
    let quoted = |text: &str| {
        let mut out = String::from("\"");
        for c in text.chars() {
            match c {
                '\n' => out.push_str("\\n"),
                '\r' => out.push_str("\\r"),
                '\t' => out.push_str("\\t"),
                '"' => out.push_str("\\\""),
                '\\' => out.push_str("\\\\"),
                c if c.is_control() => out.push_str(&format!("\\{:03o}", u32::from(c))),
                c => out.push(c),
            }
        }
        out.push('"');
        out
    };
    let mut within = vec!["additional_bindings".to_owned(); index];
    let label = match error {
        E::NoPattern | E::QueryField { .. } => {
            if index == 0 {
                "in this rule"
            } else {
                "in this binding"
            }
        }
        E::NestedBindings => {
            within.push("additional_bindings".to_owned());
            "nested here"
        }
        E::CustomKind { kind, .. } => {
            within.extend(["kind".to_owned(), quoted(kind)]);
            "this kind"
        }
        E::Syntax { .. }
        | E::UnboundWildcard { .. }
        | E::PathField { .. }
        | E::PathFieldTwice { .. } => {
            let key = match &binding.verb {
                HttpVerb::Get => "get",
                HttpVerb::Put => "put",
                HttpVerb::Post => "post",
                HttpVerb::Delete => "delete",
                HttpVerb::Patch => "patch",
                HttpVerb::Custom(_) => "path",
            };
            within.extend([key.to_owned(), quoted(&binding.template)]);
            "this path"
        }
        E::BodyField { field, .. } => {
            within.extend(["body".to_owned(), quoted(field)]);
            "this body"
        }
        E::ResponseBodyField { field, .. } => {
            within.extend(["response_body".to_owned(), quoted(field)]);
            "this response body"
        }
    };
    (label, within)
}

/// The files of every package to generate, by package name, each
/// package's sorted by file name: the packages of `requested`, each with
/// every file of `pool` that declares it. Files without a package are not
/// one package: only the requested ones are taken, each reported as
/// missing its package.
fn whole_packages(
    pool: &DescriptorPool,
    requested: Vec<FileDescriptor>,
) -> BTreeMap<String, Vec<FileDescriptor>> {
    let mut by_package: BTreeMap<String, Vec<FileDescriptor>> = BTreeMap::new();
    for file in requested {
        by_package
            .entry(file.package_name().to_owned())
            .or_default()
            .push(file);
    }
    for file in pool.files() {
        let package = file.package_name();
        if package.is_empty() {
            continue;
        }
        if let Some(files) = by_package.get_mut(package)
            && !files.iter().any(|f| f.name() == file.name())
        {
            files.push(file);
        }
    }
    for files in by_package.values_mut() {
        files.sort_by(|a, b| a.name().cmp(b.name()));
    }
    by_package
}

/// A `services::unbound_method` problem for every method of `packages`
/// (built from `pool`) without a `google.api.http` rule, at the method's
/// name: what `unbound_methods=error` reports (design §4).
pub fn unbound_methods(
    pool: &DescriptorPool,
    packages: &[Package],
    spelling: Spelling,
) -> Diagnostics {
    let mut builder = Builder {
        spelling,
        ..Builder::default()
    };
    for service in packages.iter().flat_map(|package| &package.services) {
        let Some(descriptor) = pool.get_service_by_name(&service.proto_full_name) else {
            continue;
        };
        let file = descriptor.parent_file();
        for method in descriptor.methods() {
            let built = service
                .methods
                .iter()
                .find(|m| m.proto_name == method.name());
            if built.is_some_and(|built| built.http.is_none()) {
                let path = [method.path(), &[tag::METHOD_NAME]].concat();
                let site = builder.site(&file, &path, "no `google.api.http` rule".into());
                builder.diagnostics.push(Problem::unbound_method(
                    method.full_name(),
                    site,
                    builder.spelling,
                ));
            }
        }
    }
    builder.diagnostics
}

/// A proto element that claims an Elm name: what it is, for labels,
/// where its name is, and the proto full name a `rename` of which would
/// change the name it claims, if one would.
struct Origin {
    what: String,
    site: Site,
    proto: Option<String>,
    /// Whether this is a message's claim of its type or its record
    /// constructor, which share one name.
    record: bool,
    /// The Elm name the rename map gives `proto`, if it gives one, and the
    /// `rename` option's name as the reader writes it.
    given: Option<(String, &'static str)>,
}

impl Origin {
    /// Whether `name`, which this claims, is the one its rename gives:
    /// the name itself, or the last segments of a module name.
    fn renamed_to(&self, name: &str) -> bool {
        self.given.as_ref().is_some_and(|(given, _)| {
            name == given
                || name
                    .strip_suffix(given.as_str())
                    .is_some_and(|rest| rest.ends_with('.'))
        })
    }

    /// The label of this claim of `name`: "message `a.B` becomes `B`",
    /// or, when its rename gives the name, "... is renamed to `B` by
    /// `rename`". `and` labels the second claim of a clash.
    fn label(&self, name: &str, and: bool) -> String {
        match (&self.given, and) {
            (Some((_, option)), false) if self.renamed_to(name) => {
                format!("{} is renamed to `{name}` by {option}", self.what)
            }
            (Some((_, option)), true) if self.renamed_to(name) => {
                format!("and {} is renamed to it by {option}", self.what)
            }
            (_, false) => format!("{} becomes `{name}`", self.what),
            (_, true) => format!("and so does {}", self.what),
        }
    }
}

/// Two claims of one name: the first claimant's site and the new one's,
/// labelled, and the proto full name whose `rename` would part them, the
/// new one's if a rename of it would.
struct Clash {
    first: Site,
    second: Site,
    rename: Option<String>,
    /// The proto full name and Elm name of a claimant whose rename gave
    /// it the name, the new one's first.
    renamed: Option<(String, String)>,
}

/// The names claimed in one Elm namespace, and by whom first.
#[derive(Default)]
struct Namespace {
    claimed: HashMap<String, Origin>,
}

impl Namespace {
    /// Claims `name` for `origin`; `None` unless it clashes.
    fn claim(&mut self, name: &str, origin: Origin) -> Option<Clash> {
        match self.claimed.get(name) {
            Some(first) => {
                let renamed = [&origin, first]
                    .into_iter()
                    .find(|claim| claim.renamed_to(name))
                    .and_then(|claim| Some((claim.proto.clone()?, claim.given.clone()?.0)));
                Some(Clash {
                    first: Site {
                        label: first.label(name, false),
                        ..first.site.clone()
                    },
                    second: Site {
                        label: origin.label(name, true),
                        ..origin.site
                    },
                    rename: origin.proto.or_else(|| first.proto.clone()),
                    renamed,
                })
            }
            None => {
                self.claimed.insert(name.to_owned(), origin);
                None
            }
        }
    }
}

/// The value namespace of a service's module: every method's call and
/// descriptor, and which of the names are descriptors, so a clash names
/// what clashed.
#[derive(Default)]
struct ServiceValues {
    names: Namespace,
    descriptors: HashSet<String>,
}

/// A reference from a field to a generated type, for the
/// import-cycle graph.
struct Reference {
    from_package: String,
    to_package: String,
    site: Site,
}

#[derive(Default)]
struct Builder {
    diagnostics: Diagnostics,
    spans: HashMap<String, Spans>,
    /// The comments of each file, by file name.
    comments: HashMap<String, Comments>,
    modules: BTreeMap<String, ModuleName>,
    /// Every package being generated, whether or not it has a module name.
    generated: BTreeSet<String>,
    /// Every generated module name, a package's or a service's, so no two
    /// generated modules share one.
    module_names: Namespace,
    /// The first generated module name of each lowercase spelling, with
    /// the site that claimed it, so no two differ only in case.
    module_cases: HashMap<String, (String, Site)>,
    /// The generated modules in the runtime's namespaces, for the one
    /// warning that lists them.
    runtime_namespace: BTreeSet<String>,
    /// How the options are written, for the escapes a problem names.
    spelling: Spelling,
    types: HashMap<String, TypeName>,
    references: Vec<Reference>,
    /// What a streaming method gets.
    streaming: Streaming,
    /// The rename map's entries that name a generated element and suit it:
    /// Elm names by proto full name (an enum value's under its enum's).
    renames: HashMap<String, String>,
    /// Whether a route failed for a field without an Elm name, which only
    /// the field's own problem reports.
    unnamed_route: bool,
}

impl Builder {
    /// Checks every entry of `renames` against what it names among the
    /// packages of `by_package`, reporting those that name nothing
    /// generated or give a name it cannot take, and keeps the rest.
    fn check_renames(
        &mut self,
        pool: &DescriptorPool,
        renames: &BTreeMap<String, String>,
        by_package: &BTreeMap<String, Vec<FileDescriptor>>,
    ) {
        // The names a rename could take, gathered once a rename names
        // nothing, for its suggestion.
        let mut known: Option<Vec<String>> = None;
        for (proto, elm) in renames {
            let Some(target) = rename::resolve(pool, proto)
                .filter(|target| by_package.contains_key(&target.package))
            else {
                let known =
                    known.get_or_insert_with(|| rename::names(by_package.values().flatten()));
                let suggestion = closest(proto, known.iter().map(String::as_str));
                self.diagnostics
                    .push(Problem::unknown_rename(proto, suggestion.as_deref()));
                continue;
            };
            let what = target.role.what();
            let Some((becomes, rule)) = target.role.rule() else {
                let site = self.site(&target.file, &target.path, format!("{what} here"));
                self.diagnostics.push(Problem::rename_alias(proto, site));
                continue;
            };
            if target.role.accepts(elm) {
                self.renames.insert(proto.clone(), elm.clone());
            } else {
                let site = self.site(&target.file, &target.path, format!("{what} here"));
                self.diagnostics.push(Problem::invalid_rename(
                    proto, elm, what, becomes, rule, site,
                ));
            }
        }
    }

    /// The constructor of the value `value_name` of the enum
    /// `enum_full_name` (whose proto name is `enum_proto_name` and Elm name
    /// `enum_elm_name`): its rename, or the naming rule's.
    fn enum_constructor(
        &self,
        enum_full_name: &str,
        enum_elm_name: &str,
        enum_proto_name: &str,
        value_name: &str,
    ) -> String {
        match self.renames.get(&format!("{enum_full_name}.{value_name}")) {
            Some(given) => given.clone(),
            None => naming::enum_constructor(enum_elm_name, enum_proto_name, value_name),
        }
    }

    /// Reports `file` if it is not proto3, or if its name holds a control
    /// character, which the header of its package's module would carry.
    fn check_file(&mut self, file: &FileDescriptor) {
        if file.name().chars().any(char::is_control) {
            self.diagnostics.push(Problem::file_name(file.name()));
        }
        let syntax = file.file_descriptor_proto().syntax();
        if syntax != "proto3" {
            let syntax = if syntax.is_empty() { "proto2" } else { syntax };
            let site = self.site(file, &[tag::FILE_SYNTAX], format!("{syntax} here"));
            self.diagnostics
                .push(Problem::not_proto3(file.name(), syntax, site));
        }
    }

    /// A site at `path` in `file`, or at its parent element when the
    /// compiler recorded nothing for `path` itself.
    fn site(&mut self, file: &FileDescriptor, path: &[i32], label: String) -> Site {
        let spans = self
            .spans
            .entry(file.name().to_owned())
            .or_insert_with(|| Spans::new(file.file_descriptor_proto()));
        let span = spans
            .get(path)
            .or_else(|| path.split_last().and_then(|(_, parent)| spans.get(parent)));
        Site {
            file: file.name().to_owned(),
            span,
            label,
            within: Vec::new(),
        }
    }

    /// The doc of the element at `path` in `file`: its comment, with
    /// `declaration` and `deprecated`.
    fn doc(
        &mut self,
        file: &FileDescriptor,
        path: &[i32],
        declaration: String,
        deprecated: bool,
    ) -> Doc {
        let comments = self
            .comments
            .entry(file.name().to_owned())
            .or_insert_with(|| Comments::new(file.file_descriptor_proto()));
        Doc {
            comment: comments.get(path).map(str::to_owned),
            declaration,
            deprecated,
        }
    }

    /// The comment `file` gives its package: the leading comment of its
    /// `package` statement, or else of its `syntax` statement.
    fn package_comment(&mut self, file: &FileDescriptor) -> Option<String> {
        let comments = self
            .comments
            .entry(file.name().to_owned())
            .or_insert_with(|| Comments::new(file.file_descriptor_proto()));
        comments
            .leading(&[tag::FILE_PACKAGE])
            .or_else(|| comments.leading(&[tag::FILE_SYNTAX]))
            .map(str::to_owned)
    }

    /// The doc of `field`, a field or a oneof member of a message of
    /// `file`, deprecated as `annotations` say.
    fn field_doc(
        &mut self,
        file: &FileDescriptor,
        field: &FieldDescriptor,
        annotations: &Annotations,
    ) -> Doc {
        // The source records `json_name` where the proto sets it; without
        // source info, a JSON name other than protoc's default was set.
        let json_path = [field.path(), &[tag::FIELD_JSON_NAME]].concat();
        let explicit = self
            .spans
            .entry(file.name().to_owned())
            .or_insert_with(|| Spans::new(file.file_descriptor_proto()))
            .get(&json_path)
            .is_some()
            || field.json_name() != declaration::default_json_name(field.name());
        let line = declaration::field(field, explicit);
        self.doc(file, field.path(), line, annotations.deprecated)
    }

    fn origin(
        &mut self,
        file: &FileDescriptor,
        element: &[i32],
        name_tag: i32,
        what: String,
        proto: Option<&str>,
    ) -> Origin {
        let path = [element, &[name_tag]].concat();
        let site = self.site(file, &path, String::new());
        Origin {
            what,
            site,
            proto: proto.map(str::to_owned),
            record: false,
            given: proto
                .and_then(|proto| self.renames.get(proto))
                .map(|given| (given.clone(), self.spelling.rename_key())),
        }
    }

    /// The `rename` option for `proto`, written as the options are, with a
    /// placeholder for the Elm name; a placeholder for the proto name too
    /// when no proto element's rename would help.
    fn rename_of(&self, proto: Option<&str>) -> String {
        self.spelling.rename(proto.unwrap_or(RENAME_PLACEHOLDER))
    }

    /// The rename option that gave a clash's claimant its name, written
    /// as the reader wrote it, if one did.
    fn renamed_by(&self, renamed: Option<&(String, String)>) -> Option<String> {
        renamed.map(|(proto, elm)| self.spelling.rename_to(proto, elm))
    }

    /// Names every message and enum of `file`, so references can resolve
    /// before any message is built.
    fn name_types(&mut self, file: &FileDescriptor, module: &ModuleName) {
        let package = file.package_name().to_owned();
        let named = |builder: &mut Builder, full_name: &str, path: &[i32], name_tag: i32| {
            let nested: Vec<&str> = full_name
                .strip_prefix(&package)
                .map(|rest| rest.trim_start_matches('.'))
                .unwrap_or(full_name)
                .split('.')
                .collect();
            // A nested type's name follows its enclosing message's Elm
            // name, renamed or not, as an enum's constructors follow the
            // enum's; the enclosing message is named first.
            let enclosing = full_name
                .rsplit_once('.')
                .filter(|(parent, _)| *parent != package)
                .and_then(|(parent, last)| Some((builder.types.get(parent)?, last)));
            let name = match (builder.renames.get(full_name), enclosing) {
                (Some(given), _) => Ok(given.clone()),
                (None, Some((parent, last))) => Ok(naming::nested_type_name(&parent.name, last)),
                (None, None) => naming::type_name(&nested),
            };
            match name {
                Ok(name) => {
                    builder.types.insert(
                        full_name.to_owned(),
                        TypeName {
                            module: module.clone(),
                            name,
                            proto_full_name: full_name.to_owned(),
                        },
                    );
                }
                Err(error) => {
                    let converted = match error {
                        NameError::WrongStart { converted } => converted,
                        _ => String::new(),
                    };
                    let path = [path, &[name_tag]].concat();
                    let site = builder.site(file, &path, "this name".into());
                    builder.diagnostics.push(Problem::invalid_type(
                        full_name,
                        &converted,
                        site,
                        &builder.spelling.rename(full_name),
                    ));
                }
            }
        };
        for message in all_messages(file) {
            named(self, message.full_name(), message.path(), tag::MESSAGE_NAME);
        }
        for enumeration in all_enums(file) {
            named(
                self,
                enumeration.full_name(),
                enumeration.path(),
                tag::ENUM_NAME,
            );
        }
    }

    fn package(
        &mut self,
        proto_name: &str,
        module: &ModuleName,
        files: &[FileDescriptor],
    ) -> Package {
        let mut types = Namespace::default();
        let mut constructors = Namespace::default();
        let mut messages = Vec::new();
        let mut enums = Vec::new();

        for file in files {
            for enumeration in all_enums(file) {
                if let Some(built) =
                    self.enumeration(file, &enumeration, &mut types, &mut constructors)
                {
                    enums.push(built);
                }
            }
            for message in all_messages(file) {
                if let Some(built) = self.message(file, &message, &mut types, &mut constructors) {
                    messages.push(built);
                }
            }
        }

        let mut services = Vec::new();
        for file in files {
            for service in file.services() {
                let full_name = service.full_name();
                let service_module = match self.renames.get(full_name) {
                    Some(given) => {
                        let segments = [module.segments(), std::slice::from_ref(given)].concat();
                        ModuleName::new(segments).ok_or(NameError::Empty)
                    }
                    None => naming::service_module(module, service.name()),
                };
                let service_module = match service_module {
                    Ok(service_module) => {
                        let what = format!("service `{full_name}`");
                        let origin = self.origin(
                            file,
                            service.path(),
                            tag::SERVICE_NAME,
                            what,
                            Some(full_name),
                        );
                        self.claim_module(&service_module, origin, full_name);
                        Some(service_module)
                    }
                    Err(_) => {
                        let path = [service.path(), &[tag::SERVICE_NAME]].concat();
                        let site = self.site(file, &path, "this name".into());
                        self.diagnostics.push(Problem::invalid_service(
                            full_name,
                            site,
                            &self.spelling.rename(full_name),
                        ));
                        None
                    }
                };
                let mut values = ServiceValues::default();
                let mut methods = Vec::new();
                for method in service.methods() {
                    if let Some(built) = self.method(file, &method, &mut values) {
                        methods.push(built);
                    }
                }
                let deprecated = service
                    .service_descriptor_proto()
                    .options
                    .as_ref()
                    .is_some_and(|options| options.deprecated());
                let doc = self.doc(
                    file,
                    service.path(),
                    declaration::service(&service),
                    deprecated,
                );
                if let Some(module) = service_module {
                    services.push(Service {
                        proto_full_name: full_name.to_owned(),
                        module,
                        methods,
                        doc,
                    });
                }
            }
        }

        let mut comments = Vec::new();
        for file in files {
            if let Some(comment) = self.package_comment(file)
                && !comments.contains(&comment)
            {
                comments.push(comment);
            }
        }

        Package {
            proto_name: proto_name.to_owned(),
            module: module.clone(),
            files: files.iter().map(|file| file.name().to_owned()).collect(),
            comments,
            messages,
            enums,
            services,
        }
    }

    /// The routes of `rule`, the method's own binding first; `None` after
    /// reporting every problem in them, at the rule's option.
    fn routes(
        &mut self,
        file: &FileDescriptor,
        method: &MethodDescriptor,
        rule: &HttpRule,
    ) -> Option<Vec<Route>> {
        let full_name = method.full_name();
        let path = [
            method.path(),
            &[tag::METHOD_OPTIONS, tag::METHOD_OPTIONS_HTTP],
        ]
        .concat();
        let bindings = std::iter::once((rule, false)).chain(
            rule.additional_bindings
                .iter()
                .map(|binding| (binding, true)),
        );
        let mut routes = Vec::new();
        let mut failed = false;
        let name = |field: &FieldDescriptor| self.field_ref(field);
        let mut resolved = Vec::new();
        for (binding, nested) in bindings {
            resolved.push(route::resolve(
                binding,
                &method.input(),
                &method.output(),
                nested,
                &name,
            ));
        }
        for (index, resolved) in resolved.into_iter().enumerate() {
            match resolved {
                Ok(route) => routes.push(route),
                Err(errors) => {
                    failed = true;
                    // No problems: the route named a field without an Elm
                    // name, whose problem is the field's own.
                    self.unnamed_route |= errors.is_empty();
                    let what = match index {
                        0 => format!("The HTTP rule of `{full_name}`"),
                        n => format!("Additional binding {n} of `{full_name}`"),
                    };
                    let binding = match index {
                        0 => rule,
                        n => &rule.additional_bindings[n - 1],
                    };
                    for error in errors {
                        let (label, within) = route_literal(index, binding, &error);
                        let site = Site {
                            within,
                            ..self.site_within(file, &path, label.into())
                        };
                        self.diagnostics.push(Problem::route(&what, &error, site));
                    }
                }
            }
        }
        (!failed).then_some(routes)
    }

    /// A field of a generated message as generated code names its
    /// descriptor: its message's descriptor module and its value there
    /// ([`Builder::field_value`]). `None` for a field whose message or
    /// name was reported already.
    fn field_ref(&self, field: &FieldDescriptor) -> Option<route::FieldRef> {
        let message = field.parent_message();
        let ty = self.types.get(message.full_name())?;
        Some(route::FieldRef {
            module: naming::descriptor_module(&ty.module, &ty.name),
            name: self.field_value(field).ok()?,
        })
    }

    /// The Elm value of `field`'s descriptor in its message's descriptor
    /// module, as [`Builder::message`] declares it and a route names it: a
    /// oneof member's [`naming::member_value_name`], any other field's
    /// record field name, renamed or derived, as
    /// [`naming::field_value_name`] escapes it.
    fn field_value(&self, field: &FieldDescriptor) -> Result<String, NameError> {
        let member = field
            .containing_oneof()
            .is_some_and(|oneof| !oneof.is_synthetic());
        if member {
            return naming::member_value_name(field.name());
        }
        let elm_name = match self.renames.get(field.full_name()) {
            Some(given) => given.clone(),
            None => naming::field_name(field.name())?,
        };
        Ok(naming::field_value_name(&elm_name))
    }

    /// A site at `path` in `file`, or at the nearest enclosing element the
    /// compiler recorded a span for. Options written as one aggregate
    /// (`option (google.api.http) = { ... }`) are recorded as a whole, not
    /// field by field.
    fn site_within(&mut self, file: &FileDescriptor, path: &[i32], label: String) -> Site {
        let spans = self
            .spans
            .entry(file.name().to_owned())
            .or_insert_with(|| Spans::new(file.file_descriptor_proto()));
        let span = (1..=path.len())
            .rev()
            .find_map(|len| spans.get(&path[..len]));
        Site {
            file: file.name().to_owned(),
            span,
            label,
            within: Vec::new(),
        }
    }

    /// A unary method, named and with its types resolved; `None` after
    /// reporting why it has no Elm form. Its call's and its descriptor's
    /// Elm values are claimed in `values`, the namespace of its service's
    /// module.
    fn method(
        &mut self,
        file: &FileDescriptor,
        method: &MethodDescriptor,
        values: &mut ServiceValues,
    ) -> Option<Method> {
        let full_name = method.full_name();
        let path = method.path();
        let streaming = match (method.is_client_streaming(), method.is_server_streaming()) {
            (false, false) => None,
            (true, false) => Some(("client", tag::METHOD_CLIENT_STREAMING)),
            (false, true) => Some(("server", tag::METHOD_SERVER_STREAMING)),
            (true, true) => Some(("bidirectional", tag::METHOD_CLIENT_STREAMING)),
        };
        if let Some((which, stream_tag)) = streaming {
            let site = self.site(file, &[path, &[stream_tag]].concat(), "streams here".into());
            self.diagnostics.push(match self.streaming {
                Streaming::Error => Problem::streaming(full_name, which, site, self.spelling),
                Streaming::Skip => {
                    Problem::streaming_skipped(full_name, which, site, self.spelling)
                }
            });
            return None;
        }

        let input = self.resolve_type(
            file,
            &Referrer::Request(full_name.to_owned()),
            &[path, &[tag::METHOD_INPUT]].concat(),
            Kind::Message(method.input()),
        );
        let output = self.resolve_type(
            file,
            &Referrer::Response(full_name.to_owned()),
            &[path, &[tag::METHOD_OUTPUT]].concat(),
            Kind::Message(method.output()),
        );

        let elm_name = match self.renames.get(full_name) {
            Some(given) => Ok(given.clone()),
            None => naming::method_name(method.name()),
        };
        let elm_name = match elm_name {
            Ok(name) => name,
            Err(error) => {
                let converted = match error {
                    NameError::WrongStart { converted } => converted,
                    _ => String::new(),
                };
                let site = self.site(
                    file,
                    &[path, &[tag::METHOD_NAME]].concat(),
                    "this name".into(),
                );
                self.diagnostics.push(Problem::invalid_method(
                    full_name,
                    &converted,
                    site,
                    &self.spelling.rename(full_name),
                ));
                return None;
            }
        };
        let http = http_rule(method);
        let routes = match &http {
            Some(rule) => self.routes(file, method, rule)?,
            None => Vec::new(),
        };
        let deprecated = method
            .method_descriptor_proto()
            .options
            .as_ref()
            .is_some_and(|options| options.deprecated());
        let doc = self.doc(file, path, declaration::method(method), deprecated);
        let built = Method {
            proto_name: method.name().to_owned(),
            elm_name,
            input: input?,
            output: output?,
            idempotency: idempotency(method),
            http,
            routes,
            doc,
        };

        let service = method.parent_service();
        let what = format!("method `{full_name}`");
        let origin = self.origin(file, path, tag::METHOD_NAME, what, Some(full_name));
        if let Some(Clash {
            first,
            second,
            rename,
            renamed,
        }) = values.names.claim(&built.elm_name, origin)
        {
            let problem = if values.descriptors.contains(&built.elm_name) {
                Problem::descriptor_collision
            } else {
                Problem::value_collision
            };
            self.diagnostics.push(problem(
                service.full_name(),
                &built.elm_name,
                first,
                second,
                &self.rename_of(rename.as_deref()),
                self.renamed_by(renamed.as_ref()).as_deref(),
            ));
        } else {
            // A call that clashes with another call has a descriptor that
            // clashes with the other's too; that is one problem, reported.
            let descriptor = built.descriptor_name();
            let what = format!("the descriptor of method `{full_name}`");
            let origin = self.origin(file, path, tag::METHOD_NAME, what, Some(full_name));
            if let Some(Clash {
                first,
                second,
                rename,
                renamed,
            }) = values.names.claim(&descriptor, origin)
            {
                self.diagnostics.push(Problem::descriptor_collision(
                    service.full_name(),
                    &descriptor,
                    first,
                    second,
                    &self.rename_of(rename.as_deref()),
                    self.renamed_by(renamed.as_ref()).as_deref(),
                ));
            }
            values.descriptors.insert(descriptor);
        }
        Some(built)
    }

    /// Claims `module` for `origin`, the proto element `proto`: reported
    /// when it is a module the runtime or a package it depends on already
    /// has, when another generated module has it, or when another's name
    /// differs from it only in case, since its file is then the same file
    /// on a file system that ignores case. A module in the runtime's
    /// namespaces is noted for their warning, and one an application's
    /// elm/* package has is warned of.
    fn claim_module(&mut self, module: &ModuleName, origin: Origin, proto: &str) {
        let name = module.to_string();
        let escapes = format!(
            "{} or {}",
            self.spelling.rename(proto),
            self.spelling.module_prefix()
        );
        if let Some(owner) = naming::reserved_module(&name) {
            let site = Site {
                label: format!("{} becomes `{name}`", origin.what),
                ..origin.site
            };
            self.diagnostics.push(Problem::reserved_module(
                &origin.what,
                &name,
                owner,
                &escapes,
                site,
            ));
            return;
        }
        if naming::in_runtime_namespace(&name) {
            self.runtime_namespace.insert(name.clone());
        }
        if let Some(owner) = naming::shadowed_module(&name) {
            let site = Site {
                label: format!("{} becomes `{name}`", origin.what),
                ..origin.site.clone()
            };
            self.diagnostics.push(Problem::shadowing_module(
                &origin.what,
                &name,
                owner,
                &escapes,
                site,
            ));
        }
        let folded = name.to_lowercase();
        let other = self
            .module_cases
            .get(&folded)
            .filter(|(other, _)| *other != name)
            .cloned();
        if let Some((other, first)) = other {
            let second = Site {
                label: format!("and {} becomes `{name}`", origin.what),
                ..origin.site.clone()
            };
            self.diagnostics.push(Problem::module_case_collision(
                &other,
                &name,
                &self.spelling.rename(proto),
                (first, second),
            ));
        }
        let site = Site {
            label: format!("{} becomes `{name}`", origin.what),
            ..origin.site.clone()
        };
        self.module_cases
            .entry(folded)
            .or_insert((name.clone(), site));
        if let Some(Clash {
            first,
            second,
            rename,
            renamed,
        }) = self.module_names.claim(&name, origin)
        {
            self.diagnostics.push(Problem::module_collision(
                &name,
                first,
                second,
                &self.rename_of(rename.as_deref()),
                self.renamed_by(renamed.as_ref()).as_deref(),
            ));
        }
    }

    /// Claims the type `name` in its package's module; `false` after
    /// reporting that another type has it.
    fn claim_type(
        &mut self,
        types: &mut Namespace,
        package: &str,
        name: &str,
        origin: Origin,
    ) -> bool {
        // Two messages clash as record constructors too, which is the same
        // mistake: this problem says so, and [`Builder::message`] leaves
        // the constructors' clash unreported.
        let records = origin.record && types.claimed.get(name).is_some_and(|first| first.record);
        if let Some(Clash {
            first,
            second,
            rename,
            renamed,
        }) = types.claim(name, origin)
        {
            self.diagnostics.push(Problem::type_collision(
                package,
                name,
                first,
                second,
                &self.rename_of(rename.as_deref()),
                records,
                self.renamed_by(renamed.as_ref()).as_deref(),
            ));
            return false;
        }
        true
    }

    /// Claims the descriptor module of the type `full_name`, named `name`
    /// in its package's module, for `origin`. A type whose name another
    /// type of the package has was reported already, and claims nothing.
    fn claim_descriptor_module(&mut self, full_name: &str, name: &str, origin: Origin) {
        let Some(package) = self.types.get(full_name).map(|ty| ty.module.clone()) else {
            return;
        };
        let module = naming::descriptor_module(&package, name);
        self.claim_module(&module, origin, full_name);
    }

    /// Claims `name`, the Elm value of the descriptor of a field or oneof
    /// member of `message` in its descriptor module, for `origin`. The
    /// module also defines `descriptor` (claimed first, by the message)
    /// and [`naming::VERSION_VALUE`], which no field's value can be: a
    /// derived name ends in `_` only as an escape, and a rename never does.
    fn claim_field_value(
        &mut self,
        values: &mut Namespace,
        message: &str,
        name: &str,
        origin: Origin,
    ) {
        if let Some(Clash {
            first,
            second,
            rename,
            renamed,
        }) = values.claim(name, origin)
        {
            self.diagnostics.push(Problem::field_value_collision(
                message,
                name,
                first,
                second,
                &self.rename_of(rename.as_deref()),
                self.renamed_by(renamed.as_ref()).as_deref(),
            ));
        }
    }

    fn claim_constructor(
        &mut self,
        constructors: &mut Namespace,
        package: &str,
        name: &str,
        origin: Origin,
    ) {
        if let Some(Clash {
            first,
            second,
            rename,
            renamed,
        }) = constructors.claim(name, origin)
        {
            self.diagnostics.push(Problem::constructor_collision(
                package,
                name,
                first,
                second,
                &self.rename_of(rename.as_deref()),
                self.renamed_by(renamed.as_ref()).as_deref(),
            ));
        }
    }

    fn enumeration(
        &mut self,
        file: &FileDescriptor,
        enumeration: &EnumDescriptor,
        types: &mut Namespace,
        constructors: &mut Namespace,
    ) -> Option<Enum> {
        let elm_name = self.types.get(enumeration.full_name())?.name.clone();
        let package = file.package_name();
        let what = format!("enum `{}`", enumeration.full_name());
        let origin = self.origin(
            file,
            enumeration.path(),
            tag::ENUM_NAME,
            what.clone(),
            Some(enumeration.full_name()),
        );
        if self.claim_type(types, package, &elm_name, origin) {
            let origin = self.origin(
                file,
                enumeration.path(),
                tag::ENUM_NAME,
                what,
                Some(enumeration.full_name()),
            );
            self.claim_descriptor_module(enumeration.full_name(), &elm_name, origin);
        }

        let mut values: Vec<EnumValue> = Vec::new();
        let mut declared = Vec::new();
        let mut deprecated = Vec::new();
        let mut value_docs = Vec::new();
        for value in declared_values(enumeration) {
            declared.push(value.name().to_owned());
            let options = value.enum_value_descriptor_proto().options.as_ref();
            let is_deprecated = options.is_some_and(|options| options.deprecated());
            if is_deprecated {
                deprecated.push(value.name().to_owned());
            }
            let doc = self.doc(
                file,
                value.path(),
                declaration::enum_value(&value),
                is_deprecated,
            );
            value_docs.push((value.name().to_owned(), doc));
            // An alias joins the constructor of the first value with its
            // number and claims no name of its own.
            if let Some(first) = values.iter_mut().find(|v| v.number == value.number()) {
                first.aliases.push(value.name().to_owned());
                continue;
            }
            let elm_ctor = self.enum_constructor(
                enumeration.full_name(),
                &elm_name,
                enumeration.name(),
                value.name(),
            );
            let what = format!("enum value `{}`", value.name());
            let origin = self.origin(
                file,
                value.path(),
                tag::ENUM_VALUE_NAME,
                what,
                Some(&format!("{}.{}", enumeration.full_name(), value.name())),
            );
            self.claim_constructor(constructors, package, &elm_ctor, origin);
            values.push(EnumValue {
                proto_name: value.name().to_owned(),
                number: value.number(),
                elm_ctor,
                aliases: Vec::new(),
            });
        }
        let mut values = values.into_iter();
        // Proto3 compilers reject an enum whose first value is not 0.
        let full_name = enumeration.full_name();
        let proto_name = full_name
            .strip_prefix(package)
            .and_then(|name| name.strip_prefix('.'))
            .unwrap_or(full_name);
        let deprecated_enum = enumeration
            .enum_descriptor_proto()
            .options
            .as_ref()
            .is_some_and(|options| options.deprecated());
        let doc = self.doc(
            file,
            enumeration.path(),
            declaration::enumeration(enumeration),
            deprecated_enum,
        );
        Enum::new(
            full_name.to_owned(),
            proto_name.to_owned(),
            elm_name,
            values.next()?,
            values.collect(),
        )
        .map(|built| Enum {
            doc,
            ..built
                .with_declaration_order(declared)
                .with_deprecated(deprecated)
                .with_value_docs(value_docs)
        })
    }

    fn message(
        &mut self,
        file: &FileDescriptor,
        message: &MessageDescriptor,
        types: &mut Namespace,
        constructors: &mut Namespace,
    ) -> Option<Message> {
        let elm_name = self.types.get(message.full_name())?.name.clone();
        let package = file.package_name();
        let full_name = message.full_name();
        let what = format!("message `{full_name}`");
        let origin = Origin {
            record: true,
            ..self.origin(
                file,
                message.path(),
                tag::MESSAGE_NAME,
                what.clone(),
                Some(full_name),
            )
        };
        let typed = self.claim_type(types, package, &elm_name, origin);
        if typed {
            let origin = self.origin(
                file,
                message.path(),
                tag::MESSAGE_NAME,
                what.clone(),
                Some(full_name),
            );
            self.claim_descriptor_module(full_name, &elm_name, origin);
        }
        let origin = Origin {
            record: true,
            ..self.origin(
                file,
                message.path(),
                tag::MESSAGE_NAME,
                what,
                Some(full_name),
            )
        };
        let partner = constructors
            .claimed
            .get(&elm_name)
            .is_some_and(|first| first.record);
        if !typed && partner {
            // The other message's: the type's problem reported it.
            constructors.claim(&elm_name, origin);
        } else {
            self.claim_constructor(constructors, package, &elm_name, origin);
        }

        // The values of the message's descriptor module: its descriptor,
        // then one per field and oneof member. No field's value can be
        // `descriptor` (`naming::field_value_name`); claiming it keeps
        // that checked.
        let mut values = Namespace::default();
        let what = format!("the descriptor of message `{full_name}`");
        let origin = self.origin(file, message.path(), tag::MESSAGE_NAME, what, None);
        values.claim(naming::DESCRIPTOR_VALUE, origin);

        let mut record = Namespace::default();
        let mut fields = Vec::new();
        let mut oneofs = Vec::new();
        let mut oneofs_seen = BTreeSet::new();

        for field in declared_fields(message) {
            if let Some(oneof) = field
                .containing_oneof()
                .filter(|oneof| !oneof.is_synthetic())
            {
                if !oneofs_seen.insert(oneof.name().to_owned()) {
                    continue;
                }
                let Some(elm_field_name) =
                    self.field_name(file, message, oneof.name(), oneof.path(), tag::ONEOF_NAME)
                else {
                    continue;
                };
                let what = format!("oneof `{}`", oneof.name());
                let origin = self.origin(
                    file,
                    oneof.path(),
                    tag::ONEOF_NAME,
                    what,
                    Some(oneof.full_name()),
                );
                if let Some(Clash {
                    first,
                    second,
                    rename,
                    renamed,
                }) = record.claim(&elm_field_name, origin)
                {
                    self.diagnostics.push(Problem::field_collision(
                        full_name,
                        &elm_field_name,
                        first,
                        second,
                        &self.rename_of(rename.as_deref()),
                        self.renamed_by(renamed.as_ref()).as_deref(),
                    ));
                }

                // A renamed oneof's type is named from its new field name.
                let type_from = self
                    .renames
                    .get(oneof.full_name())
                    .map_or(oneof.name(), String::as_str);
                let elm_type_name = naming::oneof_type_name(&elm_name, type_from);
                let unset_ctor = naming::oneof_unset_constructor(&elm_type_name);
                let what = format!("oneof `{}` of `{full_name}`", oneof.name());
                let origin = self.origin(
                    file,
                    oneof.path(),
                    tag::ONEOF_NAME,
                    what.clone(),
                    Some(oneof.full_name()),
                );
                self.claim_type(types, package, &elm_type_name, origin);
                let origin = self.origin(
                    file,
                    oneof.path(),
                    tag::ONEOF_NAME,
                    format!("the unset case of {what}"),
                    Some(oneof.full_name()),
                );
                self.claim_constructor(constructors, package, &unset_ctor, origin);

                // prost-reflect lists a oneof's members in declaration
                // order, so the variants follow the file as the fields do.
                let mut variants = Vec::new();
                for member in oneof.fields() {
                    let elm_ctor = match self.renames.get(member.full_name()) {
                        Some(given) => given.clone(),
                        None => naming::oneof_variant_constructor(&elm_type_name, member.name()),
                    };
                    let what = format!("oneof field `{}` of `{full_name}`", member.name());
                    let origin = self.origin(
                        file,
                        member.path(),
                        tag::FIELD_NAME,
                        what,
                        Some(member.full_name()),
                    );
                    self.claim_constructor(constructors, package, &elm_ctor, origin);
                    let elm_name = match self.field_value(&member) {
                        Ok(name) => name,
                        Err(error) => {
                            let converted = match error {
                                NameError::WrongStart { converted } => converted,
                                _ => String::new(),
                            };
                            let path = [member.path(), &[tag::FIELD_NAME]].concat();
                            let site = self.site(file, &path, "this name".into());
                            self.diagnostics.push(Problem::invalid_member_value(
                                full_name,
                                member.name(),
                                &converted,
                                site,
                            ));
                            continue;
                        }
                    };
                    let what = format!("oneof field `{}`", member.name());
                    let origin = self.origin(file, member.path(), tag::FIELD_NAME, what, None);
                    self.claim_field_value(&mut values, full_name, &elm_name, origin);
                    if let Some(ty) = self.resolve(file, message, &member, member.kind()) {
                        let annotations = annotations(&member);
                        let doc = self.field_doc(file, &member, &annotations);
                        variants.push(OneofVariant {
                            proto_name: member.name().to_owned(),
                            json_name: member.json_name().to_owned(),
                            number: member.number(),
                            elm_ctor,
                            elm_name,
                            ty,
                            cyclic: false,
                            jstype: jstype(&member),
                            annotations,
                            doc,
                        });
                    }
                }
                let doc = self.doc(file, oneof.path(), declaration::oneof(&oneof), false);
                oneofs.push(Oneof {
                    proto_name: oneof.name().to_owned(),
                    elm_field_name,
                    elm_type_name,
                    unset_ctor,
                    position: fields.len(),
                    variants,
                    doc,
                });
                continue;
            }

            let Some(elm_field_name) =
                self.field_name(file, message, field.name(), field.path(), tag::FIELD_NAME)
            else {
                continue;
            };
            let what = format!("field `{}`", field.name());
            let origin = self.origin(
                file,
                field.path(),
                tag::FIELD_NAME,
                what.clone(),
                Some(field.full_name()),
            );
            if let Some(Clash {
                first,
                second,
                rename,
                renamed,
            }) = record.claim(&elm_field_name, origin)
            {
                self.diagnostics.push(Problem::field_collision(
                    full_name,
                    &elm_field_name,
                    first,
                    second,
                    &self.rename_of(rename.as_deref()),
                    self.renamed_by(renamed.as_ref()).as_deref(),
                ));
            } else {
                // Two record fields of one name were reported as such; their
                // descriptor values clash too, which is the same problem.
                // The record field's name was found, so its value is too.
                if let Ok(value) = self.field_value(&field) {
                    let origin = self.origin(
                        file,
                        field.path(),
                        tag::FIELD_NAME,
                        what,
                        Some(field.full_name()),
                    );
                    self.claim_field_value(&mut values, full_name, &value, origin);
                }
            }
            if let Some((cardinality, ty)) = self.field_type(file, message, &field) {
                let annotations = annotations(&field);
                let doc = self.field_doc(file, &field, &annotations);
                fields.push(Field {
                    proto_name: field.name().to_owned(),
                    json_name: field.json_name().to_owned(),
                    number: field.number(),
                    elm_name: elm_field_name,
                    cardinality,
                    ty,
                    cyclic: false,
                    jstype: jstype(&field),
                    annotations,
                    doc,
                });
            }
        }

        let deprecated = message
            .descriptor_proto()
            .options
            .as_ref()
            .is_some_and(|options| options.deprecated());
        let doc = self.doc(
            file,
            message.path(),
            declaration::message(message),
            deprecated,
        );
        Some(Message {
            proto_full_name: full_name.to_owned(),
            elm_name,
            fields,
            oneofs,
            wrapper: None,
            doc,
        })
    }

    /// The Elm record field name for a field or oneof, or `None` after
    /// reporting why there is none.
    fn field_name(
        &mut self,
        file: &FileDescriptor,
        message: &MessageDescriptor,
        proto_name: &str,
        element: &[i32],
        name_tag: i32,
    ) -> Option<String> {
        let renamed = self
            .renames
            .get(&format!("{}.{proto_name}", message.full_name()));
        let name = match renamed {
            Some(given) => Ok(given.clone()),
            None => naming::field_name(proto_name),
        };
        match name {
            Ok(name) => Some(name),
            Err(error) => {
                let converted = match error {
                    NameError::WrongStart { converted } => converted,
                    _ => String::new(),
                };
                let path = [element, &[name_tag]].concat();
                let site = self.site(file, &path, "this name".into());
                self.diagnostics.push(Problem::invalid_field(
                    message.full_name(),
                    proto_name,
                    &converted,
                    site,
                    &self
                        .spelling
                        .rename(&format!("{}.{proto_name}", message.full_name())),
                ));
                None
            }
        }
    }

    fn field_type(
        &mut self,
        file: &FileDescriptor,
        message: &MessageDescriptor,
        field: &FieldDescriptor,
    ) -> Option<(Cardinality, TypeRef)> {
        if field.is_map() {
            let Kind::Message(entry) = field.kind() else {
                return None;
            };
            let key_kind = entry.map_entry_key_field().kind();
            let key = map_key(&key_kind)?;
            let value = entry.map_entry_value_field();
            let ty = self.resolve(file, message, field, value.kind())?;
            return Some((Cardinality::Map(key), ty));
        }
        let cardinality = if field.is_list() {
            Cardinality::Repeated
        } else if field.field_descriptor_proto().proto3_optional() {
            Cardinality::Optional
        } else {
            Cardinality::Singular
        };
        let ty = self.resolve(file, message, field, field.kind())?;
        Some((cardinality, ty))
    }

    /// The type of `kind`, the value type of `field`; `None` after
    /// reporting why it has no Elm form.
    fn resolve(
        &mut self,
        file: &FileDescriptor,
        message: &MessageDescriptor,
        field: &FieldDescriptor,
        kind: Kind,
    ) -> Option<TypeRef> {
        let referrer = Referrer::Field {
            message: message.full_name().to_owned(),
            field: field.name().to_owned(),
        };
        let type_path = [field.path(), &[tag::FIELD_TYPE_NAME]].concat();
        self.resolve_type(file, &referrer, &type_path, kind)
    }

    /// The type of `kind`, which `referrer` refers to at `type_path` of
    /// `file`; `None` after reporting why it has no Elm form.
    fn resolve_type(
        &mut self,
        file: &FileDescriptor,
        referrer: &Referrer,
        type_path: &[i32],
        kind: Kind,
    ) -> Option<TypeRef> {
        // For an enum, its proto name and the name of its zero value.
        let (full_name, package, defining_file, enum_names) = match kind {
            Kind::Double => return Some(TypeRef::Scalar(ScalarKind::Double)),
            Kind::Float => return Some(TypeRef::Scalar(ScalarKind::Float)),
            Kind::Int32 => return Some(TypeRef::Scalar(ScalarKind::Int32)),
            Kind::Int64 => return Some(TypeRef::Scalar(ScalarKind::Int64)),
            Kind::Uint32 => return Some(TypeRef::Scalar(ScalarKind::UInt32)),
            Kind::Uint64 => return Some(TypeRef::Scalar(ScalarKind::UInt64)),
            Kind::Sint32 => return Some(TypeRef::Scalar(ScalarKind::SInt32)),
            Kind::Sint64 => return Some(TypeRef::Scalar(ScalarKind::SInt64)),
            Kind::Fixed32 => return Some(TypeRef::Scalar(ScalarKind::Fixed32)),
            Kind::Fixed64 => return Some(TypeRef::Scalar(ScalarKind::Fixed64)),
            Kind::Sfixed32 => return Some(TypeRef::Scalar(ScalarKind::SFixed32)),
            Kind::Sfixed64 => return Some(TypeRef::Scalar(ScalarKind::SFixed64)),
            Kind::Bool => return Some(TypeRef::Scalar(ScalarKind::Bool)),
            Kind::String => return Some(TypeRef::Scalar(ScalarKind::String)),
            Kind::Bytes => return Some(TypeRef::Scalar(ScalarKind::Bytes)),
            Kind::Message(target) => (
                target.full_name().to_owned(),
                target.package_name().to_owned(),
                target.parent_file().name().to_owned(),
                None,
            ),
            Kind::Enum(target) => {
                // Proto3 compilers reject an enum without values.
                let zero = declared_values(&target).first()?.name().to_owned();
                (
                    target.full_name().to_owned(),
                    target.package_name().to_owned(),
                    target.parent_file().name().to_owned(),
                    Some((target.name().to_owned(), zero)),
                )
            }
        };
        let is_message = enum_names.is_none();

        if package == WELL_KNOWN_PACKAGE {
            let name = full_name
                .strip_prefix("google.protobuf.")
                .unwrap_or(&full_name);
            if let Some(well_known) = WellKnown::from_name(name).filter(|_| is_message) {
                return Some(TypeRef::WellKnown(well_known));
            }
            let site = self.site(file, type_path, format!("`{full_name}` here"));
            self.diagnostics
                .push(Problem::unsupported_well_known(referrer, &full_name, site));
            return None;
        }

        if !self.generated.contains(&package) {
            let site = self.site(
                file,
                type_path,
                format!("`{package}` is not being generated"),
            );
            self.diagnostics.push(Problem::not_generated(
                referrer,
                &full_name,
                &package,
                &defining_file,
                site,
            ));
            return None;
        }

        // A type in a generated package with no name, or whose package has
        // no module name, was reported already.
        let name = self.types.get(&full_name)?.clone();
        let site = self.site(
            file,
            type_path,
            format!("`{}` refers to `{package}` here", file.package_name()),
        );
        self.references.push(Reference {
            from_package: file.package_name().to_owned(),
            to_package: package,
            site,
        });
        Some(match enum_names {
            None => TypeRef::Message(name),
            Some((enum_name, zero_value)) => TypeRef::Enum {
                zero_ctor: self.enum_constructor(&full_name, &name.name, &enum_name, &zero_value),
                name,
            },
        })
    }

    /// Reports every cycle of references between generated packages.
    fn check_import_cycles(&mut self, by_package: &BTreeMap<String, Vec<FileDescriptor>>) {
        let names: Vec<&String> = self.modules.keys().collect();
        let position: HashMap<&str, usize> = names
            .iter()
            .enumerate()
            .map(|(i, name)| (name.as_str(), i))
            .collect();
        let mut edges = vec![BTreeSet::new(); names.len()];
        let mut first_site: HashMap<(usize, usize), &Site> = HashMap::new();
        for reference in &self.references {
            let Some(&from) = position.get(reference.from_package.as_str()) else {
                continue;
            };
            let Some(&to) = position.get(reference.to_package.as_str()) else {
                continue;
            };
            if from != to {
                edges[from].insert(to);
                first_site.entry((from, to)).or_insert(&reference.site);
            }
        }
        let edges: Vec<Vec<usize>> = edges
            .into_iter()
            .map(|set| set.into_iter().collect())
            .collect();
        let mut components: Vec<Vec<usize>> = strongly_connected(&edges)
            .into_iter()
            .filter(|component| component.len() > 1)
            .collect();
        components.sort();
        let mut problems = Vec::new();
        for component in components {
            let cycle: Vec<(String, Vec<String>)> = component
                .iter()
                .map(|&i| {
                    let files = by_package[names[i]]
                        .iter()
                        .map(|file| file.name().to_owned())
                        .collect();
                    (names[i].clone(), files)
                })
                .collect();
            let sites = component
                .iter()
                .filter_map(|&from| {
                    edges[from]
                        .iter()
                        .find(|to| component.contains(to))
                        .and_then(|&to| first_site.get(&(from, to)))
                        .map(|&site| site.clone())
                })
                .collect();
            problems.push(Problem::import_cycle(&cycle, sites));
        }
        for problem in problems {
            self.diagnostics.push(problem);
        }
    }
}

/// Marks every cycle of message references (see the [`super`] invariants):
/// [`Field::cyclic`] and [`Message::wrapper`] from the cycles of record
/// fields, [`OneofVariant::cyclic`] from the cycles of all references.
fn mark_cycles(packages: &mut [Package]) {
    let mut index = HashMap::new();
    for package in packages.iter() {
        for message in &package.messages {
            let key = (package.module.clone(), message.elm_name.clone());
            let next = index.len();
            index.entry(key).or_insert(next);
        }
    }
    let target = |ty: &TypeRef| match ty {
        TypeRef::Message(name) => index
            .get(&(name.module.clone(), name.name.clone()))
            .copied(),
        _ => None,
    };
    let mut fields = vec![Vec::new(); index.len()];
    let mut all = vec![Vec::new(); index.len()];
    for package in packages.iter() {
        for message in &package.messages {
            let from = index[&(package.module.clone(), message.elm_name.clone())];
            for to in message.fields.iter().filter_map(|field| target(&field.ty)) {
                fields[from].push(to);
                all[from].push(to);
            }
            let members = message.oneofs.iter().flat_map(|oneof| &oneof.variants);
            all[from].extend(members.filter_map(|variant| target(&variant.ty)));
        }
    }
    let field_cycle = cycles(&fields);
    let any_cycle = cycles(&all);
    let closes = |cycle: &[Option<usize>], from: usize, to: Option<usize>| {
        to.is_some_and(|to| cycle[from].is_some() && cycle[from] == cycle[to])
    };
    for package in packages.iter_mut() {
        let module = package.module.clone();
        for message in &mut package.messages {
            let from = index[&(module.clone(), message.elm_name.clone())];
            if field_cycle[from].is_some() {
                message.wrapper = Some(Wrapper {
                    elm_name: naming::recursive_wrapper(&message.elm_name),
                });
            }
            for field in &mut message.fields {
                field.cyclic = closes(&field_cycle, from, target(&field.ty));
            }
            for variant in message
                .oneofs
                .iter_mut()
                .flat_map(|oneof| &mut oneof.variants)
            {
                variant.cyclic = closes(&any_cycle, from, target(&variant.ty));
            }
        }
    }
}

/// For each node of the graph, the strongly-connected component it shares
/// with a cycle, if it is on one: a component of several nodes, or one
/// node with an edge to itself.
fn cycles(edges: &[Vec<usize>]) -> Vec<Option<usize>> {
    let mut cycle = vec![None; edges.len()];
    for (id, component) in strongly_connected(edges).into_iter().enumerate() {
        let looped = component.len() > 1 || edges[component[0]].contains(&component[0]);
        if looped {
            for node in component {
                cycle[node] = Some(id);
            }
        }
    }
    cycle
}

/// Every message of `file`, nested ones included, an enclosing message
/// before its nested ones; map entries excluded.
fn all_messages(file: &FileDescriptor) -> Vec<MessageDescriptor> {
    fn walk(message: MessageDescriptor, out: &mut Vec<MessageDescriptor>) {
        if message.is_map_entry() {
            return;
        }
        let children: Vec<_> = message.child_messages().collect();
        out.push(message);
        for child in children {
            walk(child, out);
        }
    }
    let mut out = Vec::new();
    for message in file.messages() {
        walk(message, &mut out);
    }
    out
}

/// Every enum of `file`: top-level ones, then nested ones in the order of
/// [`all_messages`].
fn all_enums(file: &FileDescriptor) -> Vec<EnumDescriptor> {
    file.enums()
        .chain(
            all_messages(file)
                .iter()
                .flat_map(|message| message.child_enums()),
        )
        .collect()
}

/// The fields of `message` in declaration order, the order the `.proto`
/// file writes them in, oneof members among them. The record's fields
/// follow this order and its constructor is positional, so the order is
/// public API; it follows the file so the record reads beside the proto.
/// prost-reflect's `fields()` iterates in number order instead.
pub(crate) fn declared_fields(message: &MessageDescriptor) -> Vec<FieldDescriptor> {
    message
        .descriptor_proto()
        .field
        .iter()
        .filter_map(|field| message.get_field_by_name(field.name()))
        .collect()
}

/// The values of `enumeration` in declaration order, so the zero value
/// proto3 requires first is first. prost-reflect's `values()` iterates in
/// number order, which puts a negative value before it.
pub(super) fn declared_values(enumeration: &EnumDescriptor) -> Vec<EnumValueDescriptor> {
    enumeration
        .enum_descriptor_proto()
        .value
        .iter()
        .filter_map(|value| enumeration.get_value_by_name(value.name()))
        .collect()
}

/// The `idempotency_level` `method` declares.
fn idempotency(method: &MethodDescriptor) -> Idempotency {
    use prost_types::method_options::IdempotencyLevel;
    let level = method
        .method_descriptor_proto()
        .options
        .as_ref()
        .map(|options| options.idempotency_level());
    match level {
        Some(IdempotencyLevel::NoSideEffects) => Idempotency::NoSideEffects,
        Some(IdempotencyLevel::Idempotent) => Idempotency::Idempotent,
        Some(IdempotencyLevel::IdempotencyUnknown) | None => Idempotency::Unknown,
    }
}

/// The full name of the `google.api.field_behavior` extension of
/// `FieldOptions`.
const FIELD_BEHAVIOR_EXTENSION: &str = "google.api.field_behavior";

/// What `field`'s options say about it: its `google.api.field_behavior`
/// values and its `deprecated` option. The extension is read as
/// [`http_rule`] reads `google.api.http`: from the options as the pool
/// decoded them, so a pool without `google/api/field_behavior.proto` has no
/// behavior to find, and neither has a proto that does not import it.
/// The unspecified zero and numbers this release does not know are
/// dropped.
fn annotations(field: &FieldDescriptor) -> Annotations {
    let deprecated = field
        .field_descriptor_proto()
        .options
        .as_ref()
        .is_some_and(|options| options.deprecated());
    let behavior = field
        .parent_pool()
        .get_extension_by_name(FIELD_BEHAVIOR_EXTENSION)
        .filter(|extension| field.options().has_extension(extension))
        .map(
            |extension| match field.options().get_extension(&extension).as_ref() {
                Value::List(values) => values
                    .iter()
                    .filter_map(Value::as_enum_number)
                    .filter_map(FieldBehavior::from_number)
                    .collect(),
                _ => Vec::new(),
            },
        )
        .unwrap_or_default();
    Annotations {
        behavior,
        deprecated,
    }
}

/// The full name of the `google.api.http` extension of `MethodOptions`.
const HTTP_EXTENSION: &str = "google.api.http";

/// The `google.api.http` rule of `method`, if it has one. The extension is
/// read from the method's options as the pool decoded them, so the pool
/// must have kept extension options: protox keeps them, and a pool built
/// from a `FileDescriptorSet` keeps them only when decoded from its bytes
/// (`DescriptorPool::decode_file_descriptor_set`). A pool without
/// `google/api/annotations.proto` has no rule to find.
fn http_rule(method: &MethodDescriptor) -> Option<HttpRule> {
    let extension = method.parent_pool().get_extension_by_name(HTTP_EXTENSION)?;
    let options = method.options();
    if !options.has_extension(&extension) {
        return None;
    }
    let value = options.get_extension(&extension);
    let rule = value.as_message()?;
    Some(read_rule(rule))
}

/// An `HttpRule` message as the IR holds it. A rule whose `pattern` is
/// unset reads as a `get` of the empty template, which the route parser
/// rejects.
fn read_rule(rule: &DynamicMessage) -> HttpRule {
    let string = |name: &str| {
        rule.get_field_by_name(name)
            .and_then(|value| value.as_str().map(str::to_owned))
            .unwrap_or_default()
    };
    let set = |name: &str| rule.has_field_by_name(name);
    let mut verb = HttpVerb::Get;
    let mut template = String::new();
    for (name, candidate) in [
        ("get", HttpVerb::Get),
        ("put", HttpVerb::Put),
        ("post", HttpVerb::Post),
        ("delete", HttpVerb::Delete),
        ("patch", HttpVerb::Patch),
    ] {
        if set(name) {
            verb = candidate;
            template = string(name);
        }
    }
    if let Some(Value::Message(custom)) = set("custom")
        .then(|| rule.get_field_by_name("custom"))
        .flatten()
        .as_deref()
    {
        let text = |name: &str| {
            custom
                .get_field_by_name(name)
                .and_then(|value| value.as_str().map(str::to_owned))
                .unwrap_or_default()
        };
        verb = HttpVerb::Custom(text("kind"));
        template = text("path");
    }
    let additional_bindings = match rule.get_field_by_name("additional_bindings").as_deref() {
        Some(Value::List(bindings)) => bindings
            .iter()
            .filter_map(Value::as_message)
            .map(read_rule)
            .collect(),
        _ => Vec::new(),
    };
    HttpRule {
        verb,
        template,
        body: string("body"),
        response_body: string("response_body"),
        additional_bindings,
    }
}

/// The `jstype` option of `field` when its values are 64-bit integers;
/// [`JsType::Normal`] for any other field, where it means nothing.
fn jstype(field: &FieldDescriptor) -> JsType {
    use prost_types::field_options::JsType as Proto;
    let int64 = matches!(
        field.kind(),
        Kind::Int64 | Kind::Uint64 | Kind::Sint64 | Kind::Fixed64 | Kind::Sfixed64
    );
    let option = field
        .field_descriptor_proto()
        .options
        .as_ref()
        .map(|options| options.jstype());
    match option {
        Some(Proto::JsString) if int64 => JsType::String,
        Some(Proto::JsNumber) if int64 => JsType::Number,
        _ => JsType::Normal,
    }
}

fn map_key(kind: &Kind) -> Option<MapKey> {
    Some(match kind {
        Kind::Int32 => MapKey::Int32,
        Kind::Int64 => MapKey::Int64,
        Kind::Uint32 => MapKey::UInt32,
        Kind::Uint64 => MapKey::UInt64,
        Kind::Sint32 => MapKey::SInt32,
        Kind::Sint64 => MapKey::SInt64,
        Kind::Fixed32 => MapKey::Fixed32,
        Kind::Fixed64 => MapKey::Fixed64,
        Kind::Sfixed32 => MapKey::SFixed32,
        Kind::Sfixed64 => MapKey::SFixed64,
        Kind::String => MapKey::String,
        Kind::Bool => MapKey::Bool,
        _ => return None,
    })
}
