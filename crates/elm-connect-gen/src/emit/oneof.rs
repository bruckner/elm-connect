//! A oneof's three declarations: its custom type, its encoder and its
//! decoder (design §3.6).

use super::{CONNECT_JSON, Emitter, JSON_DECODE, JSON_ENCODE, OneofShape, call};
use crate::elm::ast::{Decl, Expr, Type, Variant};
use crate::elm::build::{apply, case, list, pctor, pvar, string, ty, var};
use crate::naming::{ENCODER_ARGUMENT, ONEOF_MEMBER};

impl Emitter {
    /// `type FooKind = FooKindUnset | FooKindBar Bar | ...`: the unset case
    /// first, then a constructor per member carrying its value.
    pub(super) fn oneof_type(&mut self, shape: &OneofShape) -> Decl {
        let unset = Variant {
            name: shape.oneof.unset_ctor.clone(),
            args: Vec::new(),
        };
        let members = shape.variants.iter().map(|&(variant, value)| Variant {
            name: variant.elm_ctor.clone(),
            args: vec![self.value_type(value)],
        });
        Decl::CustomType {
            doc: None,
            name: shape.oneof.elm_type_name.clone(),
            type_params: Vec::new(),
            variants: std::iter::once(unset)
                .chain(members.collect::<Vec<_>>())
                .collect(),
        }
    }

    /// `encodeFooKind : FooKind -> List ( String, Json.Encode.Value )`: the
    /// set member under its JSON name, or nothing when unset, for the
    /// message's encoder to add to its object.
    pub(super) fn oneof_encoder(&mut self, shape: &OneofShape) -> Decl {
        let unset = (pctor(shape.oneof.unset_ctor.clone(), []), list([]));
        let members: Vec<_> = shape
            .variants
            .iter()
            .map(|&(variant, value)| {
                let encode = self.value_encoder(value);
                (
                    pctor(variant.elm_ctor.clone(), [pvar(ONEOF_MEMBER)]),
                    list([Expr::Tuple(vec![
                        string(variant.json_name.clone()),
                        call(encode, [var(ONEOF_MEMBER)]),
                    ])]),
                )
            })
            .collect();
        let value_type = self.library_type(JSON_ENCODE, "Value", []);
        let pair = Type::Tuple(vec![ty("String", []), value_type]);
        Decl::Value {
            doc: None,
            name: shape.oneof.encoder_name(),
            annotation: Type::Function(
                Box::new(ty(shape.oneof.elm_type_name.clone(), [])),
                Box::new(ty("List", [pair])),
            ),
            params: vec![pvar(ENCODER_ARGUMENT)],
            body: case(var(ENCODER_ARGUMENT), std::iter::once(unset).chain(members)),
        }
    }

    /// `decodeFooKind : Json.Decode.Decoder FooKind`: `Json.Decode.oneOf`
    /// over a `Connect.Json.member` per member, in declaration order, then
    /// `Json.Decode.succeed FooKindUnset`. A member present as `null` is
    /// skipped, so it reads as unset.
    pub(super) fn oneof_decoder(&mut self, shape: &OneofShape) -> Decl {
        let mut alternatives: Vec<Expr> = shape
            .variants
            .iter()
            .map(|&(variant, value)| {
                let decode = self.value_decoder(value);
                let map = self.reference((JSON_DECODE, "map"));
                let decoder = apply(map, [var(variant.elm_ctor.clone()), decode]);
                let step = if variant.json_name == variant.proto_name {
                    let member = self.reference((CONNECT_JSON, "member"));
                    apply(member, [string(variant.json_name.clone())])
                } else {
                    let member = self.reference((CONNECT_JSON, "memberEither"));
                    apply(
                        member,
                        [
                            string(variant.json_name.clone()),
                            string(variant.proto_name.clone()),
                        ],
                    )
                };
                call(step, [decoder])
            })
            .collect();
        let succeed = self.reference((JSON_DECODE, "succeed"));
        alternatives.push(apply(succeed, [var(shape.oneof.unset_ctor.clone())]));
        let one_of = self.reference((JSON_DECODE, "oneOf"));
        let annotation = self.library_type(
            JSON_DECODE,
            "Decoder",
            [ty(shape.oneof.elm_type_name.clone(), [])],
        );
        Decl::Value {
            doc: None,
            name: shape.oneof.decoder_name(),
            annotation,
            params: Vec::new(),
            body: apply(one_of, [list(alternatives)]),
        }
    }
}
