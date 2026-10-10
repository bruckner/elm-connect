//! A message's three declarations: its record type alias, its encoder and
//! its decoder.

use super::{CONNECT_JSON, Emitter, FieldShape, JSON_DECODE, JSON_ENCODE};
use crate::elm::ast::{Decl, Expr, Pattern, Type};
use crate::elm::build::{access, apply, list, pipeline, pvar, record, string, tuple2, ty, var};
use crate::ir::{Field, Message};
use crate::naming::ENCODER_ARGUMENT;

impl Emitter {
    /// `type alias Foo = { ... }`, one record field per proto field.
    pub(super) fn message_alias(
        &mut self,
        message: &Message,
        fields: &[(&Field, FieldShape)],
    ) -> Decl {
        let body = fields
            .iter()
            .map(|&(field, shape)| (field.elm_name.clone(), self.field_type(shape)))
            .collect();
        Decl::TypeAlias {
            doc: None,
            name: message.elm_name.clone(),
            type_params: Vec::new(),
            body: Type::Record(body),
        }
    }

    /// `encodeFoo : Foo -> Json.Encode.Value`: a JSON object with every
    /// field under its JSON name.
    pub(super) fn message_encoder(
        &mut self,
        message: &Message,
        fields: &[(&Field, FieldShape)],
    ) -> Decl {
        let members = fields
            .iter()
            .map(|&(field, shape)| {
                let value = access(var(ENCODER_ARGUMENT), field.elm_name.clone());
                tuple2(
                    string(field.json_name.clone()),
                    apply(self.field_encoder(shape), [value]),
                )
            })
            .collect::<Vec<_>>();
        // An empty message has nothing to read from its argument.
        let param = if fields.is_empty() {
            Pattern::Wildcard
        } else {
            pvar(ENCODER_ARGUMENT)
        };
        let object = self.reference((JSON_ENCODE, "object"));
        let value_type = self.library_type(JSON_ENCODE, "Value", []);
        Decl::Value {
            doc: None,
            name: message.encoder_name(),
            annotation: Type::Function(
                Box::new(ty(message.elm_name.clone(), [])),
                Box::new(value_type),
            ),
            params: vec![param],
            body: apply(object, [list(members)]),
        }
    }

    /// `decodeFoo : Json.Decode.Decoder Foo`: `Json.Decode.succeed Foo`
    /// with one `Connect.Json.field` step per field, in record order.
    pub(super) fn message_decoder(
        &mut self,
        message: &Message,
        fields: &[(&Field, FieldShape)],
    ) -> Decl {
        let succeed = self.reference((JSON_DECODE, "succeed"));
        let body = if fields.is_empty() {
            // An empty message decodes to the empty record.
            apply(succeed, [record::<String>([])])
        } else {
            let steps: Vec<Expr> = fields
                .iter()
                .map(|&(field, shape)| {
                    let (decoder, zero) = self.field_decoder(shape);
                    let step = self.reference((CONNECT_JSON, "field"));
                    apply(step, [string(field.json_name.clone()), zero, decoder])
                })
                .collect();
            pipeline(apply(succeed, [var(message.elm_name.clone())]), steps)
        };
        let annotation =
            self.library_type(JSON_DECODE, "Decoder", [ty(message.elm_name.clone(), [])]);
        Decl::Value {
            doc: None,
            name: message.decoder_name(),
            annotation,
            params: Vec::new(),
            body,
        }
    }
}
