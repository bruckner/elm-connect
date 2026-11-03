//! A recursive message's wrapper: its custom type, encoder and decoder
//! (design §3.2).

use super::{Emitter, JSON_DECODE, JSON_ENCODE, docs};
use crate::elm::ast::{Decl, Pattern, Type, Variant};
use crate::elm::build::{apply, lambda, pctor, pvar, ty, var};
use crate::ir::{Message, Wrapper};
use crate::naming::{ENCODER_ARGUMENT, REGISTRY_ARGUMENT, with_registry};
use crate::options::Codec;

impl Emitter {
    /// `type Node_ = Node_ Node`.
    pub(super) fn wrapper_type(&mut self, message: &Message, wrapper: &Wrapper) -> Decl {
        Decl::CustomType {
            doc: Some(format!(
                "{} where a cycle of fields leads back to it, since Elm rejects a \
                 recursive type alias.",
                docs::a_local_capital(&message.elm_name)
            )),
            name: wrapper.elm_name.clone(),
            type_params: Vec::new(),
            variants: vec![Variant {
                name: wrapper.elm_name.clone(),
                args: vec![ty(message.elm_name.clone(), [])],
            }],
        }
    }

    /// Whether a recursive message reaches an `Any` under `codec=both`, so
    /// its wrapper's JSON codecs take the registry as its own do.
    fn wrapper_reaches(&self, message: &Message) -> bool {
        self.codec == Codec::Both && self.reach.message(&message.proto_full_name)
    }

    /// `encodeNode_ (Node_ value) = encodeNode value`; under `codec=both`,
    /// for a message that reaches an `Any`, `encodeNode_With types (Node_
    /// value) = encodeNodeWith types value`.
    pub(super) fn wrapper_encoder(&mut self, message: &Message, wrapper: &Wrapper) -> Decl {
        if self.wrapper_reaches(message) {
            let annotation = self.encoder_with_type(ty(wrapper.elm_name.clone(), []));
            return Decl::Value {
                doc: Some(format!(
                    "Encodes {} as proto3 JSON, writing each `Any` it holds with the registry.",
                    docs::a_local(&wrapper.elm_name)
                )),
                name: with_registry(wrapper.encoder_name()),
                annotation,
                params: vec![
                    pvar(REGISTRY_ARGUMENT),
                    pctor(wrapper.elm_name.clone(), [pvar(ENCODER_ARGUMENT)]),
                ],
                body: apply(
                    var(with_registry(message.encoder_name())),
                    [var(REGISTRY_ARGUMENT), var(ENCODER_ARGUMENT)],
                ),
            };
        }
        let value_type = self.library_type(JSON_ENCODE, "Value", []);
        Decl::Value {
            doc: Some(format!(
                "Encodes {} as proto3 JSON.",
                docs::a_local(&wrapper.elm_name)
            )),
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
    /// themselves, which Elm rejects. Under `codec=both`, for a message
    /// that reaches an `Any`, `decodeNode_With types` reads it with
    /// `decodeNodeWith types`.
    pub(super) fn wrapper_decoder(&mut self, message: &Message, wrapper: &Wrapper) -> Decl {
        if self.wrapper_reaches(message) {
            let map = self.reference((JSON_DECODE, "map"));
            let lazy = self.lazy(apply(
                var(with_registry(message.decoder_name())),
                [var(REGISTRY_ARGUMENT)],
            ));
            let annotation = self.decoder_with_type(ty(wrapper.elm_name.clone(), []));
            return Decl::Value {
                doc: Some(format!(
                    "Decodes {} from proto3 JSON, reading each `Any` it holds with the registry.",
                    docs::a_local(&wrapper.elm_name)
                )),
                name: with_registry(wrapper.decoder_name()),
                annotation,
                params: vec![pvar(REGISTRY_ARGUMENT)],
                body: apply(map, [var(wrapper.elm_name.clone()), lazy]),
            };
        }
        let map = self.reference((JSON_DECODE, "map"));
        let lazy = self.lazy(var(message.decoder_name()));
        let annotation =
            self.library_type(JSON_DECODE, "Decoder", [ty(wrapper.elm_name.clone(), [])]);
        Decl::Value {
            doc: Some(format!(
                "Decodes {} from proto3 JSON.",
                docs::a_local(&wrapper.elm_name)
            )),
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
