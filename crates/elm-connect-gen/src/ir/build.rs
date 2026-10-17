//! Building the IR from a descriptor pool: naming every type, resolving
//! every field's type, and reporting what has no Elm form.

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};

use prost_reflect::{
    DescriptorPool, DynamicMessage, EnumDescriptor, EnumValueDescriptor, FieldDescriptor,
    FileDescriptor, Kind, MessageDescriptor, MethodDescriptor, Value,
};

use super::graph::strongly_connected;
use super::rename;
use super::{
    Cardinality, Enum, EnumValue, Field, HttpRule, HttpVerb, JsType, MapKey, Message, Method,
    ModuleName, Oneof, OneofVariant, Package, ScalarKind, Service, TypeName, TypeRef, WellKnown,
    Wrapper,
};
use crate::diagnostics::{Diagnostics, Problem, Referrer, Site, Spans, tag};
use crate::naming::{self, NameError};
use crate::options::{Options, Spelling, Streaming};
use crate::route::{self, Route};

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
/// On any problem, returns every problem found instead.
///
/// This is [`build_with`] under the default options, which give no
/// warnings.
pub fn build(pool: &DescriptorPool, generate: &[&str]) -> Result<Vec<Package>, Diagnostics> {
    build_with(pool, generate, &Options::default()).map(|built| built.packages)
}

/// A built IR, and what building it warned about.
#[derive(Clone, Debug)]
pub struct Built {
    /// One package per proto package, as [`build`] gives them.
    pub packages: Vec<Package>,
    /// The warnings, in the order found: what `options` left out.
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
                let origin = builder.origin(&files[0], &[], tag::FILE_PACKAGE, what);
                builder.claim_module(&module, origin, package);
                builder.modules.insert(package.clone(), module);
            }
            Err(NameError::InvalidSegment { segment }) => {
                let site = builder.site(&files[0], &[tag::FILE_PACKAGE], "this package".into());
                builder
                    .diagnostics
                    .push(Problem::invalid_module(package, &segment, site));
            }
            Err(_) => {
                for file in files {
                    let site = Site {
                        file: file.name().to_owned(),
                        span: None,
                        label: String::new(),
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

    let (errors, warnings) = builder.diagnostics.split_warnings();
    if errors.is_empty() {
        Ok(Built { packages, warnings })
    } else {
        Err(errors)
    }
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
pub fn unbound_methods(pool: &DescriptorPool, packages: &[Package]) -> Diagnostics {
    let mut builder = Builder::default();
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
                builder
                    .diagnostics
                    .push(Problem::unbound_method(method.full_name(), site));
            }
        }
    }
    builder.diagnostics
}

/// A proto element that claims an Elm name: what it is, for labels, and
/// where its name is.
struct Origin {
    what: String,
    site: Site,
}

/// The names claimed in one Elm namespace, and by whom first.
#[derive(Default)]
struct Namespace {
    claimed: HashMap<String, Origin>,
}

impl Namespace {
    /// Claims `name` for `origin`; on a clash, the first claimant's site
    /// and the new one's, labelled.
    fn claim(&mut self, name: &str, origin: Origin) -> Option<(Site, Site)> {
        match self.claimed.get(name) {
            Some(first) => Some((
                Site {
                    label: format!("{} becomes `{name}`", first.what),
                    ..first.site.clone()
                },
                Site {
                    label: format!("and so does {}", origin.what),
                    ..origin.site
                },
            )),
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
    modules: BTreeMap<String, ModuleName>,
    /// Every package being generated, whether or not it has a module name.
    generated: BTreeSet<String>,
    /// Every generated module name, a package's or a service's, so no two
    /// generated modules share one.
    module_names: Namespace,
    /// The first generated module name of each lowercase spelling, with
    /// the site that claimed it, so no two differ only in case.
    module_cases: HashMap<String, (String, Site)>,
    /// How the options are written, for the escapes a problem names.
    spelling: Spelling,
    types: HashMap<String, TypeName>,
    references: Vec<Reference>,
    /// What a streaming method gets.
    streaming: Streaming,
    /// The rename map's entries that name a generated element and suit it:
    /// Elm names by proto full name (an enum value's under its enum's).
    renames: HashMap<String, String>,
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
        for (proto, elm) in renames {
            let Some(target) = rename::resolve(pool, proto)
                .filter(|target| by_package.contains_key(&target.package))
            else {
                self.diagnostics.push(Problem::unknown_rename(proto));
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
        }
    }

    fn origin(
        &mut self,
        file: &FileDescriptor,
        element: &[i32],
        name_tag: i32,
        what: String,
    ) -> Origin {
        let path = [element, &[name_tag]].concat();
        let site = self.site(file, &path, String::new());
        Origin { what, site }
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
                    builder
                        .diagnostics
                        .push(Problem::invalid_type(full_name, &converted, site));
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
                        let origin = self.origin(file, service.path(), tag::SERVICE_NAME, what);
                        self.claim_module(&service_module, origin, full_name);
                        Some(service_module)
                    }
                    Err(_) => {
                        let path = [service.path(), &[tag::SERVICE_NAME]].concat();
                        let site = self.site(file, &path, "this name".into());
                        self.diagnostics
                            .push(Problem::invalid_service(full_name, site));
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
                if let Some(module) = service_module {
                    services.push(Service {
                        proto_full_name: full_name.to_owned(),
                        module,
                        methods,
                    });
                }
            }
        }

        Package {
            proto_name: proto_name.to_owned(),
            module: module.clone(),
            files: files.iter().map(|file| file.name().to_owned()).collect(),
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
        for (index, (binding, nested)) in bindings.enumerate() {
            match route::resolve(binding, &method.input(), &method.output(), nested) {
                Ok(route) => routes.push(route),
                Err(errors) => {
                    failed = true;
                    let what = match index {
                        0 => format!("The HTTP rule of `{full_name}`"),
                        n => format!("Additional binding {n} of `{full_name}`"),
                    };
                    for error in errors {
                        let site = self.site_within(file, &path, "in this rule".into());
                        self.diagnostics.push(Problem::route(&what, &error, site));
                    }
                }
            }
        }
        (!failed).then_some(routes)
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
                Streaming::Error => Problem::streaming(full_name, which, site),
                Streaming::Skip => Problem::streaming_skipped(full_name, which, site),
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
                self.diagnostics
                    .push(Problem::invalid_method(full_name, &converted, site));
                return None;
            }
        };
        let http = http_rule(method);
        let routes = match &http {
            Some(rule) => self.routes(file, method, rule)?,
            None => Vec::new(),
        };
        let built = Method {
            proto_name: method.name().to_owned(),
            elm_name,
            input: input?,
            output: output?,
            idempotent: idempotent(method),
            http,
            routes,
        };

        if built.elm_name == naming::VERSION_VALUE {
            let site = self.site(
                file,
                &[path, &[tag::METHOD_NAME]].concat(),
                format!("method `{full_name}` is renamed to `{}`", built.elm_name),
            );
            self.diagnostics
                .push(Problem::reserved_value(full_name, &built.elm_name, site));
        }
        let service = method.parent_service();
        let what = format!("method `{full_name}`");
        let origin = self.origin(file, path, tag::METHOD_NAME, what);
        if let Some((first, second)) = values.names.claim(&built.elm_name, origin) {
            let problem = if values.descriptors.contains(&built.elm_name) {
                Problem::descriptor_collision
            } else {
                Problem::value_collision
            };
            self.diagnostics
                .push(problem(service.full_name(), &built.elm_name, first, second));
        } else {
            // A call that clashes with another call has a descriptor that
            // clashes with the other's too; that is one problem, reported.
            let descriptor = built.descriptor_name();
            let what = format!("the descriptor of method `{full_name}`");
            let origin = self.origin(file, path, tag::METHOD_NAME, what);
            if let Some((first, second)) = values.names.claim(&descriptor, origin) {
                self.diagnostics.push(Problem::descriptor_collision(
                    service.full_name(),
                    &descriptor,
                    first,
                    second,
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
    /// on a file system that ignores case.
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
        if let Some((first, second)) = self.module_names.claim(&name, origin) {
            self.diagnostics
                .push(Problem::module_collision(&name, first, second));
        }
    }

    fn claim_type(&mut self, types: &mut Namespace, package: &str, name: &str, origin: Origin) {
        if let Some((first, second)) = types.claim(name, origin) {
            self.diagnostics
                .push(Problem::type_collision(package, name, first, second));
        }
    }

    fn claim_constructor(
        &mut self,
        constructors: &mut Namespace,
        package: &str,
        name: &str,
        origin: Origin,
    ) {
        if let Some((first, second)) = constructors.claim(name, origin) {
            self.diagnostics
                .push(Problem::constructor_collision(package, name, first, second));
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
        let origin = self.origin(file, enumeration.path(), tag::ENUM_NAME, what);
        self.claim_type(types, package, &elm_name, origin);

        let mut values: Vec<EnumValue> = Vec::new();
        let mut declared = Vec::new();
        for value in declared_values(enumeration) {
            declared.push(value.name().to_owned());
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
            let origin = self.origin(file, value.path(), tag::ENUM_VALUE_NAME, what);
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
        Enum::new(
            full_name.to_owned(),
            proto_name.to_owned(),
            elm_name,
            values.next()?,
            values.collect(),
        )
        .map(|built| built.with_declaration_order(declared))
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
        let origin = self.origin(file, message.path(), tag::MESSAGE_NAME, what.clone());
        self.claim_type(types, package, &elm_name, origin);
        let origin = self.origin(file, message.path(), tag::MESSAGE_NAME, what);
        self.claim_constructor(constructors, package, &elm_name, origin);

        let mut record = Namespace::default();
        let mut fields = Vec::new();
        let mut oneofs = Vec::new();
        let mut oneofs_seen = BTreeSet::new();

        for field in message.fields() {
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
                let origin = self.origin(file, oneof.path(), tag::ONEOF_NAME, what);
                if let Some((first, second)) = record.claim(&elm_field_name, origin) {
                    self.diagnostics.push(Problem::field_collision(
                        full_name,
                        &elm_field_name,
                        first,
                        second,
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
                let origin = self.origin(file, oneof.path(), tag::ONEOF_NAME, what.clone());
                self.claim_type(types, package, &elm_type_name, origin);
                let origin = self.origin(
                    file,
                    oneof.path(),
                    tag::ONEOF_NAME,
                    format!("the unset case of {what}"),
                );
                self.claim_constructor(constructors, package, &unset_ctor, origin);

                let mut variants = Vec::new();
                for member in oneof.fields() {
                    let elm_ctor = match self.renames.get(member.full_name()) {
                        Some(given) => given.clone(),
                        None => naming::oneof_variant_constructor(&elm_type_name, member.name()),
                    };
                    let what = format!("oneof field `{}` of `{full_name}`", member.name());
                    let origin = self.origin(file, member.path(), tag::FIELD_NAME, what);
                    self.claim_constructor(constructors, package, &elm_ctor, origin);
                    if let Some(ty) = self.resolve(file, message, &member, member.kind()) {
                        variants.push(OneofVariant {
                            proto_name: member.name().to_owned(),
                            json_name: member.json_name().to_owned(),
                            number: member.number(),
                            elm_ctor,
                            ty,
                            cyclic: false,
                            jstype: jstype(&member),
                        });
                    }
                }
                oneofs.push(Oneof {
                    proto_name: oneof.name().to_owned(),
                    elm_field_name,
                    elm_type_name,
                    unset_ctor,
                    position: fields.len(),
                    variants,
                });
                continue;
            }

            let Some(elm_field_name) =
                self.field_name(file, message, field.name(), field.path(), tag::FIELD_NAME)
            else {
                continue;
            };
            let what = format!("field `{}`", field.name());
            let origin = self.origin(file, field.path(), tag::FIELD_NAME, what);
            if let Some((first, second)) = record.claim(&elm_field_name, origin) {
                self.diagnostics.push(Problem::field_collision(
                    full_name,
                    &elm_field_name,
                    first,
                    second,
                ));
            }
            if let Some((cardinality, ty)) = self.field_type(file, message, &field) {
                fields.push(Field {
                    proto_name: field.name().to_owned(),
                    json_name: field.json_name().to_owned(),
                    number: field.number(),
                    elm_name: elm_field_name,
                    cardinality,
                    ty,
                    cyclic: false,
                    jstype: jstype(&field),
                });
            }
        }

        Some(Message {
            proto_full_name: full_name.to_owned(),
            elm_name,
            fields,
            oneofs,
            wrapper: None,
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

/// Whether `method` declares `idempotency_level = NO_SIDE_EFFECTS`.
fn idempotent(method: &MethodDescriptor) -> bool {
    use prost_types::method_options::IdempotencyLevel;
    method
        .method_descriptor_proto()
        .options
        .as_ref()
        .is_some_and(|options| options.idempotency_level() == IdempotencyLevel::NoSideEffects)
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
