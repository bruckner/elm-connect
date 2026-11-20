//! A recursive message's wrapper: its custom type, encoder and decoder
//! (design §3.2).

use super::{Deep, Emitter, JSON_DECODE, JSON_ENCODE, PROTO_JSON, PROTO_REGISTRY, docs};
use crate::elm::ast::{Decl, Expr, Pattern, Type, Variant};
use crate::elm::build::{apply, int, lambda, pctor, pvar, ty, var};
use crate::ir::{Message, Wrapper};
use crate::naming::{ENCODER_ARGUMENT, REGISTRY_ARGUMENT, with_registry};

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

    /// Whether a recursive message reaches an `Any`, so its wrapper's JSON
    /// codecs take the registry as its own do.
    fn wrapper_reaches(&self, message: &Message) -> bool {
        self.reach.message(&message.proto_full_name)
    }

    /// `encodeNode_ (Node_ value) = encodeNode value`; for a message that reaches an `Any`, `encodeNode_With types (Node_
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
    /// themselves, which Elm rejects. For a message
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

/// The depth a recursive message's JSON decoder is built for.
pub(super) const DEPTH: &str = "depth";

/// The table of a recursive type's JSON decoders by depth: `levelsNode`.
/// The prefix is no other generated value's, so it cannot collide.
pub(super) fn levels_name(elm_name: &str) -> String {
    format!("levels{elm_name}")
}

/// A recursive type's JSON decoder built for one depth: `levelNode`.
pub(super) fn level_name(elm_name: &str) -> String {
    format!("level{elm_name}")
}

impl Emitter {
    /// A value on the cycle of the message being decoded, of the message
    /// `elm_name`, read one level deeper: `Proto.Json.deeper depth (\_ ->
    /// levelsNode)`, or `Proto.Json.deeperWith depth (levelNodeWith
    /// types)` for a message that takes the registry.
    pub(super) fn deeper(&mut self, deep: Deep, elm_name: &str) -> Expr {
        match deep {
            Deep::Table => {
                let deeper = self.reference((PROTO_JSON, "deeper"));
                let table = lambda([Pattern::Wildcard], var(levels_name(elm_name)));
                apply(deeper, [var(DEPTH), table])
            }
            Deep::Built => {
                let deeper = self.reference((PROTO_JSON, "deeperWith"));
                let build = apply(
                    var(with_registry(level_name(elm_name))),
                    [var(REGISTRY_ARGUMENT)],
                );
                apply(deeper, [var(DEPTH), build])
            }
        }
    }

    /// The decoders of a recursive message, or of a oneof of one, from the
    /// decoder `body` built for the depth `depth`: under `Deep::Table`,
    /// `decodeNode = Proto.Json.atLevel 1 levelsNode`, `levelsNode =
    /// Proto.Json.levels levelNode` and `levelNode depth = body`; under
    /// `Deep::Built`, `decodeNodeWith types = levelNodeWith types 1` and
    /// `levelNodeWith types depth = body`.
    pub(super) fn leveled_decoders(
        &mut self,
        deep: Deep,
        elm_name: &str,
        decoder_name: String,
        doc: String,
        body: Expr,
    ) -> Vec<Decl> {
        let of = ty(elm_name.to_owned(), []);
        let decoder = self.library_type(JSON_DECODE, "Decoder", [of.clone()]);
        let int_type = ty(self.core("Int"), []);
        match deep {
            Deep::Table => {
                let levels = self.library_type(PROTO_JSON, "Levels", [of]);
                let at_level = self.reference((PROTO_JSON, "atLevel"));
                let build = self.reference((PROTO_JSON, "levels"));
                vec![
                    Decl::Value {
                        doc: Some(doc),
                        name: decoder_name.clone(),
                        annotation: decoder.clone(),
                        params: Vec::new(),
                        body: apply(at_level, [int(1), var(levels_name(elm_name))]),
                    },
                    Decl::Value {
                        doc: Some(format!(
                            "[`{decoder_name}`](#{decoder_name}) at each depth up to the runtime's limit, built once."
                        )),
                        name: levels_name(elm_name),
                        annotation: levels,
                        params: Vec::new(),
                        body: apply(build, [var(level_name(elm_name))]),
                    },
                    Decl::Value {
                        doc: Some(format!(
                            "[`{decoder_name}`](#{decoder_name}) built for one nesting depth, the outermost message of its cycle at 1."
                        )),
                        name: level_name(elm_name),
                        annotation: Type::Function(Box::new(int_type), Box::new(decoder)),
                        params: vec![pvar(DEPTH)],
                        body,
                    },
                ]
            }
            Deep::Built => {
                let registry = self.library_type(PROTO_REGISTRY, "Registry", []);
                let with = with_registry(decoder_name);
                let level = with_registry(level_name(elm_name));
                vec![
                    Decl::Value {
                        doc: Some(doc),
                        name: with.clone(),
                        annotation: Type::Function(
                            Box::new(registry.clone()),
                            Box::new(decoder.clone()),
                        ),
                        params: vec![pvar(REGISTRY_ARGUMENT)],
                        body: apply(var(level.clone()), [var(REGISTRY_ARGUMENT), int(1)]),
                    },
                    Decl::Value {
                        doc: Some(format!(
                            "[`{with}`](#{with}) built for one nesting depth, the outermost message of its cycle at 1."
                        )),
                        name: level,
                        annotation: Type::Function(
                            Box::new(registry),
                            Box::new(Type::Function(Box::new(int_type), Box::new(decoder))),
                        ),
                        params: vec![pvar(REGISTRY_ARGUMENT), pvar(DEPTH)],
                        body,
                    },
                ]
            }
        }
    }

    /// The decoders of a oneof of a recursive message with a member on its
    /// cycle: `decodeExprValue = levelExprValue 1` and `levelExprValue depth
    /// = body`, built at each depth by its message's (no table of its own);
    /// under `Deep::Built`, as [`Self::leveled_decoders`] writes them.
    pub(super) fn leveled_oneof(
        &mut self,
        deep: Deep,
        elm_name: &str,
        decoder_name: String,
        doc: String,
        body: Expr,
    ) -> Vec<Decl> {
        if deep == Deep::Built {
            return self.leveled_decoders(deep, elm_name, decoder_name, doc, body);
        }
        let of = ty(elm_name.to_owned(), []);
        let decoder = self.library_type(JSON_DECODE, "Decoder", [of]);
        let int_type = ty(self.core("Int"), []);
        vec![
            Decl::Value {
                doc: Some(doc),
                name: decoder_name.clone(),
                annotation: decoder.clone(),
                params: Vec::new(),
                body: apply(var(level_name(elm_name)), [int(1)]),
            },
            Decl::Value {
                doc: Some(format!(
                    "[`{decoder_name}`](#{decoder_name}) built for one nesting depth of its message."
                )),
                name: level_name(elm_name),
                annotation: Type::Function(Box::new(int_type), Box::new(decoder)),
                params: vec![pvar(DEPTH)],
                body,
            },
        ]
    }
}
