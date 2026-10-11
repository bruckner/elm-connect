//! A recursive message's wrapper: its custom type, encoder and decoder
//! (design §3.2).

use super::{Emitter, JSON_DECODE, JSON_ENCODE};
use crate::elm::ast::{Decl, Pattern, Type, Variant};
use crate::elm::build::{apply, lambda, pctor, pvar, ty, var};
use crate::ir::{Message, Wrapper};
use crate::naming::ENCODER_ARGUMENT;

impl Emitter {
    /// `type Node_ = Node_ Node`.
    pub(super) fn wrapper_type(&mut self, message: &Message, wrapper: &Wrapper) -> Decl {
        Decl::CustomType {
            doc: None,
            name: wrapper.elm_name.clone(),
            type_params: Vec::new(),
            variants: vec![Variant {
                name: wrapper.elm_name.clone(),
                args: vec![ty(message.elm_name.clone(), [])],
            }],
        }
    }

    /// `encodeNode_ (Node_ value) = encodeNode value`.
    pub(super) fn wrapper_encoder(&mut self, message: &Message, wrapper: &Wrapper) -> Decl {
        let value_type = self.library_type(JSON_ENCODE, "Value", []);
        Decl::Value {
            doc: None,
            name: wrapper.encoder_name(),
            annotation: Type::Function(
                Box::new(ty(wrapper.elm_name.clone(), [])),
                Box::new(value_type),
            ),
            params: vec![pctor(wrapper.elm_name.clone(), [pvar(ENCODER_ARGUMENT)])],
            body: apply(var(message.encoder_name()), [var(ENCODER_ARGUMENT)]),
        }
    }

    /// `decodeNode_ = Json.Decode.map Node_ (Json.Decode.lazy (\_ ->
    /// decodeNode))`. The decoders of a cycle refer to each other; the
    /// lazy step keeps them from being defined directly in terms of
    /// themselves, which Elm rejects.
    pub(super) fn wrapper_decoder(&mut self, message: &Message, wrapper: &Wrapper) -> Decl {
        let map = self.reference((JSON_DECODE, "map"));
        let lazy = self.lazy(var(message.decoder_name()));
        let annotation =
            self.library_type(JSON_DECODE, "Decoder", [ty(wrapper.elm_name.clone(), [])]);
        Decl::Value {
            doc: None,
            name: wrapper.decoder_name(),
            annotation,
            params: Vec::new(),
            body: apply(map, [var(wrapper.elm_name.clone()), lazy]),
        }
    }

    /// `Json.Decode.lazy (\_ -> decoder)`.
    pub(super) fn lazy(&mut self, decoder: crate::elm::ast::Expr) -> crate::elm::ast::Expr {
        let lazy = self.reference((JSON_DECODE, "lazy"));
        apply(lazy, [lambda([Pattern::Wildcard], decoder)])
    }
}
