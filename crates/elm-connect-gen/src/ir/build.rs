//! Building the IR from a descriptor pool: naming every type, resolving
//! every field's type, and reporting what has no Elm form.

use std::collections::{BTreeMap, BTreeSet, HashMap};

use prost_reflect::{
    DescriptorPool, EnumDescriptor, EnumValueDescriptor, FieldDescriptor, FileDescriptor, Kind,
    MessageDescriptor,
};

use super::graph::strongly_connected;
use super::{
    Cardinality, Enum, EnumValue, Field, MapKey, Message, ModuleName, Oneof, OneofVariant, Package,
    ScalarKind, TypeName, TypeRef, WellKnown,
};
use crate::diagnostics::{Diagnostics, Problem, Site, Spans, tag};
use crate::naming::{self, NameError};

/// The package whose types are well-known types, never generated.
const WELL_KNOWN_PACKAGE: &str = "google.protobuf";

/// Builds one [`Package`] per proto package declared by the files in
/// `generate` (protoc's `file_to_generate`: names as the pool knows them),
/// sorted by package name.
///
/// Every type those packages refer to must be in a generated package or be
/// a supported well-known type: the generate set must be closed under
/// package references (design §3.1). Files of `google.protobuf` in
/// `generate` are skipped. Services are ignored.
///
/// On any problem, returns every problem found instead.
pub fn build(pool: &DescriptorPool, generate: &[&str]) -> Result<Vec<Package>, Diagnostics> {
    let mut builder = Builder::default();

    let mut by_package: BTreeMap<String, Vec<FileDescriptor>> = BTreeMap::new();
    let mut requested = BTreeSet::new();
    for &name in generate {
        if !requested.insert(name) {
            continue;
        }
        let Some(file) = pool.get_file_by_name(name) else {
            builder.diagnostics.push(Problem::unknown_file(name));
            continue;
        };
        if file.package_name() == WELL_KNOWN_PACKAGE {
            continue;
        }
        let syntax = file.file_descriptor_proto().syntax();
        if syntax != "proto3" {
            let syntax = if syntax.is_empty() { "proto2" } else { syntax };
            let site = builder.site(&file, &[tag::FILE_SYNTAX], format!("{syntax} here"));
            builder
                .diagnostics
                .push(Problem::not_proto3(file.name(), syntax, site));
        }
        by_package
            .entry(file.package_name().to_owned())
            .or_default()
            .push(file);
    }
    for files in by_package.values_mut() {
        files.sort_by(|a, b| a.name().cmp(b.name()));
    }

    for (package, files) in &by_package {
        match naming::module_name(package) {
            Ok(module) => {
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

    builder.mark_recursive(&mut packages);
    builder.check_import_cycles(&by_package);

    if builder.diagnostics.is_empty() {
        Ok(packages)
    } else {
        Err(builder.diagnostics)
    }
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

/// A reference from a field to a generated type, for the recursion and
/// import-cycle graphs.
struct Reference {
    from_message: String,
    from_package: String,
    to_full_name: String,
    to_package: String,
    /// Whether the reference is a oneof member, which does not make an
    /// Elm alias recursive.
    through_oneof: bool,
    site: Site,
}

#[derive(Default)]
struct Builder {
    diagnostics: Diagnostics,
    spans: HashMap<String, Spans>,
    modules: BTreeMap<String, ModuleName>,
    types: HashMap<String, TypeName>,
    references: Vec<Reference>,
}

impl Builder {
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
            match naming::type_name(&nested) {
                Ok(name) => {
                    builder.types.insert(
                        full_name.to_owned(),
                        TypeName {
                            module: module.clone(),
                            name,
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

        Package {
            proto_name: proto_name.to_owned(),
            module: module.clone(),
            files: files.iter().map(|file| file.name().to_owned()).collect(),
            messages,
            enums,
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

        let mut values = Vec::new();
        for value in declared_values(enumeration) {
            let elm_ctor = naming::enum_constructor(&elm_name, enumeration.name(), value.name());
            let what = format!("enum value `{}`", value.name());
            let origin = self.origin(file, value.path(), tag::ENUM_VALUE_NAME, what);
            self.claim_constructor(constructors, package, &elm_ctor, origin);
            values.push(EnumValue {
                proto_name: value.name().to_owned(),
                number: value.number(),
                elm_ctor,
            });
        }
        let mut values = values.into_iter();
        // Proto3 compilers reject an enum whose first value is not 0.
        Enum::new(
            enumeration.full_name().to_owned(),
            elm_name,
            values.next()?,
            values.collect(),
        )
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

                let elm_type_name = naming::oneof_type_name(&elm_name, oneof.name());
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
                    let elm_ctor = naming::oneof_variant_constructor(&elm_type_name, member.name());
                    let what = format!("oneof field `{}` of `{full_name}`", member.name());
                    let origin = self.origin(file, member.path(), tag::FIELD_NAME, what);
                    self.claim_constructor(constructors, package, &elm_ctor, origin);
                    if let Some(ty) = self.resolve(file, message, &member, member.kind(), true) {
                        variants.push(OneofVariant {
                            proto_name: member.name().to_owned(),
                            json_name: member.json_name().to_owned(),
                            number: member.number(),
                            elm_ctor,
                            ty,
                        });
                    }
                }
                oneofs.push(Oneof {
                    proto_name: oneof.name().to_owned(),
                    elm_field_name,
                    elm_type_name,
                    unset_ctor,
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
                });
            }
        }

        Some(Message {
            proto_full_name: full_name.to_owned(),
            elm_name,
            fields,
            oneofs,
            recursive: false,
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
        match naming::field_name(proto_name) {
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
            let key = map_key(&entry.map_entry_key_field().kind())?;
            let value = entry.map_entry_value_field();
            let ty = self.resolve(file, message, field, value.kind(), false)?;
            return Some((Cardinality::Map(key), ty));
        }
        let cardinality = if field.is_list() {
            Cardinality::Repeated
        } else if field.field_descriptor_proto().proto3_optional() {
            Cardinality::Optional
        } else {
            Cardinality::Singular
        };
        let ty = self.resolve(file, message, field, field.kind(), false)?;
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
        through_oneof: bool,
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
        let type_path = [field.path(), &[tag::FIELD_TYPE_NAME]].concat();

        if package == WELL_KNOWN_PACKAGE {
            let name = full_name
                .strip_prefix("google.protobuf.")
                .unwrap_or(&full_name);
            if let Some(well_known) = WellKnown::from_name(name).filter(|_| is_message) {
                return Some(TypeRef::WellKnown(well_known));
            }
            let site = self.site(file, &type_path, format!("`{full_name}` here"));
            self.diagnostics.push(if name == "Any" {
                Problem::any(message.full_name(), field.name(), site)
            } else {
                Problem::unsupported_well_known(message.full_name(), field.name(), &full_name, site)
            });
            return None;
        }

        if !self.modules.contains_key(&package) {
            let site = self.site(
                file,
                &type_path,
                format!("`{package}` is not being generated"),
            );
            self.diagnostics.push(Problem::not_generated(
                message.full_name(),
                field.name(),
                &full_name,
                &package,
                &defining_file,
                site,
            ));
            return None;
        }

        // A type in a generated package with no name was reported already.
        let name = self.types.get(&full_name)?.clone();
        let site = self.site(
            file,
            &type_path,
            format!("`{}` refers to `{package}` here", file.package_name()),
        );
        self.references.push(Reference {
            from_message: message.full_name().to_owned(),
            from_package: file.package_name().to_owned(),
            to_full_name: full_name,
            to_package: package,
            through_oneof,
            site,
        });
        Some(match enum_names {
            None => TypeRef::Message(name),
            Some((enum_name, zero_value)) => TypeRef::Enum {
                zero_ctor: naming::enum_constructor(&name.name, &enum_name, &zero_value),
                name,
            },
        })
    }

    /// Sets [`Message::recursive`] on every message in a cycle of
    /// non-oneof message references.
    fn mark_recursive(&self, packages: &mut [Package]) {
        let mut index = HashMap::new();
        for message in packages.iter().flat_map(|package| &package.messages) {
            let next = index.len();
            index.entry(message.proto_full_name.clone()).or_insert(next);
        }
        let mut edges = vec![Vec::new(); index.len()];
        let mut self_loops = vec![false; index.len()];
        for reference in self.references.iter().filter(|r| !r.through_oneof) {
            if let (Some(&from), Some(&to)) = (
                index.get(&reference.from_message),
                index.get(&reference.to_full_name),
            ) {
                edges[from].push(to);
                self_loops[from] |= from == to;
            }
        }
        let mut recursive = self_loops;
        for component in strongly_connected(&edges) {
            if component.len() > 1 {
                for node in component {
                    recursive[node] = true;
                }
            }
        }
        for message in packages
            .iter_mut()
            .flat_map(|package| &mut package.messages)
        {
            message.recursive = recursive[index[&message.proto_full_name]];
        }
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
fn declared_values(enumeration: &EnumDescriptor) -> Vec<EnumValueDescriptor> {
    enumeration
        .enum_descriptor_proto()
        .value
        .iter()
        .filter_map(|value| enumeration.get_value_by_name(value.name()))
        .collect()
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
        Kind::Bool => MapKey::Bool,
        Kind::String => MapKey::String,
        _ => return None,
    })
}
