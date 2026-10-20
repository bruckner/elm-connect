//! A message's four declarations: its record type alias, its default
//! value, its encoder and its decoder.

use super::{Emitter, JSON_DECODE, JSON_ENCODE, MessageShape, PROTO_JSON, RecordField, call, docs};
use crate::elm::ast::{BinOp, Decl, Expr, Pattern, Type};
use crate::elm::build::{
    access, apply, binop, list, pipeline, pvar, record, string, tuple2, ty, var,
};
use crate::naming::ENCODER_ARGUMENT;

impl Emitter {
    /// `type alias Foo = { ... }`, one record field per proto field and per
    /// oneof, in declaration order.
    pub(super) fn message_alias(&mut self, shape: &MessageShape) -> Decl {
        let record = shape.record();
        let items = record
            .iter()
            .map(|field| match field {
                RecordField::Field(field, _) => {
                    docs::field_item(&field.elm_name, &field.doc, &field.annotations.behavior)
                }
                RecordField::Oneof(oneof) => docs::oneof_item(oneof.oneof),
            })
            .collect();
        let doc = docs::message(shape.message, items);
        let body = record
            .iter()
            .map(|field| match field {
                RecordField::Field(field, value) => {
                    (field.elm_name.clone(), self.field_type(*value))
                }
                RecordField::Oneof(oneof) => (
                    oneof.oneof.elm_field_name.clone(),
                    ty(oneof.oneof.elm_type_name.clone(), []),
                ),
            })
            .collect();
        Decl::TypeAlias {
            doc: Some(doc),
            name: shape.message.elm_name.clone(),
            type_params: Vec::new(),
            body: Type::Record(body),
        }
    }

    /// `defaultFoo : Foo`: every field at its proto3 default, the value it
    /// reads as when absent (design §3.2), and every oneof unset. A field
    /// that closes a cycle is a `Maybe`, `List` or `Dict` of the wrapper,
    /// whose default is empty, so a recursive message's default needs no
    /// laziness and its wrapper no default of its own.
    pub(super) fn message_default(&mut self, shape: &MessageShape) -> Decl {
        let fields: Vec<(String, Expr)> = shape
            .record()
            .into_iter()
            .map(|field| match field {
                RecordField::Field(field, value) => {
                    (field.elm_name.clone(), self.field_default(value))
                }
                RecordField::Oneof(oneof) => (
                    oneof.oneof.elm_field_name.clone(),
                    var(oneof.oneof.unset_ctor.clone()),
                ),
            })
            .collect();
        Decl::Value {
            doc: Some(format!(
                "A {} with every field at its default and every oneof unset.",
                docs::code(&shape.message.elm_name)
            )),
            name: shape.message.default_name(),
            annotation: ty(shape.message.elm_name.clone(), []),
            params: Vec::new(),
            body: record(fields),
        }
    }

    /// `encodeFoo : Foo -> Json.Encode.Value`: `Proto.Json.objectOfFields` of every
    /// field under its JSON name, each as a `Maybe Json.Encode.Value` that
    /// is `Nothing` when the field is left out
    /// ([`encode_field`](Self::encode_field)), followed by the members
    /// each oneof's encoder gives (none when it is unset). Key order means
    /// nothing in JSON, so the fields come first, whatever the declaration
    /// order.
    pub(super) fn message_encoder(&mut self, shape: &MessageShape) -> Decl {
        let pairs: Vec<Expr> = shape
            .fields
            .iter()
            .map(|&(field, value)| {
                let field_value = access(var(ENCODER_ARGUMENT), field.elm_name.clone());
                tuple2(
                    string(field.json_name.clone()),
                    self.encode_field(value, field_value),
                )
            })
            .collect();
        let oneofs: Vec<Expr> = shape
            .oneofs
            .iter()
            .map(|oneof| {
                let field_value = access(var(ENCODER_ARGUMENT), oneof.oneof.elm_field_name.clone());
                apply(var(oneof.oneof.encoder_name()), [field_value])
            })
            .collect();
        // A message without fields or oneofs has nothing to read from its
        // argument.
        let nothing = pairs.is_empty() && oneofs.is_empty();
        let param = if nothing {
            Pattern::Wildcard
        } else {
            pvar(ENCODER_ARGUMENT)
        };
        // The fields' list, then each oneof's, joined with `++`.
        let parts = (!pairs.is_empty() || oneofs.is_empty())
            .then(|| list(pairs))
            .into_iter()
            .chain(oneofs);
        let members = parts
            .rev()
            .reduce(|right, left| binop(BinOp::Append, left, right))
            .expect("at least the fields' list");
        // `Json.Encode.object []` when there is nothing to leave out, so a
        // module of empty messages needs no `Proto.Json`.
        let object = if nothing {
            self.reference((JSON_ENCODE, "object"))
        } else {
            self.reference((PROTO_JSON, "objectOfFields"))
        };
        let value_type = self.library_type(JSON_ENCODE, "Value", []);
        Decl::Value {
            doc: Some(format!(
                "Encodes a {} as proto3 JSON.",
                docs::code(&shape.message.elm_name)
            )),
            name: shape.message.encoder_name(),
            annotation: Type::Function(
                Box::new(ty(shape.message.elm_name.clone(), [])),
                Box::new(value_type),
            ),
            params: vec![param],
            body: apply(object, [members]),
        }
    }

    /// A decoding pipeline step reading the field `json_name`, also
    /// accepted under `proto_name` as proto3 JSON requires:
    /// `Proto.Json.<one> json_name ...` when the two are equal, else
    /// `Proto.Json.<either> json_name proto_name ...`, followed by `args`,
    /// where `(one, either)` is `helpers`.
    fn field_step(
        &mut self,
        helpers: (&'static str, &'static str),
        json_name: &str,
        proto_name: &str,
        args: impl IntoIterator<Item = Expr>,
    ) -> Expr {
        let (one, either) = helpers;
        let step = if json_name == proto_name {
            let field = self.reference((PROTO_JSON, one));
            apply(field, [string(json_name)])
        } else {
            let field = self.reference((PROTO_JSON, either));
            apply(field, [string(json_name), string(proto_name)])
        };
        call(step, args)
    }

    /// `decodeFoo : Json.Decode.Decoder Foo`: `Json.Decode.succeed Foo`
    /// with one step per record field, in record order: an
    /// [`Emitter::field_step`] per proto field (`Proto.Json.field`, or
    /// `Proto.Json.valueField` for a singular `google.protobuf.Value`), a
    /// `Proto.Json.oneof` per oneof; `Proto.Json.emptyMessage` for a message
    /// without fields.
    pub(super) fn message_decoder(&mut self, shape: &MessageShape) -> Decl {
        let name = &shape.message.elm_name;
        let body = if shape.fields.is_empty() && shape.oneofs.is_empty() {
            // An empty message decodes to the empty record, from a JSON
            // object only, as a message with fields does.
            self.reference((PROTO_JSON, "emptyMessage"))
        } else {
            let succeed = self.reference((JSON_DECODE, "succeed"));
            let steps: Vec<Expr> = shape
                .record()
                .into_iter()
                .map(|field| match field {
                    RecordField::Field(field, value) => match self.field_decoder(value) {
                        Some((decoder, zero)) => self.field_step(
                            ("field", "fieldEither"),
                            &field.json_name,
                            &field.proto_name,
                            [zero, decoder],
                        ),
                        None => self.field_step(
                            ("valueField", "valueFieldEither"),
                            &field.json_name,
                            &field.proto_name,
                            [],
                        ),
                    },
                    RecordField::Oneof(oneof) => {
                        let step = self.reference((PROTO_JSON, "oneof"));
                        apply(step, [var(oneof.oneof.decoder_name())])
                    }
                })
                .collect();
            pipeline(apply(succeed, [var(name.clone())]), steps)
        };
        let annotation = self.library_type(JSON_DECODE, "Decoder", [ty(name.clone(), [])]);
        Decl::Value {
            doc: Some(format!(
                "Decodes a {} from proto3 JSON.",
                docs::code(&shape.message.elm_name)
            )),
            name: shape.message.decoder_name(),
            annotation,
            params: Vec::new(),
            body,
        }
    }
}
