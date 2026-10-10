//! The Elm side of each proto scalar (design §3.4): its type, its zero
//! value, and the library functions that encode and decode it.

use super::{CONNECT_JSON, JSON_DECODE, JSON_ENCODE};
use crate::elm::ast::{Expr, Type};
use crate::elm::build::{int, string, ty, var};
use crate::ir::ScalarKind;

/// How Elm holds a scalar.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Repr {
    /// `Float`, from `double` and `float`; non-finite values travel as
    /// strings.
    Float,
    /// `Int`, from the 32-bit integers.
    Int,
    /// `String` holding a decimal integer, from the 64-bit integers, which
    /// Elm's `Int` cannot hold exactly past 2^53.
    Int64,
    /// `Bool`.
    Bool,
    /// `String`.
    String,
    /// `String` holding base64, as on the wire.
    Bytes,
}

fn repr(kind: ScalarKind) -> Repr {
    match kind {
        ScalarKind::Double | ScalarKind::Float => Repr::Float,
        ScalarKind::Int32
        | ScalarKind::UInt32
        | ScalarKind::SInt32
        | ScalarKind::Fixed32
        | ScalarKind::SFixed32 => Repr::Int,
        ScalarKind::Int64
        | ScalarKind::UInt64
        | ScalarKind::SInt64
        | ScalarKind::Fixed64
        | ScalarKind::SFixed64 => Repr::Int64,
        ScalarKind::Bool => Repr::Bool,
        ScalarKind::String => Repr::String,
        ScalarKind::Bytes => Repr::Bytes,
    }
}

/// The Elm type of a scalar.
pub(super) fn elm_type(kind: ScalarKind) -> Type {
    let name = match repr(kind) {
        Repr::Float => "Float",
        Repr::Int => "Int",
        Repr::Bool => "Bool",
        Repr::Int64 | Repr::String | Repr::Bytes => "String",
    };
    ty(name, [])
}

/// The proto3 zero value of a scalar, which an absent or `null` field
/// reads as.
pub(super) fn zero_value(kind: ScalarKind) -> Expr {
    match repr(kind) {
        Repr::Float => Expr::Float(0.0),
        Repr::Int => int(0),
        Repr::Bool => var("False"),
        // The decimal string of 0: an empty string would re-encode as an
        // int64 no proto3 JSON parser accepts.
        Repr::Int64 => string("0"),
        // The empty string is also the base64 of no bytes.
        Repr::String | Repr::Bytes => string(""),
    }
}

/// The library function that encodes a scalar: its module and name.
pub(super) fn encoder(kind: ScalarKind) -> (&'static str, &'static str) {
    match repr(kind) {
        Repr::Float => (CONNECT_JSON, "encodeFloat"),
        Repr::Int => (JSON_ENCODE, "int"),
        Repr::Int64 => (CONNECT_JSON, "encodeInt64"),
        Repr::Bool => (JSON_ENCODE, "bool"),
        Repr::String => (JSON_ENCODE, "string"),
        Repr::Bytes => (CONNECT_JSON, "encodeBytes"),
    }
}

/// The library decoder for a scalar: its module and name.
pub(super) fn decoder(kind: ScalarKind) -> (&'static str, &'static str) {
    match repr(kind) {
        Repr::Float => (CONNECT_JSON, "float"),
        Repr::Int => (CONNECT_JSON, "int32"),
        Repr::Int64 => (CONNECT_JSON, "int64"),
        Repr::Bool => (JSON_DECODE, "bool"),
        Repr::String => (JSON_DECODE, "string"),
        Repr::Bytes => (CONNECT_JSON, "bytes"),
    }
}
