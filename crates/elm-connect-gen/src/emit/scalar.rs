//! The Elm side of each proto scalar (design §3.4): its type, its zero
//! value, and the library functions that encode and decode it.

use super::{ELM_BYTES, Emitter, JSON_DECODE, JSON_ENCODE, PROTO_BYTES, PROTO_JSON};
use crate::elm::ast::{Expr, Type};
use crate::elm::build::{int, string, ty, var};
use crate::ir::ScalarKind;
use crate::options::{Bytes, Int64, Options};

/// How the scalars the generator's options govern are held where a value
/// appears: 64-bit integers as the `int64` option or the field's `jstype`
/// says, `bytes` as the `bytes` option says.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct Holding {
    pub(super) int64: Int64,
    pub(super) bytes: Bytes,
}

impl Holding {
    /// What the options say where no field says otherwise.
    pub(super) fn of(options: &Options) -> Self {
        Holding {
            int64: options.int64,
            bytes: options.bytes,
        }
    }
}

/// How Elm holds a scalar.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Repr {
    /// `Float`, from `double`; non-finite values travel as strings.
    Float,
    /// As `Float`, from `float`: decoded only within a `float`'s range.
    Float32,
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
    /// `String`: decoded only when it holds no UTF-16 surrogate without
    /// its pair.
    String,
    /// `String` holding base64, as on the wire.
    Bytes,
    /// elm/bytes' `Bytes`, from `bytes` under `bytes=bytes`: decoded from
    /// base64, encoded as standard base64 with padding.
    BytesAsBytes,
}

/// How Elm holds a scalar of `kind`, as `holding` says.
pub(super) fn repr(kind: ScalarKind, holding: Holding) -> Repr {
    let int64 = holding.int64;
    match kind {
        ScalarKind::Double => Repr::Float,
        ScalarKind::Float => Repr::Float32,
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
        ScalarKind::Bytes => match holding.bytes {
            Bytes::String => Repr::Bytes,
            Bytes::Bytes => Repr::BytesAsBytes,
        },
    }
}

impl Emitter {
    /// The Elm type of a scalar.
    pub(super) fn scalar_type(&mut self, repr: Repr) -> Type {
        let name = match repr {
            Repr::BytesAsBytes => return self.library_type(ELM_BYTES, "Bytes", []),
            Repr::Float | Repr::Float32 => "Float",
            Repr::Int32 | Repr::UInt32 | Repr::Int64AsInt | Repr::UInt64AsInt => "Int",
            Repr::Bool => "Bool",
            Repr::Int64 | Repr::UInt64 | Repr::String | Repr::Bytes => "String",
        };
        ty(self.core(name), [])
    }

    /// The proto3 zero value of a scalar, which an absent or `null` field
    /// reads as.
    pub(super) fn scalar_zero(&mut self, repr: Repr) -> Expr {
        match repr {
            Repr::Float | Repr::Float32 => Expr::Float(0.0),
            Repr::Int32 | Repr::UInt32 | Repr::Int64AsInt | Repr::UInt64AsInt => int(0),
            Repr::Bool => var(self.core("False")),
            // The decimal string of 0: an empty string would re-encode as an
            // int64 no proto3 JSON parser accepts.
            Repr::Int64 | Repr::UInt64 => string("0"),
            // The empty string is also the base64 of no bytes.
            Repr::String | Repr::Bytes => string(""),
            Repr::BytesAsBytes => self.reference((PROTO_BYTES, "empty")),
        }
    }
}

/// The library function that encodes a scalar: its module and name.
pub(super) fn encoder(repr: Repr) -> (&'static str, &'static str) {
    match repr {
        Repr::Float | Repr::Float32 => (PROTO_JSON, "encodeFloat"),
        Repr::Int32 | Repr::UInt32 => (JSON_ENCODE, "int"),
        Repr::Int64 | Repr::UInt64 => (PROTO_JSON, "encodeInt64"),
        Repr::Int64AsInt | Repr::UInt64AsInt => (PROTO_JSON, "encodeInt64AsInt"),
        Repr::Bool => (JSON_ENCODE, "bool"),
        Repr::String => (JSON_ENCODE, "string"),
        Repr::Bytes => (PROTO_JSON, "encodeBytes"),
        Repr::BytesAsBytes => (PROTO_JSON, "encodeBytesAsBytes"),
    }
}

/// The library decoder for a scalar: its module and name.
pub(super) fn decoder(repr: Repr) -> (&'static str, &'static str) {
    match repr {
        Repr::Float => (PROTO_JSON, "float"),
        Repr::Float32 => (PROTO_JSON, "float32"),
        Repr::Int32 => (PROTO_JSON, "int32"),
        Repr::UInt32 => (PROTO_JSON, "uint32"),
        Repr::Int64 => (PROTO_JSON, "int64"),
        Repr::Int64AsInt => (PROTO_JSON, "int64AsInt"),
        Repr::UInt64 => (PROTO_JSON, "uint64"),
        Repr::UInt64AsInt => (PROTO_JSON, "uint64AsInt"),
        Repr::Bool => (JSON_DECODE, "bool"),
        Repr::String => (PROTO_JSON, "string"),
        Repr::Bytes => (PROTO_JSON, "bytes"),
        Repr::BytesAsBytes => (PROTO_JSON, "bytesAsBytes"),
    }
}
