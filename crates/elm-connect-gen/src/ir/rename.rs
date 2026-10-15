//! The rename map (design §3.7): what each proto full name in it denotes,
//! and whether the Elm name given for it suits that.

use prost_reflect::{DescriptorPool, FileDescriptor};

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

    /// What the given name becomes, and the rule it must follow; `None`
    /// for an alias, which takes no name.
    pub(super) fn rule(self) -> Option<(&'static str, &'static str)> {
        const PASCAL: &str = "an ASCII uppercase letter followed by letters and digits \
                              (PascalCase)";
        const VALUE: &str = "an ASCII lowercase letter followed by letters, digits or \
                             underscores, and not an Elm reserved word";
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
    /// one.
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
