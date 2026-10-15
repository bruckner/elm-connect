//! A oneof's three declarations: its custom type, its encoder and its
//! decoder (design §3.6).

use super::field::{ValueShape, Zeroed};
use super::{Emitter, JSON_DECODE, JSON_ENCODE, OneofShape, PROTO_JSON};
use crate::elm::ast::{Decl, Expr, Type, Variant};
use crate::elm::build::{apply, case, list, pctor, pvar, string, ty, var};
use crate::naming::{ENCODER_ARGUMENT, ONEOF_MEMBER};

impl Emitter {
    /// `type FooKind = FooKindUnset | FooKindBar Bar | ...`: the unset case
    /// first, then a constructor per member carrying its value, or nothing
    /// for a member of `google.protobuf.Empty`.
    pub(super) fn oneof_type(&mut self, shape: &OneofShape) -> Decl {
        let unset = Variant {
            name: shape.oneof.unset_ctor.clone(),
            args: Vec::new(),
        };
        let members = shape.variants.iter().map(|&(variant, value)| Variant {
            name: variant.elm_ctor.clone(),
            args: if is_empty(value) {
                Vec::new()
            } else {
                vec![self.value_type(value)]
            },
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

    /// `encodeFooKind : FooKind -> List ( String, Maybe Json.Encode.Value )`:
    /// the set member under its JSON name, or nothing when unset, for the
    /// message's encoder to add to its `Proto.Json.object`. The set member
    /// is always `Just`, even at its type's default: being set is what a
    /// oneof says. A member of `google.protobuf.Empty` encodes as `{}`.
    pub(super) fn oneof_encoder(&mut self, shape: &OneofShape) -> Decl {
        let unset = (pctor(shape.oneof.unset_ctor.clone(), []), list([]));
        let members: Vec<_> = shape
            .variants
            .iter()
            .map(|&(variant, value)| {
                let (pattern, encoded) = if is_empty(value) {
                    let object = self.reference((JSON_ENCODE, "object"));
                    (
                        pctor(variant.elm_ctor.clone(), []),
                        apply(object, [list([])]),
                    )
                } else {
                    (
                        pctor(variant.elm_ctor.clone(), [pvar(ONEOF_MEMBER)]),
                        self.encode_value(value, var(ONEOF_MEMBER)),
                    )
                };
                (
                    pattern,
                    list([Expr::Tuple(vec![
                        string(variant.json_name.clone()),
                        apply(var("Just"), [encoded]),
                    ])]),
                )
            })
            .collect();
        let value_type = self.library_type(JSON_ENCODE, "Value", []);
        let pair = Type::Tuple(vec![ty("String", []), ty("Maybe", [value_type])]);
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

    /// `decodeFooKind : Json.Decode.Decoder FooKind`:
    /// `Proto.Json.members "kind" FooKindUnset [ ... ]`, a member step per
    /// member in declaration order, which reads the one member present
    /// (absent or `null` being not present), unset when none is, and fails
    /// on a malformed member or on more than one present (design §3.6).
    ///
    /// Each step is `Proto.Json.member`, or `memberEither` when the JSON
    /// and proto names differ, with the member's decoder mapped onto its
    /// constructor; a member that closes a cycle decodes through
    /// `Json.Decode.lazy`. A member of `google.protobuf.Empty` is an
    /// `emptyMember` step given its constructor, read as set when its key
    /// holds an object. A member of `google.protobuf.Value` is a
    /// `valueMember` step given its constructor, for which `null` is set,
    /// as protobuf's parsers read it.
    pub(super) fn oneof_decoder(&mut self, shape: &OneofShape) -> Decl {
        let steps: Vec<Expr> = shape
            .variants
            .iter()
            .map(|&(variant, value)| {
                let ctor = var(variant.elm_ctor.clone());
                let (helper, arg) = match value {
                    ValueShape::Zeroed(Zeroed::Empty) => ("emptyMember", ctor),
                    ValueShape::Zeroed(Zeroed::Json) => ("valueMember", ctor),
                    _ => {
                        let mut decode = self.value_decoder(value);
                        if variant.cyclic {
                            decode = self.lazy(decode);
                        }
                        let map = self.reference((JSON_DECODE, "map"));
                        ("member", apply(map, [ctor, decode]))
                    }
                };
                let names = if variant.json_name == variant.proto_name {
                    vec![string(variant.json_name.clone())]
                } else {
                    vec![
                        string(variant.json_name.clone()),
                        string(variant.proto_name.clone()),
                    ]
                };
                let helper = if names.len() == 1 {
                    helper.to_owned()
                } else {
                    format!("{helper}Either")
                };
                let step = self.reference((PROTO_JSON, &helper));
                apply(step, names.into_iter().chain([arg]))
            })
            .collect();
        let members = self.reference((PROTO_JSON, "members"));
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
            body: apply(
                members,
                [
                    string(shape.oneof.proto_name.clone()),
                    var(shape.oneof.unset_ctor.clone()),
                    list(steps),
                ],
            ),
        }
    }
}

/// Whether a member is of `google.protobuf.Empty`, which carries nothing,
/// so its constructor takes no argument.
fn is_empty(value: ValueShape) -> bool {
    matches!(value, ValueShape::Zeroed(Zeroed::Empty))
}
