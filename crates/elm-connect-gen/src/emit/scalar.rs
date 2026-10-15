//! The Elm side of each proto scalar (design §3.4): its type, its zero
//! value, and the library functions that encode and decode it.

use super::{Int64, JSON_DECODE, JSON_ENCODE, PROTO_JSON};
use crate::elm::ast::{Expr, Type};
use crate::elm::build::{int, string, ty, var};
use crate::ir::ScalarKind;

/// How Elm holds a scalar.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Repr {
    /// `Float`, from `double` and `float`; non-finite values travel as
    /// strings.
    Float,
    /// `Int`, from the signed 32-bit integers, range-checked when decoded.
    Int32,
    /// `Int`, from the unsigned 32-bit integers, range-checked when
    /// decoded.
    UInt32,
    /// `String` holding a decimal integer, from the 64-bit integers, which
    /// Elm's `Int` cannot hold exactly past 2^53.
    Int64,
    /// `Int`, from the 64-bit integers under `int64=int` or
    /// `[jstype = JS_NUMBER]`: decoded only within ±(2^53 − 1), encoded as
    /// a decimal string.
    Int64AsInt,
    /// As `Int64`, from the unsigned 64-bit integers: decoded only when
    /// zero or more.
    UInt64,
    /// As `Int64AsInt`, from the unsigned 64-bit integers: decoded only
    /// within 0 to 2^53 − 1.
    UInt64AsInt,
    /// `Bool`.
    Bool,
    /// `String`.
    String,
    /// `String` holding base64, as on the wire.
    Bytes,
}

/// How Elm holds a scalar of `kind`; a 64-bit integer as `int64` says.
pub(super) fn repr(kind: ScalarKind, int64: Int64) -> Repr {
    match kind {
        ScalarKind::Double | ScalarKind::Float => Repr::Float,
        ScalarKind::Int32 | ScalarKind::SInt32 | ScalarKind::SFixed32 => Repr::Int32,
        ScalarKind::UInt32 | ScalarKind::Fixed32 => Repr::UInt32,
        ScalarKind::Int64 | ScalarKind::SInt64 | ScalarKind::SFixed64 => match int64 {
            Int64::String => Repr::Int64,
            Int64::Int => Repr::Int64AsInt,
        },
        ScalarKind::UInt64 | ScalarKind::Fixed64 => match int64 {
            Int64::String => Repr::UInt64,
            Int64::Int => Repr::UInt64AsInt,
        },
        ScalarKind::Bool => Repr::Bool,
        ScalarKind::String => Repr::String,
        ScalarKind::Bytes => Repr::Bytes,
    }
}

/// The Elm type of a scalar.
pub(super) fn elm_type(repr: Repr) -> Type {
    let name = match repr {
        Repr::Float => "Float",
        Repr::Int32 | Repr::UInt32 | Repr::Int64AsInt | Repr::UInt64AsInt => "Int",
        Repr::Bool => "Bool",
        Repr::Int64 | Repr::UInt64 | Repr::String | Repr::Bytes => "String",
    };
    ty(name, [])
}

/// The proto3 zero value of a scalar, which an absent or `null` field
/// reads as.
pub(super) fn zero_value(repr: Repr) -> Expr {
    match repr {
        Repr::Float => Expr::Float(0.0),
        Repr::Int32 | Repr::UInt32 | Repr::Int64AsInt | Repr::UInt64AsInt => int(0),
        Repr::Bool => var("False"),
        // The decimal string of 0: an empty string would re-encode as an
        // int64 no proto3 JSON parser accepts.
        Repr::Int64 | Repr::UInt64 => string("0"),
        // The empty string is also the base64 of no bytes.
        Repr::String | Repr::Bytes => string(""),
    }
}

/// The library function that encodes a scalar: its module and name.
pub(super) fn encoder(repr: Repr) -> (&'static str, &'static str) {
    match repr {
        Repr::Float => (PROTO_JSON, "encodeFloat"),
        Repr::Int32 | Repr::UInt32 => (JSON_ENCODE, "int"),
        Repr::Int64 | Repr::UInt64 => (PROTO_JSON, "encodeInt64"),
        Repr::Int64AsInt | Repr::UInt64AsInt => (PROTO_JSON, "encodeInt64AsInt"),
        Repr::Bool => (JSON_ENCODE, "bool"),
        Repr::String => (JSON_ENCODE, "string"),
        Repr::Bytes => (PROTO_JSON, "encodeBytes"),
    }
}

/// The library decoder for a scalar: its module and name.
pub(super) fn decoder(repr: Repr) -> (&'static str, &'static str) {
    match repr {
        Repr::Float => (PROTO_JSON, "float"),
        Repr::Int32 => (PROTO_JSON, "int32"),
        Repr::UInt32 => (PROTO_JSON, "uint32"),
        Repr::Int64 => (PROTO_JSON, "int64"),
        Repr::Int64AsInt => (PROTO_JSON, "int64AsInt"),
        Repr::UInt64 => (PROTO_JSON, "uint64"),
        Repr::UInt64AsInt => (PROTO_JSON, "uint64AsInt"),
        Repr::Bool => (JSON_DECODE, "bool"),
        Repr::String => (JSON_DECODE, "string"),
        Repr::Bytes => (PROTO_JSON, "bytes"),
    }
}
