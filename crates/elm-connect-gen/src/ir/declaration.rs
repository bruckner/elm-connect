//! One-line declarations of proto elements, for their documentation
//! (design §3): what the proto declares, rebuilt from the descriptor in
//! canonical spacing rather than copied from the source, and never a body.
//!
//! - `message notes.v1.Note`, `enum notes.v1.Visibility`,
//!   `service notes.v1.NotesService`, `oneof kind`: the full name, but a
//!   oneof's, which is scoped to its message.
//! - `repeated string tags = 4;`: a field, its type by keyword or by full
//!   name, `map<string, string>` for a map, `optional` only for a proto3
//!   optional field, then its options in brackets.
//! - `VISIBILITY_PUBLIC = 1;`: an enum value, with its options likewise.
//! - `rpc GetNote(GetNoteRequest) returns (Note)`: a method, its types
//!   named relative to its service's package, `stream` where it streams.
//!
//! Options are written as a proto file writes them, `name = value` with
//! custom options in parentheses (`(google.api.field_behavior) = REQUIRED`),
//! each value in protobuf's text format as prost-reflect prints it, on one
//! line. A repeated option is written once per value, as the proto
//! repeats it.

use prost_reflect::ReflectMessage as _;
use prost_reflect::text_format::FormatOptions;
use prost_reflect::{
    DynamicMessage, EnumDescriptor, EnumValueDescriptor, FieldDescriptor, Kind, MessageDescriptor,
    MethodDescriptor, OneofDescriptor, ServiceDescriptor, Value,
};

/// `message notes.v1.Note`.
pub fn message(message: &MessageDescriptor) -> String {
    format!("message {}", message.full_name())
}

/// `enum notes.v1.Visibility`.
pub fn enumeration(enumeration: &EnumDescriptor) -> String {
    format!("enum {}", enumeration.full_name())
}

/// `oneof kind`.
pub fn oneof(oneof: &OneofDescriptor) -> String {
    format!("oneof {}", oneof.name())
}

/// `service notes.v1.NotesService`.
pub fn service(service: &ServiceDescriptor) -> String {
    format!("service {}", service.full_name())
}

/// `rpc GetNote(GetNoteRequest) returns (Note)`: the request and response
/// types by their names relative to the service's package, which is how
/// that package's files may write them, and by full name elsewhere.
pub fn method(method: &MethodDescriptor) -> String {
    let package = method
        .parent_service()
        .parent_file()
        .package_name()
        .to_owned();
    let name = |message: MessageDescriptor| {
        let full = message.full_name();
        match full
            .strip_prefix(&package)
            .and_then(|rest| rest.strip_prefix('.'))
        {
            Some(relative) if !package.is_empty() => relative.to_owned(),
            _ => full.to_owned(),
        }
    };
    let stream = |streams: bool| if streams { "stream " } else { "" };
    format!(
        "rpc {}({}{}) returns ({}{})",
        method.name(),
        stream(method.is_client_streaming()),
        name(method.input()),
        stream(method.is_server_streaming()),
        name(method.output()),
    )
}

/// `VISIBILITY_PUBLIC = 1;`, with the value's options in brackets.
pub fn enum_value(value: &EnumValueDescriptor) -> String {
    format!(
        "{} = {}{};",
        value.name(),
        value.number(),
        bracketed(options(&value.options()))
    )
}

/// `repeated string tags = 4;`, with the field's options in brackets:
/// `json_name` first when `explicit_json_name`, then the others.
pub fn field(field: &FieldDescriptor, explicit_json_name: bool) -> String {
    let label = if field.is_list() {
        "repeated "
    } else if field.field_descriptor_proto().proto3_optional() {
        "optional "
    } else {
        ""
    };
    let ty = if field.is_map() {
        match field.kind() {
            Kind::Message(entry) => format!(
                "map<{}, {}>",
                type_name(&entry.map_entry_key_field().kind()),
                type_name(&entry.map_entry_value_field().kind())
            ),
            other => type_name(&other),
        }
    } else {
        type_name(&field.kind())
    };
    let json_name = explicit_json_name
        .then(|| format!("json_name = {}", quoted(field.json_name())))
        .into_iter();
    let options = json_name.chain(options(&field.options())).collect();
    format!(
        "{label}{ty} {} = {}{};",
        field.name(),
        field.number(),
        bracketed(options)
    )
}

/// The JSON name protoc gives a field that does not set `json_name`: its
/// name with each underscore dropped and the letter after it capitalized.
pub fn default_json_name(name: &str) -> String {
    let mut json = String::with_capacity(name.len());
    let mut capitalize = false;
    for c in name.chars() {
        if c == '_' {
            capitalize = true;
        } else if capitalize {
            json.extend(c.to_uppercase());
            capitalize = false;
        } else {
            json.push(c);
        }
    }
    json
}

/// A value type as a proto file writes it: a scalar's keyword, a message's
/// or an enum's full name.
fn type_name(kind: &Kind) -> String {
    match kind {
        Kind::Double => "double".into(),
        Kind::Float => "float".into(),
        Kind::Int32 => "int32".into(),
        Kind::Int64 => "int64".into(),
        Kind::Uint32 => "uint32".into(),
        Kind::Uint64 => "uint64".into(),
        Kind::Sint32 => "sint32".into(),
        Kind::Sint64 => "sint64".into(),
        Kind::Fixed32 => "fixed32".into(),
        Kind::Fixed64 => "fixed64".into(),
        Kind::Sfixed32 => "sfixed32".into(),
        Kind::Sfixed64 => "sfixed64".into(),
        Kind::Bool => "bool".into(),
        Kind::String => "string".into(),
        Kind::Bytes => "bytes".into(),
        Kind::Message(message) => message.full_name().into(),
        Kind::Enum(enumeration) => enumeration.full_name().into(),
    }
}

/// ` [a, b]`, or nothing for no options.
fn bracketed(options: Vec<String>) -> String {
    if options.is_empty() {
        String::new()
    } else {
        format!(" [{}]", options.join(", "))
    }
}

/// Every option set in `options`, standard ones then custom ones, each in
/// field number order and once per value, as `name = value`. An option
/// whose value prost-reflect cannot print as `name: value` is left out.
fn options(options: &DynamicMessage) -> Vec<String> {
    let descriptor = options.descriptor();
    let mut written = Vec::new();
    for (field, value) in options.fields() {
        for value in each(value) {
            let mut alone = DynamicMessage::new(descriptor.clone());
            alone.set_field(&field, single(&field, value));
            written.extend(option(&alone, field.name(), field.name()));
        }
    }
    for (extension, value) in options.extensions() {
        for value in each(value) {
            let mut alone = DynamicMessage::new(descriptor.clone());
            alone.set_extension(&extension, single_extension(&extension, value));
            let printed = format!("[{}]", extension.full_name());
            let name = format!("({})", extension.full_name());
            written.extend(option(&alone, &printed, &name));
        }
    }
    written
}

/// The values of an option: each of a repeated one's, or the one.
fn each(value: &Value) -> Vec<Value> {
    match value {
        Value::List(values) => values.clone(),
        value => vec![value.clone()],
    }
}

/// `value` as the value of `field`: a list of it for a repeated field.
fn single(field: &FieldDescriptor, value: Value) -> Value {
    if field.is_list() {
        Value::List(vec![value])
    } else {
        value
    }
}

/// `value` as the value of `extension`, as [`single`].
fn single_extension(extension: &prost_reflect::ExtensionDescriptor, value: Value) -> Value {
    if extension.is_list() {
        Value::List(vec![value])
    } else {
        value
    }
}

/// `name = value` for the one option set in `alone`, which prost-reflect
/// prints under `printed`; `None` if it prints something else.
fn option(alone: &DynamicMessage, printed: &str, name: &str) -> Option<String> {
    let text = alone.to_text_format_with_options(&FormatOptions::new().pretty(true));
    let one_line = text.lines().map(str::trim).collect::<Vec<_>>().join(" ");
    let rest = one_line.strip_prefix(printed)?;
    let value = match rest.strip_prefix(": ") {
        Some(value) => value,
        // A message value: `name { field: 1 }`.
        None => rest
            .strip_prefix(' ')
            .filter(|value| value.starts_with('{'))?,
    };
    // A repeated option's one value, printed as a list.
    let value = value
        .strip_prefix('[')
        .and_then(|inner| inner.strip_suffix(']'))
        .unwrap_or(value);
    Some(format!("{name} = {value}"))
}

/// `text` as a proto string literal.
fn quoted(text: &str) -> String {
    let mut quoted = String::with_capacity(text.len() + 2);
    quoted.push('"');
    for c in text.chars() {
        match c {
            '"' => quoted.push_str("\\\""),
            '\\' => quoted.push_str("\\\\"),
            '\n' => quoted.push_str("\\n"),
            c => quoted.push(c),
        }
    }
    quoted.push('"');
    quoted
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_json_names_follow_protoc() {
        assert_eq!(default_json_name("display_name"), "displayName");
        assert_eq!(default_json_name("a__b"), "aB");
        assert_eq!(default_json_name("trailing_"), "trailing");
        assert_eq!(default_json_name("_lead"), "Lead");
        assert_eq!(default_json_name("x2_y"), "x2Y");
    }

    #[test]
    fn strings_are_quoted_as_proto_writes_them() {
        assert_eq!(quoted("plain"), "\"plain\"");
        assert_eq!(quoted("a\"b\\c\nd"), "\"a\\\"b\\\\c\\nd\"");
    }
}
