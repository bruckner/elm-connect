//! The typed records of a package's messages and enums (design §3.9):
//! `messageFoo : Proto.Message.Message Foo` and `enumBar :
//! Proto.Enum.Enum Bar`, each holding its type's codecs, default and
//! descriptor.

use super::{Emitter, MessageShape, PROTO_ENUM, PROTO_MESSAGE};
use crate::elm::ast::{Decl, Expr};
use crate::elm::build::{inline_record, int, list, record, string, ty, var};
use crate::ir::Enum;

impl Emitter {
    /// `messageFoo : Proto.Message.Message Foo`: the message's encoder,
    /// decoder and default, and its descriptor.
    pub(super) fn message_record(&mut self, shape: &MessageShape) -> Decl {
        let message = shape.message;
        let descriptor = record([
            ("typeName", string(message.proto_full_name.clone())),
            ("fields", list([])),
            ("oneofs", list([])),
        ]);
        let annotation =
            self.library_type(PROTO_MESSAGE, "Message", [ty(message.elm_name.clone(), [])]);
        Decl::Value {
            doc: None,
            name: message.value_name(),
            annotation,
            params: Vec::new(),
            body: record([
                ("encodeJson", var(message.encoder_name())),
                ("jsonDecoder", var(message.decoder_name())),
                ("default", var(message.default_name())),
                ("descriptor", descriptor),
            ]),
        }
    }

    /// `enumBar : Proto.Enum.Enum Bar`: the enum's encoder, decoder and
    /// zero value, and its descriptor, whose values are every declared
    /// name in order with its number (an alias with its number).
    pub(super) fn enum_record(&mut self, enumeration: &Enum) -> Decl {
        let values: Vec<Expr> = enumeration
            .declared()
            .map(|(name, value)| {
                inline_record([("name", string(name)), ("number", int(value.number.into()))])
            })
            .collect();
        let descriptor = record([
            ("typeName", string(enumeration.proto_full_name.clone())),
            ("values", list(values)),
        ]);
        let annotation =
            self.library_type(PROTO_ENUM, "Enum", [ty(enumeration.elm_name.clone(), [])]);
        Decl::Value {
            doc: None,
            name: enumeration.value_name(),
            annotation,
            params: Vec::new(),
            body: record([
                ("encodeJson", var(enumeration.encoder_name())),
                ("jsonDecoder", var(enumeration.decoder_name())),
                ("default", var(enumeration.zero().elm_ctor.clone())),
                ("descriptor", descriptor),
            ]),
        }
    }
}
