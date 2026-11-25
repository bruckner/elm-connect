//! A recursive message's wrapper: its custom type, encoder and decoder
//! (design §3.2).

use super::field::{Present, ValueShape, Zeroed};
use super::{Deep, Emitter, FAILS, JSON_DECODE, OneofShape, PROTO_JSON, PROTO_REGISTRY, docs};
use crate::elm::ast::{BinOp, Decl, Expr, Pattern, Type, Variant};
use crate::elm::build::{apply, binop, int, lambda, pctor, pvar, ty, var};
use crate::ir::{Message, TypeName, Wrapper};
use crate::naming::{ENCODER_ARGUMENT, REGISTRY_ARGUMENT, decoder_name, nested, with_registry};

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

    /// `encodeNode_ (Node_ value) = encodeNode value`, of the type
    /// `encodeNode` has.
    pub(super) fn wrapper_encoder(&mut self, message: &Message, wrapper: &Wrapper) -> Decl {
        let refusable = self.write_reach.message(&message.proto_full_name);
        let annotation = self.json_encoder_type(refusable);
        Decl::Value {
            doc: Some(format!(
                "Encodes {} as proto3 JSON{}.",
                docs::a_local(&wrapper.elm_name),
                if refusable { FAILS } else { "" }
            )),
            name: wrapper.encoder_name(),
            annotation: Type::Function(
                Box::new(ty(wrapper.elm_name.clone(), [])),
                Box::new(annotation),
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

impl Emitter {
    /// A value on the cycle of the message being decoded, of the message
    /// `elm_name`, read one level deeper: `Json.Decode.lazy (\_ ->
    /// decodeNestedNode (depth + 1))`, the lazy step keeping the memoised
    /// decoders from being needed while they are made; or
    /// `Proto.Json.deeperWith depth (decodeNestedNodeWith types)` for a
    /// message that takes the registry.
    pub(super) fn deeper(&mut self, deep: Deep, elm_name: &str) -> Expr {
        let decoder = decoder_name(elm_name);
        match deep {
            Deep::Memo | Deep::Called => {
                let next = binop(BinOp::Add, var(DEPTH), int(1));
                self.lazy(apply(var(nested(decoder)), [next]))
            }
            Deep::Built => {
                let deeper = self.reference((PROTO_JSON, "deeperWith"));
                let build = apply(
                    var(nested(with_registry(decoder))),
                    [var(REGISTRY_ARGUMENT)],
                );
                apply(deeper, [var(DEPTH), build])
            }
        }
    }

    /// Whether `message` nests, so it counts as a level of nesting and its
    /// codecs take the depth.
    pub(super) fn counts(&self, message: &Message) -> bool {
        self.counted.message(&message.proto_full_name)
    }

    /// The message a value is, when its codecs take the depth.
    pub(super) fn counted_message<'v>(&self, value: ValueShape<'v>) -> Option<&'v TypeName> {
        match value {
            ValueShape::Present(Present::Message(name))
                if self.counted.message(&name.proto_full_name) =>
            {
                Some(name)
            }
            _ => None,
        }
    }

    /// Whether a oneof of a message whose codecs take the depth (`counts`)
    /// takes its message's depth: a member is a message whose codecs take
    /// the depth, a `Value`, `Struct` or `ListValue`, or an `Any`, each of
    /// which counts on from the message.
    pub(super) fn oneof_counts(&self, counts: bool, shape: &OneofShape) -> bool {
        counts
            && shape.variants.iter().any(|&(variant, value)| {
                variant.cyclic
                    || self.counted_message(value).is_some()
                    || matches!(
                        value,
                        ValueShape::Zeroed(Zeroed::Json)
                            | ValueShape::Present(
                                Present::Struct | Present::ListValue | Present::Any
                            )
                    )
            })
    }

    /// A message off the cycle of the message being decoded, whose codecs
    /// take the depth, read one level deeper. One on a cycle:
    /// `decodeNestedTree (depth + 1)`, from its memoised decoders, which the
    /// holder's reach directly, as nothing the other reaches leads back; or
    /// `Proto.Json.deeperWith depth (decodeNestedTreeWith types)` for one
    /// that takes the registry, built as the value is read. One on no
    /// cycle: `Proto.Json.deeperWith depth decodeNestedNote`, built as the
    /// value is read, since a decoder made here for every path to it would
    /// be made once per path; or `Proto.Json.deeper depth
    /// (decodeNestedNoteWith types)` for one that takes the registry, made
    /// once as the holder's decoder is, which itself is made as it is read,
    /// as the plain codecs of such messages always were.
    pub(super) fn counted_decoder(&mut self, name: &TypeName) -> Expr {
        let with = self.reach.message(&name.proto_full_name);
        let decoder = if with {
            nested(with_registry(name.decoder_name()))
        } else {
            nested(name.decoder_name())
        };
        let decoder = self.generated_value(&name.module, decoder);
        let build = if with {
            apply(decoder, [var(REGISTRY_ARGUMENT)])
        } else {
            decoder
        };
        let recursive = self.counted.recursive(&name.proto_full_name);
        if with && !recursive {
            let deeper = self.reference((PROTO_JSON, "deeper"));
            apply(deeper, [var(DEPTH), build])
        } else if with || !recursive {
            let deeper = self.reference((PROTO_JSON, "deeperWith"));
            apply(deeper, [var(DEPTH), build])
        } else {
            apply(build, [binop(BinOp::Add, var(DEPTH), int(1))])
        }
    }

    /// The decoders of a message that nests, from the decoder `body` built
    /// for the depth `depth`: under `Deep::Memo`, `decodeNode =
    /// decodeNestedNode 1` and `decodeNestedNode = Proto.Json.memo
    /// (\depth -> body)`; under `Deep::Called`, `decodeNestedNote depth =
    /// body`; under `Deep::Built`, `decodeNodeWith types =
    /// decodeNestedNodeWith types 1` and `decodeNestedNodeWith types depth
    /// = body`.
    pub(super) fn nested_decoders(
        &mut self,
        deep: Deep,
        elm_name: &str,
        decoder_name: String,
        doc: String,
        body: Expr,
    ) -> Vec<Decl> {
        let of = ty(elm_name.to_owned(), []);
        let decoder = self.library_type(JSON_DECODE, "Decoder", [of]);
        let int_type = ty(self.core("Int"), []);
        match deep {
            Deep::Memo | Deep::Called => {
                let nested_decoder = nested(decoder_name.clone());
                let (params, body) = if deep == Deep::Memo {
                    let memo = self.reference((PROTO_JSON, "memo"));
                    (Vec::new(), apply(memo, [lambda([pvar(DEPTH)], body)]))
                } else {
                    (vec![pvar(DEPTH)], body)
                };
                vec![
                    Decl::Value {
                        doc: Some(doc),
                        name: decoder_name.clone(),
                        annotation: decoder.clone(),
                        params: Vec::new(),
                        body: apply(var(nested_decoder.clone()), [int(1)]),
                    },
                    Decl::Value {
                        doc: Some(docs::nested(&decoder_name, elm_name)),
                        name: nested_decoder,
                        annotation: Type::Function(Box::new(int_type), Box::new(decoder)),
                        params,
                        body,
                    },
                ]
            }
            Deep::Built => {
                let registry = self.library_type(PROTO_REGISTRY, "Registry", []);
                let with = with_registry(decoder_name);
                let nested_decoder = nested(with.clone());
                vec![
                    Decl::Value {
                        doc: Some(doc),
                        name: with.clone(),
                        annotation: Type::Function(
                            Box::new(registry.clone()),
                            Box::new(decoder.clone()),
                        ),
                        params: vec![pvar(REGISTRY_ARGUMENT)],
                        body: apply(
                            var(nested_decoder.clone()),
                            [
                                var(REGISTRY_ARGUMENT),
                                apply(
                                    var("max"),
                                    [
                                        int(1),
                                        apply(
                                            self.reference((PROTO_JSON, "registryDepth")),
                                            [var(REGISTRY_ARGUMENT)],
                                        ),
                                    ],
                                ),
                            ],
                        ),
                    },
                    Decl::Value {
                        doc: Some(docs::nested(&with, elm_name)),
                        name: nested_decoder,
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

    /// The decoders of a oneof of a message that nests with a member that
    /// counts on from it ([`Self::oneof_counts`]): `decodeExprValue =
    /// decodeNestedExprValue 1` and
    /// `decodeNestedExprValue depth = body`, built at each depth by its message's decoder (it is
    /// not memoised itself); under `Deep::Built`, as
    /// [`Self::nested_decoders`] writes them.
    pub(super) fn nested_oneof_decoders(
        &mut self,
        deep: Deep,
        elm_name: &str,
        decoder_name: String,
        doc: String,
        body: Expr,
    ) -> Vec<Decl> {
        if deep == Deep::Built {
            return self.nested_decoders(deep, elm_name, decoder_name, doc, body);
        }
        let of = ty(elm_name.to_owned(), []);
        let decoder = self.library_type(JSON_DECODE, "Decoder", [of]);
        let int_type = ty(self.core("Int"), []);
        let nested_decoder = nested(decoder_name.clone());
        vec![
            Decl::Value {
                doc: Some(doc),
                name: decoder_name.clone(),
                annotation: decoder.clone(),
                params: Vec::new(),
                body: apply(var(nested_decoder.clone()), [int(1)]),
            },
            Decl::Value {
                doc: Some(format!(
                    "[`{decoder_name}`](#{decoder_name}) for {} held by a message `depth` levels deep.",
                    docs::a_local(elm_name)
                )),
                name: nested_decoder,
                annotation: Type::Function(Box::new(int_type), Box::new(decoder)),
                params: vec![pvar(DEPTH)],
                body,
            },
        ]
    }
}
