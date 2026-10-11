//! A message's three declarations: its record type alias, its encoder and
//! its decoder.

use super::{CONNECT_JSON, Emitter, JSON_DECODE, JSON_ENCODE, MessageShape, RecordField, call};
use crate::elm::ast::{BinOp, Decl, Expr, Pattern, Type};
use crate::elm::build::{
    access, apply, binop, list, pipeline, pvar, record, string, tuple2, ty, var,
};
use crate::naming::ENCODER_ARGUMENT;

impl Emitter {
    /// `type alias Foo = { ... }`, one record field per proto field and per
    /// oneof, in declaration order.
    pub(super) fn message_alias(&mut self, shape: &MessageShape) -> Decl {
        let body = shape
            .record()
            .into_iter()
            .map(|field| match field {
                RecordField::Field(field, value) => {
                    (field.elm_name.clone(), self.field_type(value))
                }
                RecordField::Oneof(oneof) => (
                    oneof.oneof.elm_field_name.clone(),
                    ty(oneof.oneof.elm_type_name.clone(), []),
                ),
            })
            .collect();
        Decl::TypeAlias {
            doc: None,
            name: shape.message.elm_name.clone(),
            type_params: Vec::new(),
            body: Type::Record(body),
        }
    }

    /// `encodeFoo : Foo -> Json.Encode.Value`: a JSON object with every
    /// field under its JSON name, followed by the members each oneof's
    /// encoder gives (none when it is unset). Key order means nothing in
    /// JSON, so the fields come first, whatever the declaration order.
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
        let param = if pairs.is_empty() && oneofs.is_empty() {
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
        let object = self.reference((JSON_ENCODE, "object"));
        let value_type = self.library_type(JSON_ENCODE, "Value", []);
        Decl::Value {
            doc: None,
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
    /// `Connect.Json.field json_name ...` when the two are equal, else
    /// `Connect.Json.fieldEither json_name proto_name ...`, followed by
    /// `args`.
    fn field_step(
        &mut self,
        json_name: &str,
        proto_name: &str,
        args: impl IntoIterator<Item = Expr>,
    ) -> Expr {
        let step = if json_name == proto_name {
            let field = self.reference((CONNECT_JSON, "field"));
            apply(field, [string(json_name)])
        } else {
            let field = self.reference((CONNECT_JSON, "fieldEither"));
            apply(field, [string(json_name), string(proto_name)])
        };
        call(step, args)
    }

    /// `decodeFoo : Json.Decode.Decoder Foo`: `Json.Decode.succeed Foo`
    /// with one step per record field, in record order: an
    /// [`Emitter::field_step`] per proto field, a `Connect.Json.oneof` per
    /// oneof.
    pub(super) fn message_decoder(&mut self, shape: &MessageShape) -> Decl {
        let succeed = self.reference((JSON_DECODE, "succeed"));
        let name = &shape.message.elm_name;
        let body = if shape.fields.is_empty() && shape.oneofs.is_empty() {
            // An empty message decodes to the empty record.
            apply(succeed, [record::<String>([])])
        } else {
            let steps: Vec<Expr> = shape
                .record()
                .into_iter()
                .map(|field| match field {
                    RecordField::Field(field, value) => {
                        let (decoder, zero) = self.field_decoder(value);
                        self.field_step(&field.json_name, &field.proto_name, [zero, decoder])
                    }
                    RecordField::Oneof(oneof) => {
                        let step = self.reference((CONNECT_JSON, "oneof"));
                        apply(step, [var(oneof.oneof.decoder_name())])
                    }
                })
                .collect();
            pipeline(apply(succeed, [var(name.clone())]), steps)
        };
        let annotation = self.library_type(JSON_DECODE, "Decoder", [ty(name.clone(), [])]);
        Decl::Value {
            doc: None,
            name: shape.message.decoder_name(),
            annotation,
            params: Vec::new(),
            body,
        }
    }
}
