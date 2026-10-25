//! The codec round trips (design §7, `conformance/codec/`): every
//! construct the generated proto3 JSON codecs handle, run against
//! prost-reflect.
//!
//! This test samples each message of `codec.proto` from a fixed seed (the
//! sampler in `common/sample.rs`, which the route properties share) and
//! has prost-reflect write each sample's proto3 JSON in three forms:
//!
//! - `canonical`: defaults left out, JSON names;
//! - `defaults`: every default written, JSON names;
//! - `proto names, unknown fields`: defaults left out, proto field names,
//!   and a field no message declares added to every message object.
//!
//! What a generated encoder must write back after its decoder reads a
//! form is prost-reflect's canonical form, but for the differences the
//! design allows ([`allowed_differences`]) and for an `Any`'s packed
//! message, which the runtime holds as the JSON it received and writes
//! back as it is (§3.5).
//!
//! It writes the samples as Elm data (`Generated.Codec.Data`, and
//! `Generated.Codec.DataInt64Int` with 64-bit values an Elm `Int` holds),
//! the modules generated from `codec.proto` under each option set
//! (`Generated.Codec.<Set>.*`), and a table of each set's codecs
//! (`Generated.Codec.Codecs`), all under `tests/Generated/Codec/`. That
//! tree is gitignored and rewritten by every run of this test, which
//! `just codec-gen` runs on its own: nothing generated is committed, so a
//! generator change shows in review once, in the conformance corpus, and
//! the fixed seed keeps the samples the same from run to run.
//! `tests/Codec/RoundTripTest.elm` decodes every form with the generated
//! decoder, re-encodes it with the generated encoder and compares the
//! JSON with the expected, structurally and numbers by value.
//!
//! The binary oracle: each sample's protobuf binary too, written
//! deterministically ([`encode_sorted`] of [`canonical_message`]), which
//! prost-reflect must read back as the sample, under the binary sets
//! (`codec=both`, also with `int64=int` and `bytes=bytes`, and
//! `codec=binary`); `tests/Codec/BinaryRoundTripTest.elm` decodes it with
//! the generated binary decoder and must re-encode the same bytes.

use std::fs;

use elm_connect_gen::elm::ast::{Decl, Exposing, Expr, Import, Module, ModuleName, Type};
use elm_connect_gen::elm::build::{
    apply, list, qualified, record, string, tuple2, ty, ty_qualified, var,
};
use elm_connect_gen::{Options, generate};
use prost::Message as _;
use prost_reflect::{
    DescriptorPool, DeserializeOptions, DynamicMessage, FieldDescriptor, Kind, MapKey,
    MessageDescriptor, ReflectMessage, SerializeOptions, Value,
};
use serde_json::Value as Json;

mod common;
use common::{files_under, repo_root};
#[path = "common/sample.rs"]
mod sample;
use sample::{Profile, Rng, sample_message, sample_value};

/// The proto files, under `conformance/codec/`.
const PROTOS: [&str; 2] = ["codec.proto", "other.proto"];

/// The seed of the sampling and the number of samples per message under
/// [`WIDE`]; [`NARROW`] takes half as many, since only its 64-bit values
/// differ. Changing either re-samples every message, which rewrites the
/// data modules. `ELM_CONNECT_CODEC_SAMPLES` overrides the number for a
/// deeper run (`conformance/README.md`).
const SEED: u64 = 0x2026_1020;
const PER_MESSAGE: usize = 8;

fn per_message(profile: &Profile) -> usize {
    let n = match std::env::var("ELM_CONNECT_CODEC_SAMPLES") {
        Ok(n) => n
            .parse()
            .unwrap_or_else(|_| panic!("ELM_CONNECT_CODEC_SAMPLES={n} is not a number")),
        Err(_) => PER_MESSAGE,
    };
    if profile.wide { n } else { n.div_ceil(2) }
}

/// Strings of what JSON and an Elm literal must escape (C0 controls
/// included), reserved characters and multi-byte UTF-8; 64-bit integers
/// over their whole range.
const WIDE: Profile = Profile {
    chars: "azAZ09-_.~/?#&=% +:@!$'()*,;[]<>\"\\\n\r\t\u{0}\u{1}\u{8}\u{C}\u{1F}\u{7F}\u{2028}éßΩ中✓😀\u{10348}",
    wide: true,
    depth: 1,
    items: 3,
};

/// As [`WIDE`], with 64-bit values within ±(2^53 − 1), which `int64=int`
/// holds.
const NARROW: Profile = Profile {
    wide: false,
    ..WIDE
};

/// An option set the modules are generated under: the module prefix's
/// last part, the protoc parameter, and the name of its codec table in
/// `Generated.Codec.Codecs`.
struct OptionSet {
    prefix: &'static str,
    parameter: &'static str,
    table: &'static str,
    /// Whether the set's messages get proto3 JSON codecs, and binary ones.
    json: bool,
    binary: bool,
}

const SETS: [OptionSet; 8] = [
    OptionSet {
        prefix: "Default",
        parameter: "",
        table: "default",
        json: true,
        binary: false,
    },
    OptionSet {
        prefix: "Int64Int",
        parameter: "int64=int",
        table: "int64Int",
        json: true,
        binary: false,
    },
    OptionSet {
        prefix: "EnumZero",
        parameter: "enum_unknown=zero",
        table: "enumZero",
        json: true,
        binary: false,
    },
    OptionSet {
        prefix: "BytesBytes",
        parameter: "bytes=bytes",
        table: "bytesBytes",
        json: true,
        binary: false,
    },
    OptionSet {
        prefix: "Both",
        parameter: "codec=both",
        table: "both",
        json: true,
        binary: true,
    },
    OptionSet {
        prefix: "BothInt64Int",
        parameter: "codec=both,int64=int",
        table: "bothInt64Int",
        json: true,
        binary: true,
    },
    OptionSet {
        prefix: "BothBytesBytes",
        parameter: "codec=both,bytes=bytes",
        table: "bothBytesBytes",
        json: true,
        binary: true,
    },
    OptionSet {
        prefix: "Binary",
        parameter: "codec=binary",
        table: "binary",
        json: false,
        binary: true,
    },
];

impl OptionSet {
    fn options(&self) -> Options {
        let prefix = format!("module_prefix=Generated.Codec.{}", self.prefix);
        let parameter = if self.parameter.is_empty() {
            prefix
        } else {
            format!("{},{prefix}", self.parameter)
        };
        Options::from_parameter(&parameter).expect("valid options")
    }
}

fn pool() -> DescriptorPool {
    let dir = repo_root().join("conformance/codec");
    let mut compiler =
        protox::Compiler::with_file_resolver(elm_connect_gen::googleapis::resolver([dir]));
    compiler.include_imports(true).include_source_info(true);
    compiler
        .open_files(PROTOS)
        .unwrap_or_else(|e| panic!("conformance/codec does not compile: {e:?}"));
    compiler.descriptor_pool()
}

/// The messages sampled: every top-level message of `codec.proto`, in
/// declaration order. Nested and other-package messages are reached
/// through them.
fn messages(pool: &DescriptorPool) -> Vec<MessageDescriptor> {
    pool.get_file_by_name("codec.proto")
        .expect("codec.proto")
        .messages()
        .collect()
}

// The oracle.

fn serialize(message: &DynamicMessage, skip_defaults: bool, proto_names: bool) -> Json {
    message
        .serialize_with_options(
            serde_json::value::Serializer,
            &SerializeOptions::new()
                .skip_default_fields(skip_defaults)
                .use_proto_field_name(proto_names),
        )
        .unwrap_or_else(|e| panic!("prost-reflect cannot write {message:?}: {e}"))
}

/// A message type whose JSON this test walks into: one of the protos',
/// not a well-known type, whose JSON forms are the runtime's own (§3.5).
fn walked(kind: &Kind) -> Option<&MessageDescriptor> {
    match kind {
        Kind::Message(m) if !m.full_name().starts_with("google.protobuf.") => Some(m),
        _ => None,
    }
}

fn is_well_known(kind: &Kind, name: &str) -> bool {
    matches!(kind, Kind::Message(m) if m.full_name() == format!("google.protobuf.{name}"))
}

/// The value of `field` in `json`, a message's object, under its JSON or
/// its proto name.
fn member<'a>(json: &'a Json, field: &FieldDescriptor) -> Option<&'a Json> {
    json.get(field.json_name())
        .or_else(|| json.get(field.name()))
}

/// The JSON object key of a map key.
fn key_text(key: &MapKey) -> String {
    match key {
        MapKey::Bool(b) => b.to_string(),
        MapKey::I32(n) => n.to_string(),
        MapKey::I64(n) => n.to_string(),
        MapKey::U32(n) => n.to_string(),
        MapKey::U64(n) => n.to_string(),
        MapKey::String(s) => s.clone(),
    }
}

/// Calls `each` with every value of `field` in `target` and the same
/// value in `source`, two forms of a message's object, each keyed by
/// either name: the field's value, each element, or each map value.
fn each_value(
    field: &FieldDescriptor,
    target: &mut Json,
    source: &Json,
    each: &mut dyn FnMut(&Kind, &mut Json, &Json),
) {
    let key = if target.get(field.json_name()).is_some() {
        field.json_name()
    } else {
        field.name()
    };
    let (Some(target), Some(source)) = (target.get_mut(key), member(source, field)) else {
        return;
    };
    if field.is_map() {
        let Kind::Message(entry) = field.kind() else {
            unreachable!()
        };
        let kind = entry.map_entry_value_field().kind();
        if let Json::Object(entries) = target {
            for (key, value) in entries.iter_mut() {
                if let Some(from) = source.get(key) {
                    each(&kind, value, from);
                }
            }
        }
    } else if field.is_list() {
        if let (Json::Array(items), Json::Array(from)) = (target, source) {
            for (value, from) in items.iter_mut().zip(from) {
                each(&field.kind(), value, from);
            }
        }
    } else {
        each(&field.kind(), target, source);
    }
}

/// `target`, a message of type `descriptor` as canonical JSON, with each
/// `Any` replaced by the one in `source`, the same message in another
/// form: the runtime writes an `Any`'s packed message back as it arrived
/// (§3.5), defaults and proto names included.
fn take_anys(descriptor: &MessageDescriptor, target: &mut Json, source: &Json) {
    for field in descriptor.fields() {
        each_value(&field, target, source, &mut |kind, value, from| {
            if is_well_known(kind, "Any") {
                *value = from.clone();
            } else if let Some(inner) = walked(kind) {
                take_anys(inner, value, from);
            }
        });
    }
}

/// The key the `unknown` form adds to every message object.
const UNKNOWN: &str = "zzUnknownField";

/// `json`, a message of type `descriptor`, with [`UNKNOWN`] added to it
/// and to every message within it, but those inside an `Any`, which the
/// runtime passes through.
fn add_unknown(descriptor: &MessageDescriptor, json: &mut Json) {
    let copy = json.clone();
    for field in descriptor.fields() {
        each_value(&field, json, &copy, &mut |kind, value, _| {
            if let Some(inner) = walked(kind) {
                add_unknown(inner, value);
            }
        });
    }
    if let Json::Object(object) = json {
        object.insert(
            UNKNOWN.into(),
            serde_json::json!({ "a": [1, null, "x", { "b": true }] }),
        );
    }
}

/// The differences between what prost-reflect writes and what the
/// generated encoders write that the design allows, applied to `json`,
/// `message`'s canonical JSON, for the encoder that decoded `input`, the
/// form it read, at every level but inside an `Any`:
///
/// - A float or double field without presence that the input holds as
///   `-0` is written as `0` (§3.4: only `0` is left out, and JavaScript's
///   JSON writer has no negative zero); prost-reflect's canonical form
///   leaves it out as a default. (A form without it decodes as `0`, which
///   the encoder leaves out too.)
/// - A singular `google.protobuf.Empty` field outside a oneof is always
///   written, as `{}` (§3.4, §3.5: `Empty` carries no presence);
///   prost-reflect leaves it out when unset.
///
/// Everything else must match; `-0` written elsewhere as `0` does, since
/// numbers compare by value.
fn allowed_differences(message: &DynamicMessage, json: &mut Json, input: &Json) {
    for field in message.descriptor().fields() {
        let kind = field.kind();
        let singular = !field.is_list() && !field.is_map();
        if singular && !field.supports_presence() {
            let negative_zero = match message.get_field(&field).as_ref() {
                Value::F64(x) => *x == 0.0 && x.is_sign_negative(),
                Value::F32(x) => *x == 0.0 && x.is_sign_negative(),
                _ => false,
            };
            if negative_zero && member(input, &field).is_some() {
                json[field.json_name()] = serde_json::json!(0);
            }
        }
        if singular && field.containing_oneof().is_none() && is_well_known(&kind, "Empty") {
            json[field.json_name()] = serde_json::json!({});
        }
        if walked(&kind).is_none() || !message.has_field(&field) {
            continue;
        }
        let (Some(value), Some(input)) = (json.get_mut(field.json_name()), member(input, &field))
        else {
            continue;
        };
        match message.get_field(&field).as_ref() {
            Value::Message(inner) => allowed_differences(inner, value, input),
            Value::List(items) => {
                let inputs = input.as_array().expect("an array");
                for ((item, json), input) in items
                    .iter()
                    .zip(value.as_array_mut().expect("an array"))
                    .zip(inputs)
                {
                    if let Value::Message(inner) = item {
                        allowed_differences(inner, json, input);
                    }
                }
            }
            Value::Map(entries) => {
                for (key, item) in entries {
                    let key = key_text(key);
                    if let (Value::Message(inner), Some(json), Some(input)) =
                        (item, value.get_mut(&key), input.get(&key))
                    {
                        allowed_differences(inner, json, input);
                    }
                }
            }
            _ => {}
        }
    }
}

/// One sampled message, as the Elm tests take it.
struct Sample {
    name: String,
    message: DynamicMessage,
    canonical: Json,
    /// What the encoder writes after decoding the canonical form, when
    /// that is not the canonical form itself ([`allowed_differences`]).
    expected: Option<Json>,
    /// The other forms.
    forms: Vec<Form>,
    /// The protobuf binary of [`canonical_message`] of the sample, written
    /// deterministically ([`encode_sorted`]): what a generated binary
    /// encoder must write after its decoder reads it.
    binary: Vec<u8>,
    /// What the generated JSON encoder writes after the binary decoder
    /// reads [`Sample::binary`], when that is not what it writes after the
    /// JSON decoder reads the canonical form: an `Any` read from binary
    /// holds the packed message's binary ([`binary_view`]).
    binary_json: Option<Json>,
}

struct Form {
    form: &'static str,
    input: Json,
    /// What the encoder writes after decoding this form, when that is not
    /// what it writes after decoding the canonical form (an `Any` written
    /// with its defaults or under proto names).
    expected: Option<Json>,
}

impl Sample {
    /// Every form: the canonical, then the others.
    fn inputs(&self) -> impl Iterator<Item = (&str, &Json)> {
        std::iter::once(("canonical", &self.canonical))
            .chain(self.forms.iter().map(|f| (f.form, &f.input)))
    }
}

fn sample(name: String, message: DynamicMessage) -> Sample {
    let descriptor = message.descriptor();
    let binary_message = canonical_message(&message);
    let binary = encode_sorted(&binary_message);
    let mut viewed = serialize(&binary_message, true, false);
    binary_view(&binary_message, &mut viewed);
    let canonical = serialize(&message, true, false);
    let mut expected = canonical.clone();
    allowed_differences(&message, &mut expected, &canonical);
    let mut unknown = serialize(&message, true, true);
    add_unknown(&descriptor, &mut unknown);
    let forms = [
        ("defaults", serialize(&message, false, false)),
        ("proto names, unknown fields", unknown),
    ]
    .into_iter()
    .map(|(form, input)| {
        let mut own = canonical.clone();
        take_anys(&descriptor, &mut own, &input);
        allowed_differences(&message, &mut own, &input);
        Form {
            form,
            input,
            expected: (own != expected).then_some(own),
        }
    })
    .collect();
    let binary_json = (viewed != expected).then_some(viewed);
    Sample {
        name,
        message,
        expected: (expected != canonical).then_some(expected),
        canonical,
        forms,
        binary,
        binary_json,
    }
}

// The binary oracle.

/// `message` as the generated binary codecs hold it, so that the bytes
/// [`encode_sorted`] writes for it are what they write back: every
/// singular `google.protobuf.Empty` field outside a oneof set, since Elm
/// holds it as `()` without presence and the encoder writes it (as the
/// JSON encoder writes `{}`); every `Any`'s packed message re-encoded with
/// [`encode_sorted`], since the runtime keeps an `Any`'s bytes as they
/// arrive; and every `google.protobuf.Value` that sets no kind given
/// `null_value`, which prost-reflect leaves unset when it reads JSON's
/// `null`, and which is the null the runtime reads it as and writes. At
/// every level, inside an `Any`'s message too.
fn canonical_message(message: &DynamicMessage) -> DynamicMessage {
    let descriptor = message.descriptor();
    let mut out = message.clone();
    if descriptor.full_name() == "google.protobuf.Value"
        && !descriptor.fields().any(|field| out.has_field(&field))
    {
        out.set_field_by_name("null_value", Value::EnumNumber(0));
    }
    if descriptor.full_name() == "google.protobuf.Any" {
        let url = message
            .get_field_by_name("type_url")
            .and_then(|v| v.as_str().map(str::to_owned))
            .unwrap_or_default();
        if let Some(name) = url.rsplit('/').next().filter(|n| !n.is_empty()) {
            let inner_descriptor = descriptor
                .parent_pool()
                .get_message_by_name(name)
                .unwrap_or_else(|| panic!("an Any of {name}, which the pool lacks"));
            let bytes = message
                .get_field_by_name("value")
                .and_then(|v| v.as_bytes().cloned())
                .unwrap_or_default();
            let inner = DynamicMessage::decode(inner_descriptor, bytes).expect("an Any's message");
            let canonical = encode_sorted(&canonical_message(&inner));
            out.set_field_by_name("value", Value::Bytes(canonical.into()));
        }
        return out;
    }
    for field in descriptor.fields() {
        let kind = field.kind();
        let singular = !field.is_list() && !field.is_map();
        if let Kind::Message(empty) = &kind
            && singular
            && field.containing_oneof().is_none()
            && is_well_known(&kind, "Empty")
            && !out.has_field(&field)
        {
            out.set_field(&field, Value::Message(DynamicMessage::new(empty.clone())));
        }
        if !out.has_field(&field) || !matches!(kind, Kind::Message(_)) {
            continue;
        }
        let updated = match out.get_field(&field).as_ref() {
            Value::Message(inner) => Value::Message(canonical_message(inner)),
            Value::List(items) => Value::List(
                items
                    .iter()
                    .map(|item| match item {
                        Value::Message(inner) => Value::Message(canonical_message(inner)),
                        other => other.clone(),
                    })
                    .collect(),
            ),
            Value::Map(entries) => Value::Map(
                entries
                    .iter()
                    .map(|(key, item)| {
                        let item = match item {
                            Value::Message(inner) => Value::Message(canonical_message(inner)),
                            other => other.clone(),
                        };
                        (key.clone(), item)
                    })
                    .collect(),
            ),
            other => other.clone(),
        };
        out.set_field(&field, updated);
    }
    out
}

/// The protobuf binary of `message`, deterministic where prost-reflect's
/// is not: fields in number order, as prost-reflect writes them, but a
/// map's entries in the order of the Elm container that holds them
/// ([`elm_key_order`]) rather than a `HashMap`'s. Each scalar or packed
/// field and each map entry's scalar key or value is written by
/// prost-reflect itself, from a message holding it alone.
fn encode_sorted(message: &DynamicMessage) -> Vec<u8> {
    let descriptor = message.descriptor();
    let mut fields: Vec<(FieldDescriptor, Value)> = message
        .fields()
        .map(|(field, value)| (field, value.clone()))
        .collect();
    fields.sort_by_key(|(field, _)| field.number());
    let mut out = Vec::new();
    for (field, value) in fields {
        match (&value, field.kind()) {
            (Value::Map(entries), Kind::Message(entry)) => {
                let mut entries: Vec<(&MapKey, &Value)> = entries.iter().collect();
                entries.sort_by(|(a, _), (b, _)| elm_key_order(a, b));
                let key_field = entry.map_entry_key_field();
                let value_field = entry.map_entry_value_field();
                for (key, item) in entries {
                    let mut body = alone(&entry, &key_field, key.clone().into());
                    match item {
                        Value::Message(inner) => delimited(&mut body, 2, &encode_sorted(inner)),
                        item => body.extend(alone(&entry, &value_field, item.clone())),
                    }
                    delimited(&mut out, field.number(), &body);
                }
            }
            (Value::Message(inner), _) => {
                delimited(&mut out, field.number(), &encode_sorted(inner));
            }
            (Value::List(items), Kind::Message(_)) => {
                for item in items {
                    if let Value::Message(inner) = item {
                        delimited(&mut out, field.number(), &encode_sorted(inner));
                    }
                }
            }
            (value, _) => out.extend(alone(&descriptor, &field, value.clone())),
        }
    }
    out
}

/// What prost-reflect writes for `field` of a `descriptor` message
/// holding `value` and nothing else: the field's key and value, or nothing
/// for a default without presence.
fn alone(descriptor: &MessageDescriptor, field: &FieldDescriptor, value: Value) -> Vec<u8> {
    let mut message = DynamicMessage::new(descriptor.clone());
    message.set_field(field, value);
    message.encode_to_vec()
}

/// Field `number`, length-delimited, holding `body`.
fn delimited(out: &mut Vec<u8>, number: u32, body: &[u8]) {
    prost::encoding::encode_key(number, prost::encoding::WireType::LengthDelimited, out);
    prost::encoding::encode_varint(body.len() as u64, out);
    out.extend_from_slice(body);
}

/// The order of a map's keys in the Elm container the generated code
/// holds them in: a `Dict` sorts strings by UTF-16 code unit, 32-bit
/// integers by value and 64-bit integers, held as decimal text, by their
/// text; a `bool` map writes `False` first.
fn elm_key_order(a: &MapKey, b: &MapKey) -> std::cmp::Ordering {
    fn text(key: &MapKey) -> Vec<u16> {
        key_text(key).encode_utf16().collect()
    }
    match (a, b) {
        (MapKey::I32(x), MapKey::I32(y)) => x.cmp(y),
        (MapKey::U32(x), MapKey::U32(y)) => x.cmp(y),
        (MapKey::Bool(x), MapKey::Bool(y)) => x.cmp(y),
        _ => text(a).cmp(&text(b)),
    }
}

/// `json`, `message`'s canonical JSON, with each `Any` (but inside an
/// `Any`) as the generated JSON encoder writes one read from binary:
/// Connect's error-detail form, `{"type": name, "value": base64}`, or
/// `{}` for the empty `Any`.
fn binary_view(message: &DynamicMessage, json: &mut Json) {
    for (field, value) in message.fields() {
        let Some(target) = json.get_mut(field.json_name()) else {
            continue;
        };
        let each = |value: &Value, target: &mut Json| {
            if let Value::Message(inner) = value {
                if is_well_known(&kind_of_value(&field), "Any") {
                    *target = any_view(inner);
                } else if walked(&kind_of_value(&field)).is_some() {
                    binary_view(inner, target);
                }
            }
        };
        match value {
            Value::List(items) => {
                if let Json::Array(targets) = target {
                    for (item, target) in items.iter().zip(targets) {
                        each(item, target);
                    }
                }
            }
            Value::Map(entries) => {
                for (key, item) in entries {
                    if let Some(target) = target.get_mut(key_text(key)) {
                        each(item, target);
                    }
                }
            }
            value => each(value, target),
        }
    }
}

/// The kind of `field`'s values: a map's value kind, else its own.
fn kind_of_value(field: &FieldDescriptor) -> Kind {
    match field.kind() {
        Kind::Message(entry) if field.is_map() => entry.map_entry_value_field().kind(),
        kind => kind,
    }
}

fn any_view(any: &DynamicMessage) -> Json {
    let url = any
        .get_field_by_name("type_url")
        .and_then(|v| v.as_str().map(str::to_owned))
        .unwrap_or_default();
    let bytes = any
        .get_field_by_name("value")
        .and_then(|v| v.as_bytes().cloned())
        .unwrap_or_default();
    if url.is_empty() && bytes.is_empty() {
        return serde_json::json!({});
    }
    serde_json::json!({
        "type": url.rsplit('/').next().unwrap_or(&url),
        "value": base64(&bytes),
    })
}

/// Standard base64 with padding, as `Proto.Bytes.toBase64` writes it.
fn base64(bytes: &[u8]) -> String {
    const ALPHABET: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::new();
    for chunk in bytes.chunks(3) {
        let n = chunk.iter().fold(0u32, |n, b| (n << 8) | u32::from(*b)) << (8 * (3 - chunk.len()));
        for i in 0..4 {
            if i <= chunk.len() {
                out.push(ALPHABET[((n >> (18 - 6 * i)) & 63) as usize] as char);
            } else {
                out.push('=');
            }
        }
    }
    out
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// The messages given [`EDGES`] samples as well as random ones.
const EDGED: [&str; 2] = ["codec.v1.Scalars", "codec.v1.Wrappers"];

/// The number of edge samples of each of [`EDGED`]: the longest list of
/// [`edge`]'s.
const EDGES: usize = 10;

/// The `n`th edge value of kind `kind`, cycling through the bounds and
/// special values of each: what a random sample reaches only by chance.
fn edge(kind: &Kind, profile: &Profile, n: usize) -> Value {
    fn nth<T: Clone>(items: &[T], n: usize) -> T {
        items[n % items.len()].clone()
    }
    const SAFE: i64 = (1 << 53) - 1;
    match kind {
        Kind::Double => Value::F64(nth(
            &[
                f64::NAN,
                f64::INFINITY,
                f64::NEG_INFINITY,
                -0.0,
                f64::MAX,
                f64::MIN,
                f64::MIN_POSITIVE,
                5e-324,
                1e21,
                1e-7,
            ],
            n,
        )),
        Kind::Float => Value::F32(nth(
            &[
                f32::NAN,
                f32::INFINITY,
                f32::NEG_INFINITY,
                -0.0,
                f32::MAX,
                f32::MIN,
                f32::MIN_POSITIVE,
                1e-45,
                0.1,
            ],
            n,
        )),
        Kind::Int32 | Kind::Sint32 | Kind::Sfixed32 => {
            Value::I32(nth(&[i32::MIN, i32::MAX, -1, 1], n))
        }
        Kind::Uint32 | Kind::Fixed32 => Value::U32(nth(&[u32::MAX, 1], n)),
        Kind::Int64 | Kind::Sint64 | Kind::Sfixed64 if profile.wide => {
            Value::I64(nth(&[i64::MIN, i64::MAX, SAFE + 1, -SAFE - 2, SAFE, -1], n))
        }
        Kind::Int64 | Kind::Sint64 | Kind::Sfixed64 => Value::I64(nth(&[SAFE, -SAFE, -1], n)),
        Kind::Uint64 | Kind::Fixed64 if profile.wide => {
            Value::U64(nth(&[u64::MAX, 1 << 63, (1 << 53) + 1], n))
        }
        Kind::Uint64 | Kind::Fixed64 => Value::U64(nth(&[SAFE as u64, 1], n)),
        Kind::Bool => Value::Bool(true),
        Kind::String => Value::String(
            nth(
                &[
                    "\u{0}\u{1}\u{1F}\u{7F}\"\\/",
                    "😀\u{10348}中é",
                    " ",
                    "\u{2028}\n\r\t",
                ],
                n,
            )
            .to_owned(),
        ),
        // `+` and `/`, which the URL-safe alphabet writes as `-` and `_`,
        // and each length of padding.
        Kind::Bytes => Value::Bytes(
            nth(
                &[
                    &[0xFB, 0xFF][..],
                    &[0xFF, 0xFE, 0xFD],
                    &[0],
                    &[0x3E, 0x3F, 0xFF, 0x00],
                ],
                n,
            )
            .to_vec()
            .into(),
        ),
        Kind::Enum(e) => {
            let values: Vec<i32> = e.values().map(|v| v.number()).collect();
            Value::EnumNumber(nth(&values, n))
        }
        // A wrapper, finite: prost-reflect writes a `DoubleValue` or
        // `FloatValue` holding NaN or an infinity as `null`.
        Kind::Message(m) => {
            let mut message = DynamicMessage::new(m.clone());
            let field = m.get_field_by_name("value").expect("a wrapper");
            let value = match edge(&field.kind(), profile, n) {
                Value::F64(x) if x.is_nan() => Value::F64(-0.0),
                Value::F32(x) if x.is_nan() => Value::F32(-0.0),
                Value::F64(x) if x.is_infinite() => Value::F64(x.clamp(f64::MIN, f64::MAX)),
                Value::F32(x) if x.is_infinite() => Value::F32(x.clamp(f32::MIN, f32::MAX)),
                value => value,
            };
            message.set_field(&field, value);
            Value::Message(message)
        }
    }
}

/// The `n`th edge sample of `descriptor`: each singular field at its
/// `n`th [`edge`] value.
fn edge_message(descriptor: &MessageDescriptor, profile: &Profile, n: usize) -> DynamicMessage {
    let mut message = DynamicMessage::new(descriptor.clone());
    for field in descriptor.fields().filter(|f| !f.is_list() && !f.is_map()) {
        message.set_field(&field, edge(&field.kind(), profile, n));
    }
    message
}

/// The samples of every message of `codec.proto` drawn under `profile`:
/// [`per_message`] of each; for each oneof of each, one with each member
/// set, so that every member is sampled whatever the seed; and [`EDGES`]
/// of each of [`EDGED`].
fn samples(pool: &DescriptorPool, profile: &Profile) -> Vec<Sample> {
    let mut rng = Rng(SEED);
    let mut samples = Vec::new();
    for descriptor in messages(pool) {
        let name = descriptor.full_name();
        if EDGED.contains(&name) {
            for n in 0..EDGES {
                let message = edge_message(&descriptor, profile, n);
                samples.push(sample(format!("{name} edge #{n}"), message));
            }
        }
        for n in 0..per_message(profile) {
            let message = sample_message(&mut rng, profile, &descriptor, 0);
            samples.push(sample(format!("{name} #{n}"), message));
        }
        for oneof in descriptor.oneofs().filter(|o| !o.is_synthetic()) {
            for field in oneof.fields() {
                let mut message = sample_message(&mut rng, profile, &descriptor, 0);
                let value = sample_value(&mut rng, profile, &field.kind(), 0);
                message.set_field(&field, value);
                samples.push(sample(format!("{name} {}", field.name()), message));
            }
        }
    }
    samples
}

/// Each form is proto3 JSON that prost-reflect reads back as the sample it
/// was written from.
#[test]
fn every_form_reads_back_as_its_sample() {
    let pool = pool();
    let lenient = DeserializeOptions::new().deny_unknown_fields(false);
    let mut failures = Vec::new();
    for profile in [WIDE, NARROW] {
        for sample in samples(&pool, &profile) {
            let want = serialize(&sample.message, true, false);
            for (form, input) in sample.inputs() {
                match DynamicMessage::deserialize_with_options(
                    sample.message.descriptor(),
                    input.clone(),
                    &lenient,
                ) {
                    Ok(read) if serialize(&read, true, false) == want => {}
                    Ok(read) => failures.push(format!(
                        "{} ({form}): reads back as {}, not {want}",
                        sample.name,
                        serialize(&read, true, false)
                    )),
                    Err(e) => failures.push(format!("{} ({form}): {e}", sample.name)),
                }
            }
        }
    }
    assert!(failures.is_empty(), "\n{}", failures.join("\n"));
}

/// Each sample's binary is protobuf that prost-reflect reads back as the
/// sample as the binary codecs hold it ([`canonical_message`]). The
/// generated encoders must write these bytes exactly
/// (`tests/Codec/BinaryRoundTripTest.elm`), so prost-reflect reads what
/// they write. Prints how many samples prost-reflect's own encoding writes
/// byte for byte the same: all but those whose maps hold two or more
/// entries, which it writes in `HashMap` order, and those the canonical
/// form changes.
#[test]
fn every_binary_reads_back_as_its_sample() {
    let pool = pool();
    let mut failures = Vec::new();
    let (mut total, mut same) = (0, 0);
    for profile in [WIDE, NARROW] {
        for sample in samples(&pool, &profile) {
            total += 1;
            let want = canonical_message(&sample.message);
            if sample.message.encode_to_vec() == sample.binary {
                same += 1;
            }
            match DynamicMessage::decode(sample.message.descriptor(), sample.binary.as_slice()) {
                Ok(read) if serialize(&read, false, false) == serialize(&want, false, false) => {}
                Ok(read) => failures.push(format!(
                    "{}: reads back as {}, not {}",
                    sample.name,
                    serialize(&read, false, false),
                    serialize(&want, false, false)
                )),
                Err(e) => failures.push(format!("{}: {e}", sample.name)),
            }
            if encode_sorted(&want) != sample.binary {
                failures.push(format!("{}: not deterministic", sample.name));
            }
        }
    }
    eprintln!("binary oracle: {total} samples, {same} byte for byte prost-reflect's own encoding");
    assert!(failures.is_empty(), "\n{}", failures.join("\n"));
}

/// The constructs the layer is for each appear in the pinned samples, so
/// a change of seed, count or sampler cannot quietly drop one.
#[test]
fn the_samples_cover_every_construct() {
    let pool = pool();
    let text: String = samples(&pool, &WIDE)
        .iter()
        .flat_map(|s| {
            s.inputs()
                .map(|(_, input)| input.to_string())
                .collect::<Vec<_>>()
        })
        .collect::<Vec<_>>()
        .join("\n");
    let missing: Vec<&str> = COVERED
        .iter()
        .filter(|(_, needle)| !text.contains(needle))
        .map(|(construct, _)| *construct)
        .collect();
    assert!(missing.is_empty(), "not sampled: {missing:?}");
}

/// Each construct, and a piece of JSON only a sample holding it writes.
const COVERED: &[(&str, &str)] = &[
    ("json_name override", "\"overridden\":"),
    ("json_name override on a message field", "\"leafy\":{"),
    ("json_name override on a oneof member", "\"memberJson\":"),
    ("oneof message member", "\"leaf\":{"),
    ("oneof Empty member", "\"nothing\":{}"),
    ("oneof Value member", "\"json\":"),
    ("oneof int64 member", "\"big\":\""),
    ("oneof enum member", "\"kind\":\"KIND_"),
    ("oneof member under its proto name", "\"two_words\":"),
    ("Any of a message", "\"@type\":\"type.googleapis.com/codec."),
    (
        "Any of a well-known type",
        "\"@type\":\"type.googleapis.com/google.protobuf.",
    ),
    ("Struct", "\"struct\":{"),
    ("ListValue", "\"list\":["),
    ("nested enum", "\"MODE_"),
    ("other package", "\"SHADE_"),
    ("recursion", "\"left\":{"),
    ("recursion through a oneof", "\"next\":{"),
    ("bool map key", "\"true\":"),
    ("int32 map key", "\"int32Kind\":{\""),
    ("uint64 map key", "\"uint64String\":{\""),
    ("NaN", "\"NaN\""),
    ("-Infinity", "\"-Infinity\""),
    ("C0 control", "\\u0000"),
    ("wrapper", "\"int64\":\""),
];

// The Elm data.

/// The generated tree, under the repository.
const GENERATED: &str = "tests/Generated/Codec";

/// Writes `content` to the file at `path` under the repository unless it
/// holds it already, so a run that changes nothing leaves the Elm
/// compiler's cache valid.
fn write(path: &str, content: &str) {
    let file = repo_root().join(path);
    if fs::read_to_string(&file).is_ok_and(|have| have == content) {
        return;
    }
    fs::create_dir_all(file.parent().expect("a parent")).expect("create");
    fs::write(&file, content).unwrap_or_else(|e| panic!("write {}: {e}", file.display()));
}

fn import(name: &str) -> Import {
    Import {
        module: ModuleName::new(name),
        alias: None,
        exposing: None,
    }
}

fn maybe_json(json: &Option<Json>) -> Expr {
    match json {
        None => var("Nothing"),
        Some(json) => apply(var("Just"), [string(json.to_string())]),
    }
}

/// The samples as an Elm module `name` of `Codec.RoundTrip.Sample`s.
fn data_module(name: &str, profile: &str, samples: &[Sample]) -> Module {
    let items = samples.iter().map(|sample| {
        let forms = sample.forms.iter().map(|form| {
            record([
                ("form", string(form.form)),
                ("input", string(form.input.to_string())),
                ("expected", maybe_json(&form.expected)),
            ])
        });
        record([
            ("name", string(sample.name.clone())),
            (
                "message",
                string(sample.message.descriptor().full_name().to_owned()),
            ),
            ("canonical", string(sample.canonical.to_string())),
            ("expected", maybe_json(&sample.expected)),
            ("forms", list(forms)),
            ("binary", string(hex(&sample.binary))),
            ("binaryJson", maybe_json(&sample.binary_json)),
        ])
    });
    Module {
        header: Some(format!(
            "Generated by the codec test (crates/elm-connect-gen/tests/codec.rs): the messages \
             of conformance/codec/codec.proto sampled {profile}, as prost-reflect writes them, \
             and what the generated encoders write back. Do not edit; `just codec-gen` \
             rewrites it."
        )),
        name: ModuleName::new(name),
        doc: None,
        exposing: Exposing::All,
        imports: vec![import("Codec.RoundTrip")],
        decls: vec![Decl::Value {
            doc: None,
            name: "samples".into(),
            annotation: ty("List", [ty_qualified("Codec.RoundTrip", "Sample", [])]),
            params: Vec::new(),
            body: Expr::List(items.collect()),
        }],
    }
}

/// Each option set's codecs of every sampled message, by full name: the
/// JSON codecs of the sets that have them (`default`, ...), and the binary
/// codecs of those that have them (`bothBinary`, ...), beside the JSON
/// codecs where the set has both.
fn codecs_module(pool: &DescriptorPool) -> Module {
    let mut imports = vec![import("Codec.RoundTrip"), import("Codec.BinaryRoundTrip")];
    let mut decls = Vec::new();
    for set in &SETS {
        let module = format!("Generated.Codec.{}.Codec.V1", set.prefix);
        imports.push(import(&module));
        let value = |name: String| qualified(module.as_str(), name);
        if set.json {
            let rows = messages(pool).into_iter().map(|descriptor| {
                tuple2(
                    string(descriptor.full_name().to_owned()),
                    apply(
                        qualified("Codec.RoundTrip", "codec"),
                        [
                            value(format!("decode{}", descriptor.name())),
                            value(format!("encode{}", descriptor.name())),
                        ],
                    ),
                )
            });
            decls.push(table(set.table.to_owned(), "Codec.RoundTrip", list(rows)));
        }
        if set.binary {
            let rows = messages(pool).into_iter().map(|descriptor| {
                let name = descriptor.name();
                let row = if set.json {
                    apply(
                        qualified("Codec.BinaryRoundTrip", "both"),
                        [
                            value(format!("decode{name}Bytes")),
                            value(format!("encode{name}Bytes")),
                            value(format!("decode{name}")),
                            value(format!("encode{name}")),
                        ],
                    )
                } else {
                    apply(
                        qualified("Codec.BinaryRoundTrip", "binaryOnly"),
                        [
                            value(format!("decode{name}Bytes")),
                            value(format!("encode{name}Bytes")),
                        ],
                    )
                };
                tuple2(string(descriptor.full_name().to_owned()), row)
            });
            decls.push(table(
                format!("{}Binary", set.table),
                "Codec.BinaryRoundTrip",
                list(rows),
            ));
        }
    }
    Module {
        header: Some(
            "Generated by the codec test (crates/elm-connect-gen/tests/codec.rs): the codecs of \
             each message of conformance/codec/codec.proto under each option set. Do not edit; \
             `just codec-gen` rewrites it."
                .into(),
        ),
        name: ModuleName::new("Generated.Codec.Codecs"),
        doc: None,
        exposing: Exposing::All,
        imports,
        decls,
    }
}

/// `name : List ( String, <module>.Codec )` holding `rows`.
fn table(name: String, module: &str, rows: Expr) -> Decl {
    Decl::Value {
        doc: None,
        name,
        annotation: ty(
            "List",
            [Type::Tuple(vec![
                ty("String", []),
                ty_qualified(module, "Codec", []),
            ])],
        ),
        params: Vec::new(),
        body: rows,
    }
}

#[test]
fn the_codec_round_trips_are_written() {
    let pool = pool();
    let print = elm_connect_gen::elm::print::print_module;
    let mut written = Vec::new();
    let mut emit = |path: String, content: &str| {
        write(&path, content);
        written.push(path);
    };
    for set in &SETS {
        let generated = generate(&pool, &PROTOS, &set.options())
            .unwrap_or_else(|d| panic!("{}", elm_connect_gen::diagnostics::render_narrow(&d)));
        for module in &generated.files {
            let path = format!("tests/{}", module.path);
            assert!(
                path.starts_with(&format!("{GENERATED}/{}/", set.prefix)),
                "{path} is outside {GENERATED}/{}",
                set.prefix
            );
            emit(path, &module.content);
        }
    }
    let data = [
        (
            "Generated.Codec.Data",
            "with 64-bit integers over their whole range",
            WIDE,
        ),
        (
            "Generated.Codec.DataInt64Int",
            "with 64-bit integers within ±(2^53 − 1), for int64=int",
            NARROW,
        ),
    ];
    for (name, profile_text, profile) in data {
        let module = data_module(name, profile_text, &samples(&pool, &profile));
        emit(
            format!("tests/{}.elm", name.replace('.', "/")),
            &print(&module),
        );
    }
    emit(
        format!("{GENERATED}/Codecs.elm"),
        &print(&codecs_module(&pool)),
    );
    // A module this run did not write is left from an earlier generator
    // or proto, and would still compile into the Elm tests.
    let root = repo_root().join(GENERATED);
    for stale in files_under(&root)
        .into_iter()
        .filter(|path| !written.contains(&format!("{GENERATED}/{path}")))
    {
        fs::remove_file(root.join(&stale)).expect("remove a stale module");
    }
}
