//! A oneof's three declarations: its custom type, its encoder and its
//! decoder (design §3.6).

use super::field::{ValueShape, Zeroed};
use super::{Emitter, JSON_DECODE, JSON_ENCODE, OneofShape, PROTO_ANY, PROTO_JSON, docs};
use crate::elm::ast::{Decl, Expr, Type, Variant};
use crate::elm::build::{apply, case, list, pctor, pvar, qualified, string, ty, ty_fn, var};
use crate::ir::{Message, ModuleName};
use crate::naming::{ENCODER_ARGUMENT, ONEOF_MEMBER, REGISTRY_ARGUMENT, with_registry};

impl Emitter {
    /// `type FooKind = FooKindUnset | FooKindBar Bar | ...`: the unset case
    /// first, then a constructor per member carrying its value, or nothing
    /// for a member of `google.protobuf.Empty` or `google.protobuf.NullValue`.
    /// `message` holds it, and
    /// `package` is its package's module.
    pub(super) fn oneof_type(
        &mut self,
        package: &ModuleName,
        message: &Message,
        shape: &OneofShape,
    ) -> Decl {
        let descriptors = docs::page(&message.descriptor_module(package));
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
            doc: Some(docs::oneof(
                &message.proto_full_name,
                shape.oneof,
                &descriptors,
            )),
            name: shape.oneof.elm_type_name.clone(),
            type_params: Vec::new(),
            variants: std::iter::once(unset)
                .chain(members.collect::<Vec<_>>())
                .collect(),
        }
    }

    /// `encodeFooKind : FooKind -> List ( String, Maybe Json.Encode.Value )`:
    /// the set member under its JSON name, or nothing when unset, for the
    /// message's encoder to add to its `Proto.Json.objectOfFields`. The set member
    /// is always `Just`, even at its type's default: being set is what a
    /// oneof says. A member of `google.protobuf.Empty` encodes as `{}`, one
    /// of `google.protobuf.NullValue` as `null`.
    ///
    /// A oneof with a member that reaches an `Any` under `codec=both` gets
    /// `encodeFooKindWith`, taking the registry first, whose members' JSON
    /// is a `Result`: a member that reaches one gives its encoder's, the
    /// others `Ok`.
    pub(super) fn oneof_encoder(&mut self, shape: &OneofShape) -> Decl {
        let with = self.oneof_reaches(shape);
        let unset = (pctor(shape.oneof.unset_ctor.clone(), []), list([]));
        let members: Vec<_> = shape
            .variants
            .iter()
            .map(|&(variant, value)| {
                let (pattern, encoded) = if matches!(value, ValueShape::Zeroed(Zeroed::Empty)) {
                    let object = self.reference((JSON_ENCODE, "object"));
                    (
                        pctor(variant.elm_ctor.clone(), []),
                        apply(object, [list([])]),
                    )
                } else if matches!(value, ValueShape::Zeroed(Zeroed::Null)) {
                    let null = self.reference((JSON_ENCODE, "null"));
                    (pctor(variant.elm_ctor.clone(), []), null)
                } else {
                    (
                        pctor(variant.elm_ctor.clone(), [pvar(ONEOF_MEMBER)]),
                        self.encode_value(value, var(ONEOF_MEMBER)),
                    )
                };
                let just = var(self.core("Just"));
                let json = if !with {
                    apply(just, [encoded])
                } else if self.reaches(value) {
                    apply(qualified("Result", "map"), [just, encoded])
                } else {
                    let ok = var(self.core("Ok"));
                    apply(ok, [apply(just, [encoded])])
                };
                (
                    pattern,
                    list([Expr::Tuple(vec![string(variant.json_name.clone()), json])]),
                )
            })
            .collect();
        let value_type = self.library_type(JSON_ENCODE, "Value", []);
        let maybe = ty(self.core("Maybe"), [value_type]);
        let member = if with {
            let problem = self.library_type(PROTO_ANY, "Problem", []);
            ty(self.core("Result"), [problem, maybe])
        } else {
            maybe
        };
        let pair = Type::Tuple(vec![ty(self.core("String"), []), member]);
        let oneof = ty(shape.oneof.elm_type_name.clone(), []);
        let members_type = ty(self.core("List"), [pair]);
        let (name, annotation, params) = if with {
            let registry = self.library_type(super::PROTO_REGISTRY, "Registry", []);
            (
                with_registry(shape.oneof.encoder_name()),
                ty_fn([registry, oneof], members_type),
                vec![pvar(REGISTRY_ARGUMENT), pvar(ENCODER_ARGUMENT)],
            )
        } else {
            (
                shape.oneof.encoder_name(),
                ty_fn([oneof], members_type),
                vec![pvar(ENCODER_ARGUMENT)],
            )
        };
        Decl::Value {
            doc: Some(format!(
                "Encodes {} as the members of its message's JSON object.",
                docs::a_local(&shape.oneof.elm_type_name)
            )),
            name,
            annotation,
            params,
            body: case(var(ENCODER_ARGUMENT), std::iter::once(unset).chain(members)),
        }
    }

    /// Whether a member of a oneof reaches an `Any` under `codec=both`.
    pub(super) fn oneof_reaches(&self, shape: &OneofShape) -> bool {
        shape.variants.iter().any(|&(_, value)| self.reaches(value))
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
    /// as protobuf's parsers read it, and a member of
    /// `google.protobuf.NullValue` a `nullValueMember` step likewise. A oneof
    /// with a member that reaches an `Any` under `codec=both` gets
    /// `decodeFooKindWith`, taking the registry.
    pub(super) fn oneof_decoder(&mut self, shape: &OneofShape) -> Decl {
        let steps: Vec<Expr> = shape
            .variants
            .iter()
            .map(|&(variant, value)| {
                let ctor = var(variant.elm_ctor.clone());
                let (helper, arg) = match value {
                    ValueShape::Zeroed(Zeroed::Empty) => ("emptyMember", ctor),
                    ValueShape::Zeroed(Zeroed::Json) => ("valueMember", ctor),
                    ValueShape::Zeroed(Zeroed::Null) => ("nullValueMember", ctor),
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
        let oneof = ty(shape.oneof.elm_type_name.clone(), []);
        let (name, annotation, params) = if self.oneof_reaches(shape) {
            (
                with_registry(shape.oneof.decoder_name()),
                self.decoder_with_type(oneof),
                vec![pvar(REGISTRY_ARGUMENT)],
            )
        } else {
            (
                shape.oneof.decoder_name(),
                self.library_type(JSON_DECODE, "Decoder", [oneof]),
                Vec::new(),
            )
        };
        Decl::Value {
            doc: Some(format!(
                "Decodes {} from the members of its message's JSON object.",
                docs::a_local(&shape.oneof.elm_type_name)
            )),
            name,
            annotation,
            params,
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

/// Whether a member is of `google.protobuf.Empty` or
/// `google.protobuf.NullValue`, which carry nothing, so its constructor
/// takes no argument.
fn is_empty(value: ValueShape) -> bool {
    matches!(value, ValueShape::Zeroed(Zeroed::Empty | Zeroed::Null))
}
