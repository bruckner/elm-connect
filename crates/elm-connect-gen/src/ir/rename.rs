//! The rename map (design §3.7): what each proto full name in it denotes,
//! and whether the Elm name given for it suits that.

use prost_reflect::{DescriptorPool, EnumDescriptor, FileDescriptor, MessageDescriptor};

use crate::diagnostics::tag;
use crate::ir::ModuleName;
use crate::naming::ELM_RESERVED_WORDS;

/// What a renamed proto element is, which decides the Elm name it takes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Role {
    /// A package: its whole Elm module name.
    Package,
    /// A service: the last segment of its module name.
    Service,
    /// A method: its value in the service's module.
    Method,
    /// A message: its type.
    Message,
    /// An enum: its type.
    Enum,
    /// A field outside any oneof: its record field.
    Field,
    /// A oneof: its record field, and through it its type.
    Oneof,
    /// A member field of a oneof: its constructor.
    OneofMember,
    /// An enum value: its constructor.
    EnumValue,
    /// An enum value declared after another with its number, under
    /// `allow_alias`: it has no constructor of its own to rename.
    EnumAlias,
}

impl Role {
    /// The element, as a noun phrase: "a message".
    pub(super) fn what(self) -> &'static str {
        match self {
            Role::Package => "a package",
            Role::Service => "a service",
            Role::Method => "a method",
            Role::Message => "a message",
            Role::Enum => "an enum",
            Role::Field => "a field",
            Role::Oneof => "a oneof",
            Role::OneofMember => "a field of a oneof",
            Role::EnumValue => "an enum value",
            Role::EnumAlias => "an enum value alias",
        }
    }

    /// The element, as a bare noun: "message".
    pub(super) fn noun(self) -> &'static str {
        let what = self.what();
        what.split_once(' ').map_or(what, |(_, noun)| noun)
    }

    /// The kinds of element a rename can name under this one, as
    /// alternatives: "method" under a service; `None` for an element with
    /// nothing under it.
    pub(super) fn members(self) -> Option<&'static str> {
        match self {
            Role::Package => Some("service, message or enum"),
            Role::Service => Some("method"),
            Role::Message => Some("field, oneof or nested message or enum"),
            Role::Enum => Some("value"),
            Role::Method
            | Role::Field
            | Role::Oneof
            | Role::OneofMember
            | Role::EnumValue
            | Role::EnumAlias => None,
        }
    }

    /// What the given name becomes, and the rule it must follow; `None`
    /// for an alias, which takes no name.
    pub(super) fn rule(self) -> Option<(&'static str, &'static str)> {
        const PASCAL: &str = "an ASCII uppercase letter followed by letters and digits \
                              (PascalCase)";
        const VALUE: &str = "an ASCII lowercase letter followed by letters, digits or \
                             underscores, not ending in an underscore, and not an Elm \
                             reserved word";
        Some(match self {
            Role::Package => (
                "an Elm module name",
                "dot-separated segments, each an ASCII uppercase letter followed by letters, \
                 digits or underscores (`Notes.Api`)",
            ),
            Role::Service => (
                "the last segment of an Elm module name",
                "a single segment, without dots: an ASCII uppercase letter followed by \
                 letters, digits or underscores",
            ),
            Role::Method => ("an Elm value", VALUE),
            Role::Message | Role::Enum => ("an Elm type", PASCAL),
            Role::Field | Role::Oneof => ("an Elm record field", VALUE),
            Role::OneofMember | Role::EnumValue => ("an Elm constructor", PASCAL),
            Role::EnumAlias => return None,
        })
    }

    /// Whether `elm` is a name this role can take. Types and constructors
    /// take no underscore: the generator's own names have none, so the
    /// wrapper of a recursive message (`Node_`, design §3.2) cannot meet
    /// one. Values and record fields do not end in one: a value the
    /// generator adds ends in `_` (`elmConnectVersion_`, design §3.1), and
    /// a derived name does only as an escape (`type_`, `descriptor_`).
    pub(super) fn accepts(self, elm: &str) -> bool {
        let segment = |name: &str| ModuleName::new(vec![name.to_owned()]).is_some();
        let pascal = |name: &str| {
            let mut chars = name.chars();
            chars.next().is_some_and(|c| c.is_ascii_uppercase())
                && chars.all(|c| c.is_ascii_alphanumeric())
        };
        let value = |name: &str| {
            let mut chars = name.chars();
            chars.next().is_some_and(|c| c.is_ascii_lowercase())
                && chars.all(|c| c.is_ascii_alphanumeric() || c == '_')
                && !name.ends_with('_')
                && !ELM_RESERVED_WORDS.contains(&name)
        };
        match self {
            Role::Package => elm.split('.').all(segment),
            Role::Service => segment(elm),
            Role::Method | Role::Field | Role::Oneof => value(elm),
            Role::Message | Role::Enum | Role::OneofMember | Role::EnumValue => pascal(elm),
            Role::EnumAlias => false,
        }
    }
}

/// The element a proto full name denotes: its role, its package, and
/// where its name is written.
pub(super) struct Target {
    pub(super) role: Role,
    pub(super) package: String,
    pub(super) file: FileDescriptor,
    pub(super) path: Vec<i32>,
}

/// What `name` denotes in `pool`, if anything: a package (its first file
/// by name), a service, a message (not a map entry), an enum, or, by its
/// last segment, a method of a service, a field or real oneof of a
/// message, or a value of an enum (`notes.v1.Visibility.VISIBILITY_PUBLIC`,
/// qualified by its enum rather than scoped beside it as protobuf does).
pub(super) fn resolve(pool: &DescriptorPool, name: &str) -> Option<Target> {
    let target = |role, file: FileDescriptor, path: &[i32], name_tag| Target {
        role,
        package: file.package_name().to_owned(),
        file,
        path: [path, &[name_tag]].concat(),
    };
    if let Some(message) = pool.get_message_by_name(name) {
        return (!message.is_map_entry()).then(|| {
            let path = message.path().to_vec();
            target(
                Role::Message,
                message.parent_file(),
                &path,
                tag::MESSAGE_NAME,
            )
        });
    }
    if let Some(enumeration) = pool.get_enum_by_name(name) {
        let path = enumeration.path().to_vec();
        return Some(target(
            Role::Enum,
            enumeration.parent_file(),
            &path,
            tag::ENUM_NAME,
        ));
    }
    if let Some(service) = pool.get_service_by_name(name) {
        let path = service.path().to_vec();
        return Some(target(
            Role::Service,
            service.parent_file(),
            &path,
            tag::SERVICE_NAME,
        ));
    }
    let mut package_files: Vec<FileDescriptor> =
        pool.files().filter(|f| f.package_name() == name).collect();
    package_files.sort_by(|a, b| a.name().cmp(b.name()));
    if let Some(file) = package_files.into_iter().next() {
        return Some(Target {
            role: Role::Package,
            package: name.to_owned(),
            file,
            path: vec![tag::FILE_PACKAGE],
        });
    }
    let (parent, last) = name.rsplit_once('.')?;
    if let Some(service) = pool.get_service_by_name(parent) {
        let method = service.methods().find(|m| m.name() == last)?;
        let path = method.path().to_vec();
        return Some(target(
            Role::Method,
            service.parent_file(),
            &path,
            tag::METHOD_NAME,
        ));
    }
    if let Some(message) = pool.get_message_by_name(parent) {
        if message.is_map_entry() {
            return None;
        }
        let file = message.parent_file();
        if let Some(field) = message.get_field_by_name(last) {
            let role = match field.containing_oneof() {
                Some(oneof) if !oneof.is_synthetic() => Role::OneofMember,
                _ => Role::Field,
            };
            let path = field.path().to_vec();
            return Some(target(role, file, &path, tag::FIELD_NAME));
        }
        let oneof = message
            .oneofs()
            .find(|oneof| oneof.name() == last && !oneof.is_synthetic())?;
        let path = oneof.path().to_vec();
        return Some(target(Role::Oneof, file, &path, tag::ONEOF_NAME));
    }
    let enumeration = pool.get_enum_by_name(parent)?;
    let values = super::build::declared_values(&enumeration);
    let index = values.iter().position(|value| value.name() == last)?;
    let value = &values[index];
    let alias = values[..index]
        .iter()
        .any(|earlier| earlier.number() == value.number());
    let role = if alias {
        Role::EnumAlias
    } else {
        Role::EnumValue
    };
    let path = value.path().to_vec();
    Some(target(
        role,
        enumeration.parent_file(),
        &path,
        tag::ENUM_VALUE_NAME,
    ))
}

/// The longest of `name` and its dot-separated prefixes that [`resolve`]
/// finds, with what it denotes: `name` itself when it resolves, or how far
/// a name that does not got (`notes.v1.Note` for `notes.v1.Note.pageCount`).
pub(super) fn resolve_prefix(pool: &DescriptorPool, name: &str) -> Option<(String, Target)> {
    let mut prefix = name;
    loop {
        if let Some(target) = resolve(pool, prefix) {
            return Some((prefix.to_owned(), target));
        }
        prefix = prefix.rsplit_once('.')?.0;
    }
}

/// Every proto full name a rename of `files` (the files of the generated
/// packages) can name, as [`resolve`] takes it, sorted: each package,
/// service, method, message (not a map entry), enum, field, real oneof
/// and enum value under its enum.
pub(super) fn names<'a>(files: impl IntoIterator<Item = &'a FileDescriptor>) -> Vec<String> {
    fn add_enum(names: &mut Vec<String>, enumeration: &EnumDescriptor) {
        names.push(enumeration.full_name().to_owned());
        for value in enumeration.values() {
            names.push(format!("{}.{}", enumeration.full_name(), value.name()));
        }
    }
    fn add_message(names: &mut Vec<String>, message: &MessageDescriptor) {
        if message.is_map_entry() {
            return;
        }
        names.push(message.full_name().to_owned());
        names.extend(message.fields().map(|field| field.full_name().to_owned()));
        names.extend(
            message
                .oneofs()
                .filter(|oneof| !oneof.is_synthetic())
                .map(|oneof| oneof.full_name().to_owned()),
        );
        for nested in message.child_messages() {
            add_message(names, &nested);
        }
        for nested in message.child_enums() {
            add_enum(names, &nested);
        }
    }
    let mut names = Vec::new();
    for file in files {
        names.push(file.package_name().to_owned());
        for service in file.services() {
            names.push(service.full_name().to_owned());
            names.extend(
                service
                    .methods()
                    .map(|method| method.full_name().to_owned()),
            );
        }
        for nested in file.messages() {
            add_message(&mut names, &nested);
        }
        for nested in file.enums() {
            add_enum(&mut names, &nested);
        }
    }
    names.sort();
    names.dedup();
    names
}
