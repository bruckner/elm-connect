//! A field's shape, and the Elm type, encoder and decoder that follow
//! from it.

use super::{CONNECT_JSON, Emitter, JSON_DECODE, JSON_ENCODE, scalar};
use crate::elm::ast::{Expr, Type};
use crate::elm::build::{apply, list, ty, var};
use crate::ir::{Cardinality, Field, Message, ScalarKind, TypeName, TypeRef};

/// A field as the emitter supports it: what [`Emitter::field`] classifies
/// an IR field into once, so that the type, the encoder and the decoder of
/// the field match on a closed set and report nothing.
#[derive(Clone, Copy, Debug)]
pub(super) enum FieldShape<'p> {
    /// One value without presence, which reads as its zero value when
    /// absent or `null`.
    Plain(Zeroed<'p>),
    /// `Maybe`: a field with presence (proto3 `optional`, or
    /// message-typed), `Nothing` when absent or `null`.
    Maybe(ValueShape<'p>),
    /// `List`: a repeated field, `[]` when absent or `null`.
    List(ValueShape<'p>),
}

/// The type of a field's values, as the emitter supports it.
#[derive(Clone, Copy, Debug)]
pub(super) enum ValueShape<'p> {
    /// A type with a proto3 zero value.
    Zeroed(Zeroed<'p>),
    /// A generated message.
    Message(&'p TypeName),
}

/// A type with a proto3 zero value, which a field without presence holds
/// directly.
#[derive(Clone, Copy, Debug)]
pub(super) enum Zeroed<'p> {
    /// A proto scalar.
    Scalar(ScalarKind),
    /// A generated enum, whose zero value is this constructor.
    Enum(&'p TypeName, &'p str),
}

impl Emitter {
    /// The shape of `field`, or `None` once it is reported.
    pub(super) fn field<'m>(
        &mut self,
        message: &Message,
        field: &'m Field,
    ) -> Option<FieldShape<'m>> {
        let element = || format!("{}.{}", message.proto_full_name, field.proto_name);
        let value = match &field.ty {
            TypeRef::Scalar(kind) => ValueShape::Zeroed(Zeroed::Scalar(*kind)),
            TypeRef::Enum { name, zero_ctor } => ValueShape::Zeroed(Zeroed::Enum(name, zero_ctor)),
            TypeRef::Message(name) => ValueShape::Message(name),
            TypeRef::WellKnown(_) => {
                self.unimplemented(&element(), "a field of a well-known type");
                return None;
            }
        };
        Some(match (field.cardinality, value) {
            (Cardinality::Singular, ValueShape::Zeroed(zeroed)) => FieldShape::Plain(zeroed),
            (Cardinality::Singular | Cardinality::Optional, value) => FieldShape::Maybe(value),
            (Cardinality::Repeated, value) => FieldShape::List(value),
            (Cardinality::Map(_), _) => {
                self.unimplemented(&element(), "a map field");
                return None;
            }
        })
    }

    /// The Elm type of a field.
    pub(super) fn field_type(&mut self, shape: FieldShape) -> Type {
        match shape {
            FieldShape::Plain(zeroed) => self.value_type(ValueShape::Zeroed(zeroed)),
            FieldShape::Maybe(value) => ty("Maybe", [self.value_type(value)]),
            FieldShape::List(value) => ty("List", [self.value_type(value)]),
        }
    }

    /// The encoder of a field: a function from its Elm value to
    /// `Json.Encode.Value`, possibly partially applied.
    pub(super) fn field_encoder(&mut self, shape: FieldShape) -> Expr {
        match shape {
            FieldShape::Plain(zeroed) => self.value_encoder(ValueShape::Zeroed(zeroed)),
            FieldShape::Maybe(value) => {
                let value = self.value_encoder(value);
                apply(self.reference((CONNECT_JSON, "encodeMaybe")), [value])
            }
            FieldShape::List(value) => {
                let value = self.value_encoder(value);
                apply(self.reference((JSON_ENCODE, "list")), [value])
            }
        }
    }

    /// The decoder of a field, and the value an absent or `null` field
    /// reads as.
    pub(super) fn field_decoder(&mut self, shape: FieldShape) -> (Expr, Expr) {
        match shape {
            FieldShape::Plain(zeroed) => {
                let decoder = self.value_decoder(ValueShape::Zeroed(zeroed));
                let zero = match zeroed {
                    Zeroed::Scalar(kind) => scalar::zero_value(kind),
                    Zeroed::Enum(name, zero_ctor) => {
                        self.generated_value(&name.module, zero_ctor.to_owned())
                    }
                };
                (decoder, zero)
            }
            FieldShape::Maybe(value) => {
                let value = self.value_decoder(value);
                let map = self.reference((JSON_DECODE, "map"));
                (apply(map, [var("Just"), value]), var("Nothing"))
            }
            FieldShape::List(value) => {
                let value = self.value_decoder(value);
                (
                    apply(self.reference((JSON_DECODE, "list")), [value]),
                    list([]),
                )
            }
        }
    }

    /// The Elm type of one value.
    pub(super) fn value_type(&mut self, value: ValueShape) -> Type {
        match value {
            ValueShape::Zeroed(Zeroed::Scalar(kind)) => scalar::elm_type(kind),
            ValueShape::Zeroed(Zeroed::Enum(name, _)) | ValueShape::Message(name) => {
                self.generated_type(name)
            }
        }
    }

    /// The encoder of one value.
    pub(super) fn value_encoder(&mut self, value: ValueShape) -> Expr {
        match value {
            ValueShape::Zeroed(Zeroed::Scalar(kind)) => self.reference(scalar::encoder(kind)),
            ValueShape::Zeroed(Zeroed::Enum(name, _)) | ValueShape::Message(name) => {
                self.generated_value(&name.module, name.encoder_name())
            }
        }
    }

    /// The decoder of one value.
    pub(super) fn value_decoder(&mut self, value: ValueShape) -> Expr {
        match value {
            ValueShape::Zeroed(Zeroed::Scalar(kind)) => self.reference(scalar::decoder(kind)),
            ValueShape::Zeroed(Zeroed::Enum(name, _)) | ValueShape::Message(name) => {
                self.generated_value(&name.module, name.decoder_name())
            }
        }
    }
}
