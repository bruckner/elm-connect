//! A oneof's three declarations: its custom type, its encoder and its
//! decoder (design §3.6).

use super::Deep;
use super::field::{ValueShape, Zeroed};
use super::{Emitter, JSON_DECODE, JSON_ENCODE, OneofShape, PROTO_JSON, docs};
use crate::elm::ast::{Decl, Expr, Type, Variant};
use crate::elm::build::{apply, case, list, pctor, pvar, string, ty, ty_fn, var};
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
    /// A oneof with a member whose write can be refused gives each member
    /// as a `Proto.Json.Encoder Proto.Error.Error` instead, for
    /// `Proto.Json.writeObject`: a member that can be refused, or a message,
    /// gives its encoder, the others their JSON in `Proto.Json.ready`.
    pub(super) fn oneof_encoder(&mut self, shape: &OneofShape) -> Decl {
        let with = self.oneof_write_reaches(shape);
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
                    let encoded = self.encode_value(value, var(ONEOF_MEMBER));
                    (
                        pctor(variant.elm_ctor.clone(), [pvar(ONEOF_MEMBER)]),
                        encoded,
                    )
                };
                let json = if !with {
                    let just = var(self.core("Just"));
                    apply(just, [encoded])
                } else if self.write_reaches(value) {
                    let reaches = self.reaches(value);
                    self.deeper_if_cyclic(variant.cyclic, reaches, encoded)
                } else if let Some(encoder) = self.total_message_encoder(value) {
                    // A message that cannot refuse is an encoder for any
                    // refusal type already.
                    apply(encoder, [var(ONEOF_MEMBER)])
                } else {
                    let ready = self.reference((super::PROTO_JSON, "ready"));
                    apply(ready, [encoded])
                };
                (
                    pattern,
                    list([Expr::Tuple(vec![string(variant.json_name.clone()), json])]),
                )
            })
            .collect();
        let member = if with {
            self.json_encoder_type(true)
        } else {
            let value_type = self.library_type(JSON_ENCODE, "Value", []);
            ty(self.core("Maybe"), [value_type])
        };
        let pair = Type::Tuple(vec![ty(self.core("String"), []), member]);
        let oneof = ty(shape.oneof.elm_type_name.clone(), []);
        let members_type = ty(self.core("List"), [pair]);
        Decl::Value {
            doc: Some(format!(
                "Encodes {} as the members of its message's JSON object.",
                docs::a_local(&shape.oneof.elm_type_name)
            )),
            name: shape.oneof.encoder_name(),
            annotation: ty_fn([oneof], members_type),
            params: vec![pvar(ENCODER_ARGUMENT)],
            body: case(var(ENCODER_ARGUMENT), std::iter::once(unset).chain(members)),
        }
    }

    /// Whether a member of a oneof has a write that can be refused.
    pub(super) fn oneof_write_reaches(&self, shape: &OneofShape) -> bool {
        shape
            .variants
            .iter()
            .any(|&(_, value)| self.write_reaches(value))
    }

    /// Whether a member of a oneof reaches an `Any`.
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
    /// with a member that reaches an `Any` gets
    /// `decodeFooKindWith`, taking the registry.
    /// For a oneof of a recursive message with a member on its cycle
    /// (`recursive`), the decoders take the depth as the message's do, and
    /// the member is read one level deeper.
    pub(super) fn oneof_decoder(&mut self, shape: &OneofShape, recursive: bool) -> Vec<Decl> {
        let on_cycle = recursive && shape.variants.iter().any(|(variant, _)| variant.cyclic);
        let deep = on_cycle.then(|| {
            if self.oneof_reaches(shape) {
                Deep::Built
            } else {
                Deep::Memo
            }
        });
        self.deep = deep;
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
                        self.deep_value = variant.cyclic;
                        let mut decode = self.value_decoder(value);
                        self.deep_value = false;
                        if variant.cyclic && deep.is_none() {
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
        self.deep = None;
        let members = self.reference((PROTO_JSON, "members"));
        let body = apply(
            members,
            [
                string(shape.oneof.proto_name.clone()),
                var(shape.oneof.unset_ctor.clone()),
                list(steps),
            ],
        );
        let doc = format!(
            "Decodes {} from the members of its message's JSON object.",
            docs::a_local(&shape.oneof.elm_type_name)
        );
        if let Some(deep) = deep {
            let elm_name = shape.oneof.elm_type_name.clone();
            return self.nested_oneof_decoders(
                deep,
                &elm_name,
                shape.oneof.decoder_name(),
                doc,
                body,
            );
        }
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
        vec![Decl::Value {
            doc: Some(doc),
            name,
            annotation,
            params,
            body,
        }]
    }
}

/// Whether a member is of `google.protobuf.Empty` or
/// `google.protobuf.NullValue`, which carry nothing, so its constructor
/// takes no argument.
fn is_empty(value: ValueShape) -> bool {
    matches!(value, ValueShape::Zeroed(Zeroed::Empty | Zeroed::Null))
}
