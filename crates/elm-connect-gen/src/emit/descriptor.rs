//! The typed records of a package's messages and enums (design §3.9):
//! `messageFoo : Proto.Message.Message Foo`, holding the message's codecs
//! and its descriptor, and `enumBar : Proto.Enum.Enum Bar`, holding the
//! enum's name, codecs and values.

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

    /// `enumBar : Proto.Enum.Enum Bar`: the enum's full name, its encoder
    /// and decoder, and every value name in declaration order with its
    /// number and constructor (an alias with its value's). That is all the
    /// proto says about an enum, so the record carries no descriptor;
    /// `Proto.Enum.descriptor` builds one.
    pub(super) fn enum_record(&mut self, enumeration: &Enum) -> Decl {
        let values: Vec<Expr> = enumeration
            .declared()
            .map(|(name, value)| {
                inline_record([
                    ("name", string(name)),
                    ("number", int(value.number.into())),
                    ("value", var(value.elm_ctor.clone())),
                ])
            })
            .collect();
        let annotation =
            self.library_type(PROTO_ENUM, "Enum", [ty(enumeration.elm_name.clone(), [])]);
        Decl::Value {
            doc: None,
            name: enumeration.value_name(),
            annotation,
            params: Vec::new(),
            body: record([
                ("typeName", string(enumeration.proto_full_name.clone())),
                ("encodeJson", var(enumeration.encoder_name())),
                ("jsonDecoder", var(enumeration.decoder_name())),
                ("values", list(values)),
            ]),
        }
    }
}
