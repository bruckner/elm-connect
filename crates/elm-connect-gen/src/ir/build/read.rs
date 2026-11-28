//! What the builder reads from descriptors without deciding anything:
//! the messages and enums of a file in the order the IR lists them, the
//! fields and enum values in declaration order, a map's key kind, and
//! what a method's or a field's options say (`idempotency_level`,
//! `google.api.http`, `google.api.field_behavior`, `deprecated`,
//! `packed`, `jstype`). Each is a function of a descriptor alone: none
//! names an Elm identifier or reports a problem.

use prost_reflect::{
    DynamicMessage, EnumDescriptor, EnumValueDescriptor, FieldDescriptor, FileDescriptor, Kind,
    MessageDescriptor, MethodDescriptor, Value,
};

use crate::ir::{Annotations, FieldBehavior, HttpRule, HttpVerb, Idempotency, JsType, MapKey};

/// Every message of `file`, nested ones included, an enclosing message
/// before its nested ones; map entries excluded.
pub(super) fn all_messages(file: &FileDescriptor) -> Vec<MessageDescriptor> {
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
pub(super) fn all_enums(file: &FileDescriptor) -> Vec<EnumDescriptor> {
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
pub(in crate::ir) fn declared_values(enumeration: &EnumDescriptor) -> Vec<EnumValueDescriptor> {
    enumeration
        .enum_descriptor_proto()
        .value
        .iter()
        .filter_map(|value| enumeration.get_value_by_name(value.name()))
        .collect()
}

/// The `idempotency_level` `method` declares.
pub(super) fn idempotency(method: &MethodDescriptor) -> Idempotency {
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
/// The unspecified zero is dropped; a number this release does not name
/// is kept as [`FieldBehavior::Unknown`].
pub(super) fn annotations(field: &FieldDescriptor) -> Annotations {
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
pub(super) fn http_rule(method: &MethodDescriptor) -> Option<HttpRule> {
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

/// Whether `field` is a repeated scalar or enum that is not packed: one
/// declared `[packed = false]`, as proto3's scalars are packed by default.
/// The option is read from the field's own options: the descriptor pool's
/// `is_packed` reports such a field packed.
pub(super) fn unpacked(field: &FieldDescriptor) -> bool {
    field.is_list()
        && field
            .field_descriptor_proto()
            .options
            .as_ref()
            .and_then(|options| options.packed)
            == Some(false)
        && !matches!(field.kind(), Kind::Message(_) | Kind::String | Kind::Bytes)
}

/// The `jstype` option of `field` when its values are 64-bit integers;
/// [`JsType::Normal`] for any other field, where it means nothing.
pub(super) fn jstype(field: &FieldDescriptor) -> JsType {
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

pub(super) fn map_key(kind: &Kind) -> Option<MapKey> {
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
