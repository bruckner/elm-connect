//! Sampling messages of any shape from their prost-reflect descriptors,
//! from a fixed seed: the route properties (`routes.rs`) and the codec
//! round trips (`codec.rs`) share it, each through a [`Profile`].

use prost::Message;
use prost_reflect::{DynamicMessage, Kind, MapKey, MessageDescriptor, Value};
use serde_json::Value as Json;

/// What a sampler draws from.
#[derive(Clone, Copy, Debug)]
pub struct Profile {
    /// The characters strings and map keys are drawn from. Only assigned
    /// characters: elm-format escapes unassigned ones, which the printer
    /// does not know.
    pub chars: &'static str,
    /// Whether 64-bit integers range over their whole type, or stay within
    /// ±(2^53 − 1), which an Elm `Int` holds exactly (`int64=int`).
    pub wide: bool,
    /// Past this many levels down, messages are left empty.
    pub depth: usize,
    /// Repeated and map fields hold fewer elements than this.
    pub items: u64,
}

/// SplitMix64: a generator whose sequence is fixed by its definition, so
/// the pinned samples cannot change with a dependency's release, as
/// `rand`'s `StdRng` may.
pub struct Rng(pub u64);

impl Rng {
    pub fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    /// A number in `0..n`.
    pub fn below(&mut self, n: u64) -> u64 {
        self.next() % n
    }

    /// A number in `low..=high`.
    pub fn range(&mut self, low: i64, high: i64) -> i64 {
        low + (self.next() % ((high - low) as u64 + 1)) as i64
    }

    /// True one time in `n`.
    pub fn one_in(&mut self, n: u64) -> bool {
        self.below(n) == 0
    }

    pub fn pick<T: Clone>(&mut self, items: &[T]) -> T {
        items[self.below(items.len() as u64) as usize].clone()
    }
}

/// The largest integer a double, and so an Elm `Int`, holds exactly.
const SAFE: i64 = (1 << 53) - 1;

/// A short string of the profile's characters, or empty.
pub fn sample_string(rng: &mut Rng, profile: &Profile) -> String {
    let chars: Vec<char> = profile.chars.chars().collect();
    let length = rng.pick(&[0, 1, 2, 3, 5, 8]);
    (0..length).map(|_| rng.pick(&chars)).collect()
}

pub fn sample_i32(rng: &mut Rng) -> i32 {
    match rng.below(4) {
        0 => rng.pick(&[i32::MIN, i32::MAX, -1, 1]),
        1 => rng.range(-1000, 1000) as i32,
        _ => rng.next() as i32,
    }
}

pub fn sample_i64(rng: &mut Rng, profile: &Profile) -> i64 {
    if !profile.wide {
        return match rng.below(4) {
            0 => rng.pick(&[SAFE, -SAFE, -1, 1]),
            1 => rng.range(-1000, 1000),
            _ => rng.range(-SAFE, SAFE),
        };
    }
    match rng.below(4) {
        0 => rng.pick(&[i64::MIN, i64::MAX, SAFE, SAFE + 1, SAFE + 2, -SAFE - 2]),
        1 => rng.range(-1000, 1000),
        _ => rng.next() as i64,
    }
}

pub fn sample_u64(rng: &mut Rng, profile: &Profile) -> u64 {
    if !profile.wide {
        return match rng.below(4) {
            0 => rng.pick(&[SAFE as u64, 1]),
            1 => rng.below(1000),
            _ => rng.below(SAFE as u64 + 1),
        };
    }
    match rng.below(4) {
        0 => rng.pick(&[u64::MAX, 1 << 63, (1 << 53) + 1, 1]),
        1 => rng.below(1000),
        _ => rng.next(),
    }
}

/// A double: the non-finite values, the extremes, `-0` and every magnitude
/// between.
pub fn sample_f64(rng: &mut Rng) -> f64 {
    match rng.below(4) {
        0 => rng.pick(&[
            f64::NAN,
            f64::INFINITY,
            f64::NEG_INFINITY,
            f64::MAX,
            f64::MIN,
            f64::MIN_POSITIVE,
            5e-324,
            1e21,
            1e-7,
            0.1,
            -0.0,
        ]),
        1 => rng.range(-1000, 1000) as f64 / 8.0,
        _ => {
            let x = f64::from_bits(rng.next());
            if x.is_finite() && x != 0.0 { x } else { 1.5 }
        }
    }
}

pub fn sample_f32(rng: &mut Rng) -> f32 {
    match rng.below(4) {
        0 => rng.pick(&[f32::NAN, f32::INFINITY, f32::NEG_INFINITY, f32::MAX, 0.1]),
        1 => rng.range(-1000, 1000) as f32 / 8.0,
        _ => {
            let x = f32::from_bits(rng.next() as u32);
            if x.is_finite() && x != 0.0 { x } else { 1.5 }
        }
    }
}

/// A field mask path of proto field names whose lowerCamelCase form reads
/// back as it: lowercase words, each starting with a letter.
pub fn sample_path(rng: &mut Rng) -> String {
    let word = |rng: &mut Rng| -> String {
        let length = rng.range(1, 4);
        (0..length)
            .map(|i| {
                if i == 0 || rng.below(3) > 0 {
                    (b'a' + rng.below(26) as u8) as char
                } else {
                    (b'0' + rng.below(10) as u8) as char
                }
            })
            .collect()
    };
    (0..rng.range(1, 3))
        .map(|_| {
            (0..rng.range(1, 2))
                .map(|_| word(rng))
                .collect::<Vec<_>>()
                .join("_")
        })
        .collect::<Vec<_>>()
        .join(".")
}

/// A JSON value for a `google.protobuf.Value`: every JSON type, numbers
/// finite (proto3 JSON has no text for a `Value` holding NaN or an
/// infinity), objects and arrays nested `depth` levels down at most.
pub fn sample_json(rng: &mut Rng, profile: &Profile, depth: usize) -> Json {
    let kinds = if depth == 0 { 4 } else { 6 };
    match rng.below(kinds) {
        0 => Json::Null,
        1 => Json::Bool(rng.one_in(2)),
        2 => {
            let x = sample_f64(rng);
            serde_json::json!(if x.is_finite() { x } else { 0.5 })
        }
        3 => Json::String(sample_string(rng, profile)),
        4 => Json::Array(
            (0..rng.below(profile.items))
                .map(|_| sample_json(rng, profile, depth - 1))
                .collect(),
        ),
        _ => Json::Object(
            (0..rng.below(profile.items))
                .map(|_| {
                    (
                        sample_string(rng, profile),
                        sample_json(rng, profile, depth - 1),
                    )
                })
                .collect(),
        ),
    }
}

/// The messages of `descriptor`'s file that an `Any` may hold: the file's
/// own and the well-known types with a JSON form of their own.
fn any_payloads(descriptor: &MessageDescriptor) -> Vec<MessageDescriptor> {
    let pool = descriptor.parent_pool();
    let mut payloads: Vec<MessageDescriptor> = pool
        .files()
        .filter(|file| !file.package_name().starts_with("google."))
        .flat_map(|file| file.messages().collect::<Vec<_>>())
        .collect();
    payloads.sort_by(|a, b| a.full_name().cmp(b.full_name()));
    for name in ["Duration", "Timestamp", "Struct", "Int64Value", "Empty"] {
        if let Some(message) = pool.get_message_by_name(&format!("google.protobuf.{name}")) {
            payloads.push(message);
        }
    }
    payloads
}

/// A well-known type with a JSON form of its own, sampled within what the
/// runtime holds exactly; `None` for any other message.
pub fn sample_well_known(
    rng: &mut Rng,
    profile: &Profile,
    descriptor: &MessageDescriptor,
    depth: usize,
) -> Option<DynamicMessage> {
    let mut message = DynamicMessage::new(descriptor.clone());
    match descriptor.full_name() {
        // To the millisecond, which `Time.Posix` holds; finer digits are
        // truncated by design (§3.5).
        "google.protobuf.Timestamp" => {
            let any = rng.range(-62_135_596_800, 253_402_300_799);
            let seconds = rng.pick(&[-62_135_596_800, 253_402_300_799, 0, any, any]);
            message.set_field_by_name("seconds", Value::I64(seconds));
            message.set_field_by_name("nanos", Value::I32(rng.range(0, 999) as i32 * 1_000_000));
        }
        "google.protobuf.Duration" => {
            let negative = rng.one_in(2);
            let any = rng.range(0, 315_576_000_000);
            let seconds = rng.pick(&[0, 1, 315_576_000_000, any, any]);
            let nanos = match rng.below(4) {
                0 => 0,
                1 => rng.range(0, 999) * 1_000_000,
                2 => rng.range(0, 999_999) * 1_000,
                _ => rng.range(0, 999_999_999),
            };
            let sign = if negative { -1 } else { 1 };
            message.set_field_by_name("seconds", Value::I64(sign * seconds));
            message.set_field_by_name("nanos", Value::I32((sign * nanos) as i32));
        }
        "google.protobuf.FieldMask" => {
            let paths = (0..rng.range(0, 3))
                .map(|_| Value::String(sample_path(rng)))
                .collect();
            message.set_field_by_name("paths", Value::List(paths));
        }
        "google.protobuf.Struct" | "google.protobuf.Value" | "google.protobuf.ListValue" => {
            let json = match descriptor.name() {
                "Struct" => Json::Object(
                    (0..rng.below(profile.items))
                        .map(|_| (sample_string(rng, profile), sample_json(rng, profile, 2)))
                        .collect(),
                ),
                "ListValue" => Json::Array(
                    (0..rng.below(profile.items))
                        .map(|_| sample_json(rng, profile, 2))
                        .collect(),
                ),
                _ => sample_json(rng, profile, 2),
            };
            message = DynamicMessage::deserialize(descriptor.clone(), json)
                .expect("JSON is a Struct, ListValue or Value");
        }
        // Set: a message of the same file, or a well-known type, packed. An
        // `Any` with no type URL has no proto3 JSON form but `{}`, which
        // the field's presence covers (a set field holding `{}`).
        "google.protobuf.Any" => {
            let payload = rng.pick(&any_payloads(descriptor));
            let inner = sample_message(rng, profile, &payload, depth + 1);
            message.set_field_by_name(
                "type_url",
                Value::String(format!("type.googleapis.com/{}", payload.full_name())),
            );
            message.set_field_by_name("value", Value::Bytes(inner.encode_to_vec().into()));
        }
        name if name.starts_with("google.protobuf.") && name.ends_with("Value") => {
            // A wrapper: at its default a third of the time. Finite:
            // prost-reflect writes a `DoubleValue` or `FloatValue` holding
            // NaN or an infinity as `null`, not as proto3 JSON's string.
            let field = descriptor.get_field_by_name("value").expect("a wrapper");
            if !rng.one_in(3) {
                let value = match sample_value(rng, profile, &field.kind(), 0) {
                    Value::F64(x) if !x.is_finite() => Value::F64(1.5),
                    Value::F32(x) if !x.is_finite() => Value::F32(1.5),
                    value => value,
                };
                message.set_field(&field, value);
            }
        }
        _ => return None,
    }
    Some(message)
}

/// A value of kind `kind`; a message `depth` levels down.
pub fn sample_value(rng: &mut Rng, profile: &Profile, kind: &Kind, depth: usize) -> Value {
    match kind {
        Kind::Double => Value::F64(sample_f64(rng)),
        Kind::Float => Value::F32(sample_f32(rng)),
        Kind::Int32 | Kind::Sint32 | Kind::Sfixed32 => Value::I32(sample_i32(rng)),
        Kind::Int64 | Kind::Sint64 | Kind::Sfixed64 => Value::I64(sample_i64(rng, profile)),
        Kind::Uint32 | Kind::Fixed32 => Value::U32(rng.next() as u32),
        Kind::Uint64 | Kind::Fixed64 => Value::U64(sample_u64(rng, profile)),
        Kind::Bool => Value::Bool(rng.one_in(2)),
        Kind::String => Value::String(sample_string(rng, profile)),
        Kind::Bytes => Value::Bytes(
            (0..rng.below(7))
                .map(|_| rng.next() as u8)
                .collect::<Vec<u8>>()
                .into(),
        ),
        Kind::Enum(descriptor) => {
            let values: Vec<i32> = descriptor.values().map(|v| v.number()).collect();
            Value::EnumNumber(rng.pick(&values))
        }
        Kind::Message(descriptor) => {
            Value::Message(sample_message(rng, profile, descriptor, depth + 1))
        }
    }
}

/// A map key of kind `kind`. Keys stay strings on the wire whatever the
/// option, so 64-bit keys range over their whole type in every profile.
pub fn sample_key(rng: &mut Rng, profile: &Profile, kind: &Kind) -> MapKey {
    let wide = Profile {
        wide: true,
        ..*profile
    };
    match kind {
        Kind::String => MapKey::String(sample_string(rng, profile)),
        Kind::Bool => MapKey::Bool(rng.one_in(2)),
        Kind::Int32 | Kind::Sint32 | Kind::Sfixed32 => MapKey::I32(sample_i32(rng)),
        Kind::Int64 | Kind::Sint64 | Kind::Sfixed64 => MapKey::I64(sample_i64(rng, &wide)),
        Kind::Uint32 | Kind::Fixed32 => MapKey::U32(rng.next() as u32),
        Kind::Uint64 | Kind::Fixed64 => MapKey::U64(sample_u64(rng, &wide)),
        other => panic!("no map key of kind {other:?}"),
    }
}

/// A message of type `descriptor`: each field without presence at its
/// default about a third of the time; each field with presence unset, set
/// to its default (a message set but empty), or set; a oneof unset or one
/// member set; repeated and map fields with fewer than the profile's
/// `items` elements. Past the profile's `depth`, messages are left empty.
pub fn sample_message(
    rng: &mut Rng,
    profile: &Profile,
    descriptor: &MessageDescriptor,
    depth: usize,
) -> DynamicMessage {
    if let Some(message) = sample_well_known(rng, profile, descriptor, depth) {
        return message;
    }
    let mut message = DynamicMessage::new(descriptor.clone());
    if depth > profile.depth {
        return message;
    }
    for oneof in descriptor.oneofs().filter(|o| !o.is_synthetic()) {
        let members: Vec<_> = oneof.fields().collect();
        let choice = rng.below(members.len() as u64 + 1) as usize;
        if let Some(field) = members.get(choice) {
            // A set member at its default is still set.
            let value = if rng.one_in(3) && has_default_json(&field.kind()) {
                Value::default_value(&field.kind())
            } else {
                sample_value(rng, profile, &field.kind(), depth)
            };
            message.set_field(field, value);
        }
    }
    for field in descriptor.fields() {
        if field
            .containing_oneof()
            .is_some_and(|oneof| !oneof.is_synthetic())
        {
            continue;
        }
        let kind = field.kind();
        let value = if field.is_map() {
            let Kind::Message(entry) = &kind else {
                unreachable!()
            };
            let key_kind = entry.map_entry_key_field().kind();
            let value_kind = entry.map_entry_value_field().kind();
            let entries = (0..rng.below(profile.items))
                .map(|_| {
                    (
                        sample_key(rng, profile, &key_kind),
                        sample_value(rng, profile, &value_kind, depth),
                    )
                })
                .collect();
            Some(Value::Map(entries))
        } else if field.is_list() {
            Some(Value::List(
                (0..rng.below(profile.items))
                    .map(|_| sample_value(rng, profile, &kind, depth))
                    .collect(),
            ))
        } else if field.supports_presence() {
            match rng.below(3) {
                0 => None,
                1 if has_default_json(&kind) => Some(Value::default_value(&kind)),
                _ => Some(sample_value(rng, profile, &kind, depth)),
            }
        } else if rng.one_in(3) {
            None
        } else {
            Some(sample_value(rng, profile, &kind, depth))
        };
        if let Some(value) = value {
            message.set_field(&field, value);
        }
    }
    message
}

/// Whether a value of kind `kind` at its default has a proto3 JSON form:
/// all but an `Any` with no type URL, which prost-reflect cannot write.
fn has_default_json(kind: &Kind) -> bool {
    !matches!(kind, Kind::Message(m) if m.full_name() == "google.protobuf.Any")
}
