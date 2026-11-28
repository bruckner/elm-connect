//! A field's shape, and the Elm type, encoder and decoder that follow
//! from it.

use super::scalar::{Holding, Repr};
use super::{
    CORE_DICT, CORE_STRING, Emitter, JSON_DECODE, PROTO_ANY, PROTO_DURATION, PROTO_JSON_DECODE,
    PROTO_JSON_ENCODE, PROTO_TIMESTAMP, PROTO_VALUE, call, scalar,
};
use crate::elm::ast::{Expr, Type};
use crate::elm::build::{apply, lambda, list, pvar, qualified, ty, var};
use crate::naming::{MAP_VALUE, REGISTRY_ARGUMENT, with_registry};

use std::collections::HashMap;

use crate::options::Int64;

use crate::ir::{
    Cardinality, Field, JsType, MapKey, Message, ScalarKind, TypeName, TypeRef, WellKnown, Wrapper,
};

/// A field as the emitter supports it: what [`field_shape`] classifies an
/// IR field into once, so that the type, the encoder and the decoder of
/// the field match on a closed set and report nothing.
#[derive(Clone, Copy, Debug)]
pub(super) enum FieldShape<'p> {
    /// One value without presence, which reads as its zero value when
    /// absent or `null`.
    Plain(Zeroed<'p>),
    /// `Maybe`: a field with presence (proto3 `optional`, or of a
    /// [`Present`] type), `Nothing` when absent or `null`.
    Maybe(ValueShape<'p>),
    /// `List`: a repeated field, `[]` when absent or `null`.
    List(ValueShape<'p>),
    /// `Dict`: a map field, `Dict.empty` when absent or `null`.
    Dict(KeyShape, ValueShape<'p>),
    /// `List ( Bool, v )`: a map field with `bool` keys, which cannot key a
    /// `Dict` since Elm's `Bool` is not `comparable`; `[]` when absent or
    /// `null` (design §3.2).
    BoolMap(ValueShape<'p>),
    /// `Maybe Proto.Value.Value`: a singular or `optional` field of
    /// `google.protobuf.Value`, `Nothing` when absent and `Just` its value
    /// otherwise, `ValueNull` included, since `null` is one of a `Value`'s own
    /// values and protobuf's parsers read a field holding it as set
    /// (design §3.5).
    Json,
}

/// The keys of a map field held in a `Dict`, by the decoder that reads
/// them. JSON object keys are strings whatever the proto key type; an
/// integer key is checked against its type's range, and two keys that
/// name one integer fail (design §3.2).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum KeyShape {
    /// `String`: `string` keys, refused when one holds a surrogate
    /// without its pair, as a `string` value is.
    String,
    /// `Int`: signed 32-bit integer keys.
    Int32,
    /// `Int`: unsigned 32-bit integer keys.
    UInt32,
    /// `String`: signed 64-bit integer keys, held as canonical decimal
    /// strings like 64-bit values under either `int64` option (design
    /// §3.4).
    Int64,
    /// `String`: unsigned 64-bit integer keys, likewise.
    UInt64,
}

impl KeyShape {
    /// The `Dict` key for `key`; `None` for `bool`, which has none.
    fn of(key: MapKey) -> Option<Self> {
        Some(match key {
            MapKey::String => KeyShape::String,
            MapKey::Int32 | MapKey::SInt32 | MapKey::SFixed32 => KeyShape::Int32,
            MapKey::UInt32 | MapKey::Fixed32 => KeyShape::UInt32,
            MapKey::Int64 | MapKey::SInt64 | MapKey::SFixed64 => KeyShape::Int64,
            MapKey::UInt64 | MapKey::Fixed64 => KeyShape::UInt64,
            MapKey::Bool => return None,
        })
    }

    /// Whether Elm holds the key as an `Int`, rather than a `String`.
    fn is_int(self) -> bool {
        matches!(self, KeyShape::Int32 | KeyShape::UInt32)
    }
}

/// The type of a field's values, as the emitter supports it.
#[derive(Clone, Copy, Debug)]
pub(super) enum ValueShape<'p> {
    /// A type with a zero value, held directly by a singular field.
    Zeroed(Zeroed<'p>),
    /// A type a singular field holds with presence, as a `Maybe`.
    Present(Present<'p>),
}

/// A type with a zero value, which a singular field without presence
/// holds directly and reads when absent or `null`.
#[derive(Clone, Copy, Debug)]
pub(super) enum Zeroed<'p> {
    /// A proto scalar, held as this, whose zero value is proto3's.
    Scalar(Repr),
    /// A generated enum, whose zero value is this constructor.
    Enum(&'p TypeName, &'p str),
    /// `google.protobuf.Value`: any JSON, held as a `Proto.Value.Value`.
    /// A list, map or oneof member holds it bare; a singular or `optional`
    /// field holds it as [`FieldShape::Json`], never as
    /// [`FieldShape::Plain`], since `null` is a value it can be set to
    /// (design §3.5).
    Json,
    /// `google.protobuf.Empty`: `()`, which carries nothing, so a singular
    /// field of it has no presence either: absent, `null` and `{}` all read
    /// as `()` (design §3.5). A oneof member of it is a constructor without
    /// arguments.
    Empty,
    /// `google.protobuf.NullValue`: `()`, as for [`Zeroed::Empty`], since
    /// its one value carries nothing; a singular field of it, `optional`
    /// too, has no presence, and its zero value is never written. It is
    /// written `null`, which also sets a oneof member of it (design §3.5).
    Null,
}

/// A message type, which a singular field holds with presence (design
/// §3.2): a generated message, or a well-known type mapped to an Elm type
/// of its own (design §3.5).
#[derive(Clone, Copy, Debug)]
pub(super) enum Present<'p> {
    /// A generated message.
    Message(&'p TypeName),
    /// A recursive message, held in its wrapper because the field closes a
    /// cycle of record fields ([`Field::cyclic`]), with the message's full
    /// name.
    Wrapped(&'p Wrapper, &'p str),
    /// A wrapper such as `google.protobuf.Int32Value`: its scalar, which
    /// is left out of the JSON when unset.
    Wrapper(Repr),
    /// `google.protobuf.Timestamp`: `Proto.Timestamp.Timestamp`.
    Timestamp,
    /// `google.protobuf.Duration`: the runtime's `Duration`.
    Duration,
    /// `google.protobuf.FieldMask`: its paths, a `List String`.
    FieldMask,
    /// `google.protobuf.Struct`: a JSON object, a
    /// `Dict String Proto.Value.Value`.
    Struct,
    /// `google.protobuf.ListValue`: a JSON array, a
    /// `List Proto.Value.Value`.
    ListValue,
    /// `google.protobuf.Any`: the runtime's `Proto.Any.Any`, holding JSON
    /// under `codec=json` and binary otherwise.
    Any,
}

/// The shape of a well-known type's values; `holding` says how the 64-bit
/// and bytes wrappers hold their value.
fn well_known(well_known: WellKnown, holding: Holding) -> ValueShape<'static> {
    let wrapper = |kind| Present::Wrapper(scalar::repr(kind, holding));
    let present = match well_known {
        WellKnown::Value => return ValueShape::Zeroed(Zeroed::Json),
        WellKnown::Struct => Present::Struct,
        WellKnown::ListValue => Present::ListValue,
        WellKnown::Timestamp => Present::Timestamp,
        WellKnown::Duration => Present::Duration,
        WellKnown::FieldMask => Present::FieldMask,
        WellKnown::Empty => return ValueShape::Zeroed(Zeroed::Empty),
        WellKnown::Any => Present::Any,
        WellKnown::DoubleValue => wrapper(ScalarKind::Double),
        WellKnown::FloatValue => wrapper(ScalarKind::Float),
        WellKnown::Int64Value => wrapper(ScalarKind::Int64),
        WellKnown::UInt64Value => wrapper(ScalarKind::UInt64),
        WellKnown::Int32Value => wrapper(ScalarKind::Int32),
        WellKnown::UInt32Value => wrapper(ScalarKind::UInt32),
        WellKnown::BoolValue => wrapper(ScalarKind::Bool),
        WellKnown::StringValue => wrapper(ScalarKind::String),
        WellKnown::BytesValue => wrapper(ScalarKind::Bytes),
        WellKnown::NullValue => return ValueShape::Zeroed(Zeroed::Null),
    };
    ValueShape::Present(present)
}

impl Emitter {
    /// The Elm type of a field.
    pub(super) fn field_type(&mut self, shape: FieldShape) -> Type {
        match shape {
            FieldShape::Plain(zeroed) => self.value_type(ValueShape::Zeroed(zeroed)),
            FieldShape::Maybe(value) => ty(self.core("Maybe"), [self.value_type(value)]),
            FieldShape::Json => {
                let value = self.value_type(ValueShape::Zeroed(Zeroed::Json));
                ty(self.core("Maybe"), [value])
            }
            FieldShape::List(value) => ty(self.core("List"), [self.value_type(value)]),
            FieldShape::Dict(key, value) => {
                let key = if key.is_int() {
                    ty(self.core("Int"), [])
                } else {
                    ty(self.core("String"), [])
                };
                let value = self.value_type(value);
                self.dict(key, value)
            }
            FieldShape::BoolMap(value) => ty(
                self.core("List"),
                [Type::Tuple(vec![
                    ty(self.core("Bool"), []),
                    self.value_type(value),
                ])],
            ),
        }
    }

    /// The JSON of a field whose Elm value is `value`, as a
    /// `Maybe Json.Encode.Value` for `Proto.Json.Encode.plainObject`: `Nothing` when
    /// the field is left out (design §3.2). A field without presence is
    /// left out at its proto3 default, a field with presence when
    /// `Nothing`, a repeated or map field when empty. A field of
    /// `google.protobuf.Value` is its value's JSON when `Just`, so
    /// `Just ValueNull` writes `null`. A field of
    /// `google.protobuf.Empty` is always written, as `{}`: Elm holds it as
    /// `()`, without the presence its proto type has, and writing it keeps
    /// it set (design §3.5).
    pub(super) fn encode_field(&mut self, shape: FieldShape, value: Expr) -> Expr {
        let (helper, args) = match shape {
            FieldShape::Json => unreachable!("a field of google.protobuf.Value can be refused"),
            FieldShape::Plain(Zeroed::Empty) => {
                let encoded = self.encode_value(ValueShape::Zeroed(Zeroed::Empty), value);
                return apply(var(self.core("Just")), [encoded]);
            }
            FieldShape::Plain(Zeroed::Scalar(Repr::Float | Repr::Float32)) => {
                return apply(
                    self.reference((PROTO_JSON_ENCODE, "implicitDouble")),
                    [value],
                );
            }
            // Not `implicit`, which compares with `==`: Elm finds any two
            // `Bytes` equal, so every value would read as the default.
            FieldShape::Plain(Zeroed::Scalar(Repr::BytesAsBytes)) => {
                return apply(
                    self.reference((PROTO_JSON_ENCODE, "implicitBytes")),
                    [value],
                );
            }
            FieldShape::Plain(zeroed) => {
                let zero = self.field_default(shape);
                let encoder = self.value_encoder(ValueShape::Zeroed(zeroed));
                (
                    self.reference((PROTO_JSON_ENCODE, "implicit")),
                    vec![zero, encoder],
                )
            }
            FieldShape::Maybe(inner) => match self.total_message_encoder(inner) {
                Some(encoder) => (
                    self.reference((PROTO_JSON_ENCODE, "totalOptional")),
                    vec![encoder],
                ),
                None => {
                    let encoder = self.value_encoder(inner);
                    (qualified("Maybe", "map"), vec![encoder])
                }
            },
            FieldShape::List(inner) => match self.total_message_encoder(inner) {
                Some(encoder) => (
                    self.reference((PROTO_JSON_ENCODE, "totalRepeated")),
                    vec![encoder],
                ),
                None => {
                    let encoder = self.value_encoder(inner);
                    (
                        self.reference((PROTO_JSON_ENCODE, "plainRepeated")),
                        vec![encoder],
                    )
                }
            },
            FieldShape::Dict(key, inner) => {
                let key = if key.is_int() {
                    qualified(CORE_STRING, "fromInt")
                } else {
                    var("identity")
                };
                let encoder = self.map_value_encoder(inner);
                (
                    self.reference((PROTO_JSON_ENCODE, "plainDict")),
                    vec![key, encoder],
                )
            }
            FieldShape::BoolMap(inner) => {
                let encoder = self.map_value_encoder(inner);
                (
                    self.reference((PROTO_JSON_ENCODE, "plainBoolMap")),
                    vec![encoder],
                )
            }
        };
        apply(helper, args.into_iter().chain([value]))
    }

    /// A field whose write can be refused, as a `Proto.Json.Encode.Field` for a
    /// run of `Proto.Json.Encode.checkedFields`: the checked helper of its kind
    /// with its values' encoder.
    pub(super) fn write_field(&mut self, shape: FieldShape, value: Expr) -> Expr {
        let (helper, args) = match shape {
            FieldShape::Json => {
                let encoder = self.reference((PROTO_JSON_ENCODE, "value"));
                ("optional", vec![encoder])
            }
            FieldShape::Maybe(inner) => {
                let encoder = self.value_encoder(inner);
                ("optional", vec![encoder])
            }
            FieldShape::List(inner) => {
                let encoder = self.value_encoder(inner);
                ("repeated", vec![encoder])
            }
            FieldShape::Dict(key, inner) => {
                let encoder = self.value_encoder(inner);
                let key = if key.is_int() {
                    qualified(CORE_STRING, "fromInt")
                } else {
                    var("identity")
                };
                ("dict", vec![key, encoder])
            }
            FieldShape::BoolMap(inner) => {
                let encoder = self.value_encoder(inner);
                ("boolMap", vec![encoder])
            }
            FieldShape::Plain(_) => unreachable!("a field without presence cannot be refused"),
        };
        let helper = self.reference((PROTO_JSON_ENCODE, helper));
        apply(helper, args.into_iter().chain([value]))
    }

    /// Whether a field's write can be refused ([`Self::write_reaches`]).
    pub(super) fn field_write_reaches(&self, shape: FieldShape) -> bool {
        match shape {
            FieldShape::Maybe(value)
            | FieldShape::List(value)
            | FieldShape::Dict(_, value)
            | FieldShape::BoolMap(value) => self.write_reaches(value),
            FieldShape::Json => true,
            FieldShape::Plain(_) => false,
        }
    }

    /// Whether a value's JSON write can be refused: an `Any`; a well-known
    /// type whose Elm values can have no proto3 JSON form
    /// ([`crate::ir::reach::checked`]); a message that holds one of these,
    /// at any depth.
    pub(super) fn write_reaches(&self, value: ValueShape) -> bool {
        match value {
            ValueShape::Present(Present::Any) => true,
            ValueShape::Present(Present::Message(name)) => {
                self.write_reach.message(&name.proto_full_name)
            }
            ValueShape::Present(Present::Wrapped(_, full_name)) => {
                self.write_reach.message(full_name)
            }
            ValueShape::Present(
                Present::Timestamp
                | Present::Duration
                | Present::FieldMask
                | Present::Struct
                | Present::ListValue,
            )
            | ValueShape::Zeroed(Zeroed::Json) => true,
            ValueShape::Present(Present::Wrapper(_)) | ValueShape::Zeroed(_) => false,
        }
    }

    /// Whether a field's values reach an `Any` ([`Self::reaches`]).
    pub(super) fn field_reaches(&self, shape: FieldShape) -> bool {
        match shape {
            FieldShape::Maybe(value)
            | FieldShape::List(value)
            | FieldShape::Dict(_, value)
            | FieldShape::BoolMap(value) => self.reaches(value),
            FieldShape::Plain(_) | FieldShape::Json => false,
        }
    }

    /// Whether a value is or reaches a `google.protobuf.Any`, so that its
    /// JSON codecs take the registry and its encoder gives a `Result`.
    pub(super) fn reaches(&self, value: ValueShape) -> bool {
        match value {
            ValueShape::Present(Present::Any) => true,
            ValueShape::Present(Present::Message(name)) => {
                self.reach.message(&name.proto_full_name)
            }
            ValueShape::Present(Present::Wrapped(_, full_name)) => self.reach.message(full_name),
            ValueShape::Present(_) | ValueShape::Zeroed(_) => false,
        }
    }

    /// The decoder of a field, and the value an absent or `null` field
    /// reads as; `None` for [`FieldShape::Json`], which
    /// `Proto.Json.Decode.nullField` reads whole, since for it `null` is not
    /// absent.
    pub(super) fn field_decoder(&mut self, shape: FieldShape) -> Option<(Expr, Expr)> {
        let decoder = match shape {
            FieldShape::Json => return None,
            FieldShape::Plain(zeroed) => self.value_decoder(ValueShape::Zeroed(zeroed)),
            FieldShape::Maybe(value) => {
                let value = self.value_decoder(value);
                let map = self.reference((JSON_DECODE, "map"));
                apply(map, [var(self.core("Just")), value])
            }
            FieldShape::List(value) => {
                let value = self.value_decoder(value);
                apply(self.reference((JSON_DECODE, "list")), [value])
            }
            FieldShape::Dict(key, value) => {
                let value = self.value_decoder(value);
                let dict = match key {
                    KeyShape::String => self.reference((PROTO_JSON_DECODE, "stringDict")),
                    KeyShape::Int32 => self.reference((PROTO_JSON_DECODE, "int32Dict")),
                    KeyShape::UInt32 => self.reference((PROTO_JSON_DECODE, "uint32Dict")),
                    KeyShape::Int64 => self.reference((PROTO_JSON_DECODE, "int64Dict")),
                    KeyShape::UInt64 => self.reference((PROTO_JSON_DECODE, "uint64Dict")),
                };
                apply(dict, [value])
            }
            FieldShape::BoolMap(value) => {
                let value = self.value_decoder(value);
                apply(self.reference((PROTO_JSON_DECODE, "boolMap")), [value])
            }
        };
        Some((decoder, self.field_default(shape)))
    }

    /// A field's proto3 default: the value it reads as when absent or
    /// `null`, and holds in its message's default value.
    pub(super) fn field_default(&mut self, shape: FieldShape) -> Expr {
        match shape {
            FieldShape::Plain(Zeroed::Scalar(repr)) => self.scalar_zero(repr),
            FieldShape::Plain(Zeroed::Enum(name, zero_ctor)) => {
                self.generated_value(&name.module, zero_ctor.to_owned())
            }
            FieldShape::Plain(Zeroed::Json) => {
                unreachable!("a singular field of google.protobuf.Value is FieldShape::Json")
            }
            FieldShape::Plain(Zeroed::Empty | Zeroed::Null) => Expr::Unit,
            FieldShape::Maybe(_) | FieldShape::Json => var(self.core("Nothing")),
            FieldShape::List(_) | FieldShape::BoolMap(_) => list([]),
            FieldShape::Dict(..) => self.reference((CORE_DICT, "empty")),
        }
    }

    /// The Elm type of one value.
    pub(super) fn value_type(&mut self, value: ValueShape) -> Type {
        match value {
            ValueShape::Zeroed(Zeroed::Scalar(repr))
            | ValueShape::Present(Present::Wrapper(repr)) => self.scalar_type(repr),
            ValueShape::Zeroed(Zeroed::Enum(name, _))
            | ValueShape::Present(Present::Message(name)) => self.generated_type(name),
            ValueShape::Zeroed(Zeroed::Json) => self.library_type(PROTO_VALUE, "Value", []),
            ValueShape::Present(Present::Timestamp) => {
                self.library_type(PROTO_TIMESTAMP, "Timestamp", [])
            }
            ValueShape::Present(Present::Duration) => {
                self.library_type(PROTO_DURATION, "Duration", [])
            }
            ValueShape::Present(Present::FieldMask) => {
                ty(self.core("List"), [ty(self.core("String"), [])])
            }
            ValueShape::Present(Present::Struct) => {
                let value = self.library_type(PROTO_VALUE, "Value", []);
                let key = ty(self.core("String"), []);
                self.dict(key, value)
            }
            ValueShape::Present(Present::ListValue) => {
                let value = self.library_type(PROTO_VALUE, "Value", []);
                ty(self.core("List"), [value])
            }
            ValueShape::Present(Present::Any) => self.library_type(PROTO_ANY, "Any", []),
            ValueShape::Zeroed(Zeroed::Empty | Zeroed::Null) => Type::Unit,
            ValueShape::Present(Present::Wrapped(wrapper, _)) => ty(wrapper.elm_name.clone(), []),
        }
    }

    /// The JSON of one value, `value`: its encoder applied to it, and for a
    /// message whose write cannot be refused, unwrapped with
    /// `Proto.Json.Encode.encodeTotal`.
    pub(super) fn encode_value(&mut self, shape: ValueShape, value: Expr) -> Expr {
        if let Some(encoder) = self.total_message_encoder(shape) {
            let total = self.reference((PROTO_JSON_ENCODE, "encodeTotal"));
            return apply(total, [apply(encoder, [value])]);
        }
        call(self.value_encoder(shape), [value])
    }

    /// The plain encoder of a map's values. A message is written by `\entry
    /// -> Proto.Json.Encode.encodeTotal (encodeFoo entry)`, one closure per write
    /// of the field: `Proto.Json.Encode.encodeTotal << encodeFoo` builds a partial
    /// application of two steps instead, which made writing a message
    /// holding three empty maps of messages 12 % slower.
    fn map_value_encoder(&mut self, value: ValueShape) -> Expr {
        match self.total_message_encoder(value) {
            Some(encoder) => {
                let total = self.reference((PROTO_JSON_ENCODE, "encodeTotal"));
                lambda(
                    [pvar(MAP_VALUE)],
                    apply(total, [apply(encoder, [var(MAP_VALUE)])]),
                )
            }
            None => self.value_encoder(value),
        }
    }

    /// The `Proto.Json.Encode.Encoder x` of a message whose write cannot be
    /// refused, which plain code unwraps with `Proto.Json.Encode.encodeTotal`;
    /// `None` for any other value.
    pub(super) fn total_message_encoder(&mut self, value: ValueShape) -> Option<Expr> {
        if self.write_reaches(value) {
            return None;
        }
        match value {
            ValueShape::Present(Present::Message(name)) => {
                Some(self.generated_value(&name.module, name.encoder_name()))
            }
            ValueShape::Present(Present::Wrapped(wrapper, _)) => Some(var(wrapper.encoder_name())),
            _ => None,
        }
    }

    /// The encoder of one value: a `Proto.Json.Encode.Encoder` when its write can
    /// be refused ([`Self::write_reaches`]), else its plain JSON; for a
    /// message, `Proto.Json.Encode.encodeTotal << encodeFoo`.
    pub(super) fn value_encoder(&mut self, value: ValueShape) -> Expr {
        if self.write_reaches(value) {
            let encoder = match value {
                ValueShape::Present(Present::Message(name)) => {
                    self.generated_value(&name.module, name.encoder_name())
                }
                ValueShape::Present(Present::Wrapped(wrapper, _)) => var(wrapper.encoder_name()),
                ValueShape::Present(Present::Timestamp) => {
                    self.reference((PROTO_JSON_ENCODE, "timestamp"))
                }
                ValueShape::Present(Present::Duration) => {
                    self.reference((PROTO_JSON_ENCODE, "duration"))
                }
                ValueShape::Present(Present::FieldMask) => {
                    self.reference((PROTO_JSON_ENCODE, "fieldMask"))
                }
                ValueShape::Present(Present::Struct) => {
                    self.reference((PROTO_JSON_ENCODE, "struct"))
                }
                ValueShape::Present(Present::ListValue) => {
                    self.reference((PROTO_JSON_ENCODE, "listValue"))
                }
                ValueShape::Zeroed(Zeroed::Json) => self.reference((PROTO_JSON_ENCODE, "value")),
                _ => self.reference((PROTO_JSON_ENCODE, "any")),
            };
            return encoder;
        }
        match value {
            ValueShape::Zeroed(Zeroed::Scalar(repr))
            | ValueShape::Present(Present::Wrapper(repr)) => self.reference(scalar::encoder(repr)),
            ValueShape::Zeroed(Zeroed::Enum(name, _)) => {
                self.generated_value(&name.module, name.encoder_name())
            }
            ValueShape::Present(Present::Message(_) | Present::Wrapped(..)) => {
                let encoder = self
                    .total_message_encoder(value)
                    .expect("a message whose write cannot be refused");
                let total = self.reference((PROTO_JSON_ENCODE, "encodeTotal"));
                crate::elm::build::binop(crate::elm::ast::BinOp::ComposeL, total, encoder)
            }
            ValueShape::Zeroed(Zeroed::Json)
            | ValueShape::Present(
                Present::Timestamp
                | Present::Duration
                | Present::FieldMask
                | Present::Struct
                | Present::ListValue
                | Present::Any,
            ) => unreachable!("a value whose write can be refused has no plain encoder"),
            ValueShape::Zeroed(Zeroed::Empty) => self.reference((PROTO_JSON_ENCODE, "empty")),
            ValueShape::Zeroed(Zeroed::Null) => self.reference((PROTO_JSON_ENCODE, "nullValue")),
        }
    }

    /// `field`, a field's or oneof member's `Proto.Json.Encode.Field`, written one
    /// level deeper when its message counts nesting and the value counts a
    /// level (`counted`) and reaches an `Any`: `Proto.Json.Encode.deeper
    /// field`, so that converting an `Any` to JSON counts the messages
    /// around it as a read does. The level is raised once for the field,
    /// not per element: every element of a field is one level below its
    /// message.
    pub(super) fn deeper_if_counted(&mut self, counted: bool, reaches: bool, field: Expr) -> Expr {
        if counted && reaches {
            let deeper = self.reference((PROTO_JSON_ENCODE, "deeper"));
            apply(deeper, [field])
        } else {
            field
        }
    }

    /// The decoder of one value, taking the registry when it reaches an
    /// `Any`.
    pub(super) fn value_decoder(&mut self, value: ValueShape) -> Expr {
        if let (Some(deep), true) = (self.deep, self.deep_value) {
            let target = match value {
                ValueShape::Present(Present::Wrapped(wrapper, _)) => Some((
                    wrapper
                        .elm_name
                        .strip_suffix('_')
                        .expect("a wrapper is its message's name and `_`")
                        .to_owned(),
                    Some(wrapper.elm_name.clone()),
                )),
                ValueShape::Present(Present::Message(name)) => Some((name.name.clone(), None)),
                _ => None,
            };
            if let Some((message, wrapper)) = target {
                let decoder = self.deeper(deep, &message);
                return match wrapper {
                    Some(wrapper) => {
                        let map = self.reference((JSON_DECODE, "map"));
                        apply(map, [var(wrapper), decoder])
                    }
                    None => decoder,
                };
            }
        }
        if self.deep.is_some()
            && let Some(name) = self.counted_message(value)
        {
            return self.counted_decoder(name);
        }
        if self.reaches(value) {
            let decoder = match value {
                ValueShape::Present(Present::Message(name)) => {
                    self.generated_value(&name.module, with_registry(name.decoder_name()))
                }
                ValueShape::Present(Present::Wrapped(wrapper, _)) => {
                    var(with_registry(wrapper.decoder_name()))
                }
                _ if self.deep.is_some() => {
                    let nested = self.reference((PROTO_JSON_DECODE, "nestedAny"));
                    return apply(
                        nested,
                        [var(super::recursion::DEPTH), var(REGISTRY_ARGUMENT)],
                    );
                }
                _ => self.reference((PROTO_JSON_DECODE, "any")),
            };
            return apply(decoder, [var(REGISTRY_ARGUMENT)]);
        }
        match value {
            ValueShape::Zeroed(Zeroed::Scalar(repr))
            | ValueShape::Present(Present::Wrapper(repr)) => self.reference(scalar::decoder(repr)),
            ValueShape::Zeroed(Zeroed::Enum(name, _))
            | ValueShape::Present(Present::Message(name)) => {
                self.generated_value(&name.module, name.decoder_name())
            }
            ValueShape::Zeroed(Zeroed::Json) if self.deep.is_some() => {
                let nested = self.reference((PROTO_JSON_DECODE, "nestedValue"));
                apply(nested, [var(super::recursion::DEPTH)])
            }
            ValueShape::Zeroed(Zeroed::Json) => self.reference((PROTO_JSON_DECODE, "value")),
            ValueShape::Present(Present::Timestamp) => {
                self.reference((PROTO_JSON_DECODE, "timestamp"))
            }
            ValueShape::Present(Present::Duration) => {
                self.reference((PROTO_JSON_DECODE, "duration"))
            }
            ValueShape::Present(Present::FieldMask) => {
                self.reference((PROTO_JSON_DECODE, "fieldMask"))
            }
            ValueShape::Present(Present::Struct) if self.deep.is_some() => {
                let nested = self.reference((PROTO_JSON_DECODE, "nestedStruct"));
                apply(nested, [var(super::recursion::DEPTH)])
            }
            ValueShape::Present(Present::ListValue) if self.deep.is_some() => {
                let nested = self.reference((PROTO_JSON_DECODE, "nestedListValue"));
                apply(nested, [var(super::recursion::DEPTH)])
            }
            ValueShape::Present(Present::Struct) => self.reference((PROTO_JSON_DECODE, "struct")),
            ValueShape::Present(Present::ListValue) => {
                self.reference((PROTO_JSON_DECODE, "listValue"))
            }
            ValueShape::Present(Present::Any) => {
                unreachable!("an Any reaches an Any, so its decoder takes the registry")
            }
            ValueShape::Zeroed(Zeroed::Empty) => self.reference((PROTO_JSON_DECODE, "empty")),
            ValueShape::Zeroed(Zeroed::Null) => self.reference((PROTO_JSON_DECODE, "nullValue")),
            ValueShape::Present(Present::Wrapped(wrapper, _)) => var(wrapper.decoder_name()),
        }
    }
}

/// The shape of `field`. `by_name` holds the messages of the field's
/// package, where a field that closes a cycle finds its target's wrapper;
/// `holding` is what the generator's options say, which the field's
/// `jstype` may override.
pub(super) fn field_shape<'m>(
    field: &'m Field,
    by_name: &HashMap<&str, &'m Message>,
    holding: Holding,
) -> FieldShape<'m> {
    let value = match &field.ty {
        TypeRef::Message(name) if field.cyclic => {
            // A cycle never leaves its package (the IR's invariants), and
            // every message on one has a wrapper.
            let wrapper = by_name[name.name.as_str()]
                .wrapper
                .as_ref()
                .expect("a message on a cycle has a wrapper");
            ValueShape::Present(Present::Wrapped(wrapper, &name.proto_full_name))
        }
        ty => value_shape(ty, field_holding(field.jstype, holding)),
    };
    match (field.cardinality, value) {
        // `optional` adds no presence to a message type, and `Empty` has
        // none to add.
        (Cardinality::Singular | Cardinality::Optional, ValueShape::Zeroed(Zeroed::Empty)) => {
            FieldShape::Plain(Zeroed::Empty)
        }
        // `NullValue` has one value, so `optional` has nothing to tell
        // apart.
        (Cardinality::Singular | Cardinality::Optional, ValueShape::Zeroed(Zeroed::Null)) => {
            FieldShape::Plain(Zeroed::Null)
        }
        // `null` sets a `Value`, so a singular one has presence whether or
        // not it is `optional`.
        (Cardinality::Singular | Cardinality::Optional, ValueShape::Zeroed(Zeroed::Json)) => {
            FieldShape::Json
        }
        (Cardinality::Singular, ValueShape::Zeroed(zeroed)) => FieldShape::Plain(zeroed),
        (Cardinality::Singular | Cardinality::Optional, value) => FieldShape::Maybe(value),
        (Cardinality::Repeated, value) => FieldShape::List(value),
        (Cardinality::Map(key), value) => match KeyShape::of(key) {
            Some(key) => FieldShape::Dict(key, value),
            None => FieldShape::BoolMap(value),
        },
    }
}

/// How a field with this `jstype` holds its scalars, under what the
/// generator's options say: `jstype` decides 64-bit integers unless it is
/// `JS_NORMAL`.
pub(super) fn field_holding(jstype: JsType, holding: Holding) -> Holding {
    let int64 = match jstype {
        JsType::Normal => holding.int64,
        JsType::String => Int64::String,
        JsType::Number => Int64::Int,
    };
    Holding { int64, ..holding }
}

/// The shape of one value of type `ty`, holding its scalars as `holding`
/// says.
pub(super) fn value_shape(ty: &TypeRef, holding: Holding) -> ValueShape<'_> {
    match ty {
        TypeRef::Scalar(kind) => ValueShape::Zeroed(Zeroed::Scalar(scalar::repr(*kind, holding))),
        TypeRef::Enum { name, zero_ctor } => ValueShape::Zeroed(Zeroed::Enum(name, zero_ctor)),
        TypeRef::Message(name) => ValueShape::Present(Present::Message(name)),
        TypeRef::WellKnown(known) => well_known(*known, holding),
    }
}
