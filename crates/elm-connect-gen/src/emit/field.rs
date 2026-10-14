//! A field's shape, and the Elm type, encoder and decoder that follow
//! from it.

use super::scalar::Repr;
use super::{
    CORE_DICT, CORE_STRING, Emitter, Int64, JSON_DECODE, JSON_ENCODE, PROTO_DURATION, PROTO_JSON,
    TIME, call, scalar,
};
use crate::elm::ast::{Expr, Type};
use crate::elm::build::{apply, list, qualified, ty, var};
use std::collections::HashMap;

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
}

/// The keys of a map field held in a `Dict`, as Elm holds them. JSON
/// object keys are strings whatever the proto key type.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum KeyShape {
    /// `String`: `string` keys, and 64-bit integer keys held as decimal
    /// strings like 64-bit values (design §3.4).
    String,
    /// `Int`: 32-bit integer keys, read from and written as their decimal
    /// strings.
    Int,
}

impl KeyShape {
    /// The `Dict` key for `key`; `None` for `bool`, which has none.
    fn of(key: MapKey) -> Option<Self> {
        Some(match key {
            MapKey::String
            | MapKey::Int64
            | MapKey::UInt64
            | MapKey::SInt64
            | MapKey::Fixed64
            | MapKey::SFixed64 => KeyShape::String,
            MapKey::Int32
            | MapKey::UInt32
            | MapKey::SInt32
            | MapKey::Fixed32
            | MapKey::SFixed32 => KeyShape::Int,
            MapKey::Bool => return None,
        })
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
    /// `google.protobuf.Value`: any JSON, held as a `Json.Encode.Value`,
    /// whose zero value is `null` (design §3.5).
    Json,
    /// `google.protobuf.Empty`: `()`, which carries nothing, so a singular
    /// field of it has no presence either: absent, `null` and `{}` all read
    /// as `()` (design §3.5). A oneof member of it is a constructor without
    /// arguments.
    Empty,
}

/// A message type, which a singular field holds with presence (design
/// §3.2): a generated message, or a well-known type mapped to an Elm type
/// of its own (design §3.5).
#[derive(Clone, Copy, Debug)]
pub(super) enum Present<'p> {
    /// A generated message.
    Message(&'p TypeName),
    /// A recursive message, held in its wrapper because the field closes a
    /// cycle of record fields ([`Field::cyclic`]).
    Wrapped(&'p Wrapper),
    /// A wrapper such as `google.protobuf.Int32Value`: its scalar, which
    /// is `null` on the wire when unset.
    Wrapper(Repr),
    /// `google.protobuf.Timestamp`: `Time.Posix`.
    Timestamp,
    /// `google.protobuf.Duration`: the runtime's `Duration`.
    Duration,
    /// `google.protobuf.FieldMask`: its paths, a `List String`.
    FieldMask,
    /// `google.protobuf.Struct`: a JSON object, a
    /// `Dict String Json.Encode.Value`.
    Struct,
    /// `google.protobuf.ListValue`: a JSON array, a
    /// `List Json.Encode.Value`.
    ListValue,
}

/// The shape of a well-known type's values; `int64` says how the 64-bit
/// wrappers hold their value.
fn well_known(well_known: WellKnown, int64: Int64) -> ValueShape<'static> {
    let wrapper = |kind| Present::Wrapper(scalar::repr(kind, int64));
    let present = match well_known {
        WellKnown::Value => return ValueShape::Zeroed(Zeroed::Json),
        WellKnown::Struct => Present::Struct,
        WellKnown::ListValue => Present::ListValue,
        WellKnown::Timestamp => Present::Timestamp,
        WellKnown::Duration => Present::Duration,
        WellKnown::FieldMask => Present::FieldMask,
        WellKnown::Empty => return ValueShape::Zeroed(Zeroed::Empty),
        WellKnown::DoubleValue => wrapper(ScalarKind::Double),
        WellKnown::FloatValue => wrapper(ScalarKind::Float),
        WellKnown::Int64Value => wrapper(ScalarKind::Int64),
        WellKnown::UInt64Value => wrapper(ScalarKind::UInt64),
        WellKnown::Int32Value => wrapper(ScalarKind::Int32),
        WellKnown::UInt32Value => wrapper(ScalarKind::UInt32),
        WellKnown::BoolValue => wrapper(ScalarKind::Bool),
        WellKnown::StringValue => wrapper(ScalarKind::String),
        WellKnown::BytesValue => wrapper(ScalarKind::Bytes),
    };
    ValueShape::Present(present)
}

impl Emitter {
    /// The Elm type of a field.
    pub(super) fn field_type(&mut self, shape: FieldShape) -> Type {
        match shape {
            FieldShape::Plain(zeroed) => self.value_type(ValueShape::Zeroed(zeroed)),
            FieldShape::Maybe(value) => ty("Maybe", [self.value_type(value)]),
            FieldShape::List(value) => ty("List", [self.value_type(value)]),
            FieldShape::Dict(key, value) => {
                let key = match key {
                    KeyShape::String => ty("String", []),
                    KeyShape::Int => ty("Int", []),
                };
                let value = self.value_type(value);
                self.exposed_type(CORE_DICT, "Dict", [key, value])
            }
            FieldShape::BoolMap(value) => ty(
                "List",
                [Type::Tuple(vec![ty("Bool", []), self.value_type(value)])],
            ),
        }
    }

    /// The JSON of a field whose Elm value is `value`.
    pub(super) fn encode_field(&mut self, shape: FieldShape, value: Expr) -> Expr {
        let encoder = match shape {
            FieldShape::Plain(zeroed) => {
                return self.encode_value(ValueShape::Zeroed(zeroed), value);
            }
            FieldShape::Maybe(inner) => {
                let inner = self.value_encoder(inner);
                apply(self.reference((PROTO_JSON, "encodeMaybe")), [inner])
            }
            FieldShape::List(inner) => {
                let inner = self.value_encoder(inner);
                apply(self.reference((JSON_ENCODE, "list")), [inner])
            }
            FieldShape::Dict(key, inner) => {
                let inner = self.value_encoder(inner);
                let key = match key {
                    KeyShape::String => var("identity"),
                    KeyShape::Int => qualified(CORE_STRING, "fromInt"),
                };
                apply(self.reference((JSON_ENCODE, "dict")), [key, inner])
            }
            FieldShape::BoolMap(inner) => {
                let inner = self.value_encoder(inner);
                apply(self.reference((PROTO_JSON, "encodeBoolMap")), [inner])
            }
        };
        call(encoder, [value])
    }

    /// The decoder of a field, and the value an absent or `null` field
    /// reads as.
    pub(super) fn field_decoder(&mut self, shape: FieldShape) -> (Expr, Expr) {
        let decoder = match shape {
            FieldShape::Plain(zeroed) => self.value_decoder(ValueShape::Zeroed(zeroed)),
            FieldShape::Maybe(value) => {
                let value = self.value_decoder(value);
                let map = self.reference((JSON_DECODE, "map"));
                apply(map, [var("Just"), value])
            }
            FieldShape::List(value) => {
                let value = self.value_decoder(value);
                apply(self.reference((JSON_DECODE, "list")), [value])
            }
            FieldShape::Dict(key, value) => {
                let value = self.value_decoder(value);
                let dict = match key {
                    KeyShape::String => self.reference((JSON_DECODE, "dict")),
                    KeyShape::Int => self.reference((PROTO_JSON, "intDict")),
                };
                apply(dict, [value])
            }
            FieldShape::BoolMap(value) => {
                let value = self.value_decoder(value);
                apply(self.reference((PROTO_JSON, "boolMap")), [value])
            }
        };
        (decoder, self.field_default(shape))
    }

    /// A field's proto3 default: the value it reads as when absent or
    /// `null`, and holds in its message's default value.
    pub(super) fn field_default(&mut self, shape: FieldShape) -> Expr {
        match shape {
            FieldShape::Plain(Zeroed::Scalar(repr)) => scalar::zero_value(repr),
            FieldShape::Plain(Zeroed::Enum(name, zero_ctor)) => {
                self.generated_value(&name.module, zero_ctor.to_owned())
            }
            FieldShape::Plain(Zeroed::Json) => self.reference((JSON_ENCODE, "null")),
            FieldShape::Plain(Zeroed::Empty) => Expr::Unit,
            FieldShape::Maybe(_) => var("Nothing"),
            FieldShape::List(_) | FieldShape::BoolMap(_) => list([]),
            FieldShape::Dict(..) => self.reference((CORE_DICT, "empty")),
        }
    }

    /// The Elm type of one value.
    pub(super) fn value_type(&mut self, value: ValueShape) -> Type {
        match value {
            ValueShape::Zeroed(Zeroed::Scalar(repr))
            | ValueShape::Present(Present::Wrapper(repr)) => scalar::elm_type(repr),
            ValueShape::Zeroed(Zeroed::Enum(name, _))
            | ValueShape::Present(Present::Message(name)) => self.generated_type(name),
            ValueShape::Zeroed(Zeroed::Json) => self.library_type(JSON_ENCODE, "Value", []),
            ValueShape::Present(Present::Timestamp) => self.library_type(TIME, "Posix", []),
            ValueShape::Present(Present::Duration) => {
                self.exposed_type(PROTO_DURATION, "Duration", [])
            }
            ValueShape::Present(Present::FieldMask) => ty("List", [ty("String", [])]),
            ValueShape::Present(Present::Struct) => {
                let value = self.library_type(JSON_ENCODE, "Value", []);
                self.exposed_type(CORE_DICT, "Dict", [ty("String", []), value])
            }
            ValueShape::Present(Present::ListValue) => {
                ty("List", [self.library_type(JSON_ENCODE, "Value", [])])
            }
            ValueShape::Zeroed(Zeroed::Empty) => Type::Unit,
            ValueShape::Present(Present::Wrapped(wrapper)) => ty(wrapper.elm_name.clone(), []),
        }
    }

    /// The JSON of one value, `value`: its encoder applied to it, or the
    /// value itself when it is JSON already.
    pub(super) fn encode_value(&mut self, shape: ValueShape, value: Expr) -> Expr {
        match shape {
            ValueShape::Zeroed(Zeroed::Json) => value,
            shape => call(self.value_encoder(shape), [value]),
        }
    }

    /// The encoder of one value.
    pub(super) fn value_encoder(&mut self, value: ValueShape) -> Expr {
        match value {
            ValueShape::Zeroed(Zeroed::Scalar(repr))
            | ValueShape::Present(Present::Wrapper(repr)) => self.reference(scalar::encoder(repr)),
            ValueShape::Zeroed(Zeroed::Enum(name, _))
            | ValueShape::Present(Present::Message(name)) => {
                self.generated_value(&name.module, name.encoder_name())
            }
            ValueShape::Zeroed(Zeroed::Json) => var("identity"),
            ValueShape::Present(Present::Timestamp) => {
                self.reference((PROTO_JSON, "encodeTimestamp"))
            }
            ValueShape::Present(Present::Duration) => {
                self.reference((PROTO_JSON, "encodeDuration"))
            }
            ValueShape::Present(Present::FieldMask) => {
                self.reference((PROTO_JSON, "encodeFieldMask"))
            }
            ValueShape::Present(Present::Struct) => self.reference((PROTO_JSON, "encodeStruct")),
            ValueShape::Present(Present::ListValue) => {
                self.reference((PROTO_JSON, "encodeListValue"))
            }
            ValueShape::Zeroed(Zeroed::Empty) => self.reference((PROTO_JSON, "encodeEmpty")),
            ValueShape::Present(Present::Wrapped(wrapper)) => var(wrapper.encoder_name()),
        }
    }

    /// The decoder of one value.
    pub(super) fn value_decoder(&mut self, value: ValueShape) -> Expr {
        match value {
            ValueShape::Zeroed(Zeroed::Scalar(repr))
            | ValueShape::Present(Present::Wrapper(repr)) => self.reference(scalar::decoder(repr)),
            ValueShape::Zeroed(Zeroed::Enum(name, _))
            | ValueShape::Present(Present::Message(name)) => {
                self.generated_value(&name.module, name.decoder_name())
            }
            ValueShape::Zeroed(Zeroed::Json) => self.reference((JSON_DECODE, "value")),
            ValueShape::Present(Present::Timestamp) => self.reference((PROTO_JSON, "timestamp")),
            ValueShape::Present(Present::Duration) => self.reference((PROTO_JSON, "duration")),
            ValueShape::Present(Present::FieldMask) => self.reference((PROTO_JSON, "fieldMask")),
            ValueShape::Present(Present::Struct) => self.reference((PROTO_JSON, "struct")),
            ValueShape::Present(Present::ListValue) => self.reference((PROTO_JSON, "listValue")),
            ValueShape::Zeroed(Zeroed::Empty) => self.reference((PROTO_JSON, "empty")),
            ValueShape::Present(Present::Wrapped(wrapper)) => var(wrapper.decoder_name()),
        }
    }
}

/// The shape of `field`. `by_name` holds the messages of the field's
/// package, where a field that closes a cycle finds its target's wrapper;
/// `int64` is the generator's option, which the field's `jstype` may
/// override.
pub(super) fn field_shape<'m>(
    field: &'m Field,
    by_name: &HashMap<&str, &'m Message>,
    int64: Int64,
) -> FieldShape<'m> {
    let value = match &field.ty {
        TypeRef::Message(name) if field.cyclic => {
            // A cycle never leaves its package (the IR's invariants), and
            // every message on one has a wrapper.
            let wrapper = by_name[name.name.as_str()]
                .wrapper
                .as_ref()
                .expect("a message on a cycle has a wrapper");
            ValueShape::Present(Present::Wrapped(wrapper))
        }
        ty => value_shape(ty, field_int64(field.jstype, int64)),
    };
    match (field.cardinality, value) {
        // `optional` adds no presence to a message type, and `Empty` has
        // none to add.
        (Cardinality::Singular | Cardinality::Optional, ValueShape::Zeroed(Zeroed::Empty)) => {
            FieldShape::Plain(Zeroed::Empty)
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

/// How a field with this `jstype` holds 64-bit integers, under the
/// generator's `int64` option.
pub(super) fn field_int64(jstype: JsType, int64: Int64) -> Int64 {
    match jstype {
        JsType::Normal => int64,
        JsType::String => Int64::String,
        JsType::Number => Int64::Int,
    }
}

/// The shape of one value of type `ty`, holding 64-bit integers as
/// `int64` says.
pub(super) fn value_shape(ty: &TypeRef, int64: Int64) -> ValueShape<'_> {
    match ty {
        TypeRef::Scalar(kind) => ValueShape::Zeroed(Zeroed::Scalar(scalar::repr(*kind, int64))),
        TypeRef::Enum { name, zero_ctor } => ValueShape::Zeroed(Zeroed::Enum(name, zero_ctor)),
        TypeRef::Message(name) => ValueShape::Present(Present::Message(name)),
        TypeRef::WellKnown(known) => well_known(*known, int64),
    }
}
