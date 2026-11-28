//! Which messages reach a `google.protobuf.Any`: those holding one in a
//! field, a map value or a oneof member, or holding a message that does,
//! across packages. Under `codec=both` an `Any` holds its message's binary,
//! so the JSON decoders of these messages take a registry (design §3.5).
//!
//! The same walk, seeded also with the well-known types whose Elm values
//! can hold what proto3 JSON has no form for, finds the messages whose JSON
//! write can be refused: their encoders are built from
//! `Proto.Json.Encode.object`, and the others are written by plain code.

use std::collections::BTreeSet;

use super::{Message, Oneof, Package, TypeRef, WellKnown};

/// The messages that reach a `google.protobuf.Any`, or, built by
/// [`AnyReach::refusable`], whose JSON write can be refused; by full proto
/// name.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct AnyReach {
    messages: BTreeSet<String>,
    /// Whether the well-known types whose Elm values can hold what proto3
    /// JSON cannot write seed the walk beside `Any`.
    checked: bool,
}

impl AnyReach {
    /// The messages of `packages` that reach an `Any`. A message that
    /// holds one directly does; then, until nothing changes, so does one
    /// holding a message that does, so a cycle of messages ends.
    pub fn of<'p>(packages: impl IntoIterator<Item = &'p Package>) -> Self {
        Self::walk(packages, false)
    }

    /// The messages of `packages` whose JSON write can be refused: those
    /// that reach an `Any` or a well-known type with values proto3 JSON has
    /// no form for ([`checked`]).
    pub fn refusable<'p>(packages: impl IntoIterator<Item = &'p Package>) -> Self {
        Self::walk(packages, true)
    }

    fn walk<'p>(packages: impl IntoIterator<Item = &'p Package>, checked: bool) -> Self {
        let messages: Vec<&Message> = packages
            .into_iter()
            .flat_map(|package| &package.messages)
            .collect();
        let mut reach = AnyReach {
            checked,
            ..AnyReach::default()
        };
        loop {
            let found: Vec<&str> = messages
                .iter()
                .filter(|message| !reach.message(&message.proto_full_name))
                .filter(|message| held(message).any(|ty| reach.type_ref(ty)))
                .map(|message| message.proto_full_name.as_str())
                .collect();
            if found.is_empty() {
                return reach;
            }
            reach.messages.extend(found.into_iter().map(str::to_owned));
        }
    }

    /// Whether the message `full_name` is in the set.
    pub fn message(&self, full_name: &str) -> bool {
        self.messages.contains(full_name)
    }

    /// Whether a value of `ty` is or reaches an `Any` (or, for
    /// [`AnyReach::refusable`], something refusable).
    pub fn type_ref(&self, ty: &TypeRef) -> bool {
        match ty {
            TypeRef::WellKnown(WellKnown::Any) => true,
            TypeRef::WellKnown(known) if self.checked => checked(*known),
            TypeRef::Message(name) => self.message(&name.proto_full_name),
            TypeRef::Scalar(_) | TypeRef::Enum { .. } | TypeRef::WellKnown(_) => false,
        }
    }

    /// Whether a member of `oneof` is or reaches an `Any` (as
    /// [`AnyReach::type_ref`]).
    pub fn oneof(&self, oneof: &Oneof) -> bool {
        oneof
            .variants
            .iter()
            .any(|variant| self.type_ref(&variant.ty))
    }
}

/// Whether a well-known type's Elm values can hold what proto3 JSON has no
/// form for: a `Timestamp` or a `Duration` that is not valid (only one
/// read from binary can be), a `FieldMask` path that does not round-trip through
/// lowerCamelCase, a number in a `Value` that is not finite.
pub fn checked(known: WellKnown) -> bool {
    matches!(
        known,
        WellKnown::Timestamp
            | WellKnown::Duration
            | WellKnown::FieldMask
            | WellKnown::Value
            | WellKnown::Struct
            | WellKnown::ListValue
    )
}

/// The type of each field and oneof member of `message`.
fn held(message: &Message) -> impl Iterator<Item = &TypeRef> {
    message.fields.iter().map(|field| &field.ty).chain(
        message
            .oneofs
            .iter()
            .flat_map(|oneof| oneof.variants.iter().map(|variant| &variant.ty)),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ir::{
        Annotations, Cardinality, Doc, Field, JsType, MapKey, ModuleName, OneofVariant, ScalarKind,
        TypeName,
    };

    fn package(name: &str, messages: Vec<Message>) -> Package {
        Package {
            proto_name: name.to_lowercase(),
            module: ModuleName::new(vec![name.into()]).expect("valid"),
            files: Vec::new(),
            comments: Vec::new(),
            messages,
            enums: Vec::new(),
            services: Vec::new(),
        }
    }

    fn message(full_name: &str, fields: Vec<Field>, oneofs: Vec<Oneof>) -> Message {
        Message {
            proto_full_name: full_name.into(),
            elm_name: full_name.rsplit('.').next().unwrap().into(),
            fields,
            oneofs,
            wrapper: None,
            recursive: false,
            doc: Doc::default(),
        }
    }

    fn field(cardinality: Cardinality, ty: TypeRef) -> Field {
        Field {
            proto_name: "f".into(),
            json_name: "f".into(),
            number: 1,
            elm_name: "f".into(),
            cardinality,
            ty,
            cyclic: false,
            recursive: false,
            jstype: JsType::Normal,
            unpacked: false,
            annotations: Annotations::default(),
            doc: Doc::default(),
        }
    }

    fn of(full_name: &str) -> TypeRef {
        let (package, name) = full_name.rsplit_once('.').unwrap();
        TypeRef::Message(TypeName {
            module: ModuleName::new(vec![package.to_uppercase()]).expect("valid"),
            name: name.into(),
            proto_full_name: full_name.into(),
        })
    }

    fn oneof(ty: TypeRef) -> Oneof {
        Oneof {
            proto_name: "o".into(),
            elm_field_name: "o".into(),
            elm_type_name: "O".into(),
            unset_ctor: "OUnset".into(),
            position: 0,
            variants: vec![OneofVariant {
                proto_name: "m".into(),
                json_name: "m".into(),
                number: 2,
                elm_ctor: "OM".into(),
                elm_name: "m".into(),
                ty,
                cyclic: false,
                jstype: JsType::Normal,
                annotations: Annotations::default(),
                doc: Doc::default(),
            }],
            doc: Doc::default(),
        }
    }

    const ANY: TypeRef = TypeRef::WellKnown(WellKnown::Any);

    #[test]
    fn a_field_map_value_or_oneof_member_of_any_reaches_it() {
        let packages = [package(
            "A",
            vec![
                message("a.Field", vec![field(Cardinality::Singular, ANY)], vec![]),
                message("a.List", vec![field(Cardinality::Repeated, ANY)], vec![]),
                message(
                    "a.Map",
                    vec![field(Cardinality::Map(MapKey::String), ANY)],
                    vec![],
                ),
                message("a.Member", vec![], vec![oneof(ANY)]),
                message(
                    "a.None",
                    vec![
                        field(Cardinality::Singular, TypeRef::Scalar(ScalarKind::Bytes)),
                        field(Cardinality::Singular, TypeRef::WellKnown(WellKnown::Struct)),
                    ],
                    vec![oneof(TypeRef::WellKnown(WellKnown::Value))],
                ),
            ],
        )];
        let reach = AnyReach::of(&packages);
        let found: Vec<bool> = ["a.Field", "a.List", "a.Map", "a.Member", "a.None"]
            .iter()
            .map(|name| reach.message(name))
            .collect();
        assert_eq!(found, [true, true, true, true, false]);
        assert!(reach.oneof(&oneof(ANY)));
        assert!(!reach.oneof(&oneof(TypeRef::Scalar(ScalarKind::String))));
    }

    #[test]
    fn holding_a_message_that_reaches_it_reaches_it_across_packages() {
        let packages = [
            package(
                "A",
                vec![
                    message(
                        "a.Outer",
                        vec![field(Cardinality::Repeated, of("b.Inner"))],
                        vec![],
                    ),
                    message("a.Choice", vec![], vec![oneof(of("a.Outer"))]),
                    message(
                        "a.Plain",
                        vec![field(Cardinality::Singular, of("b.Leaf"))],
                        vec![],
                    ),
                ],
            ),
            package(
                "B",
                vec![
                    message("b.Inner", vec![field(Cardinality::Singular, ANY)], vec![]),
                    message("b.Leaf", vec![], vec![]),
                ],
            ),
        ];
        let reach = AnyReach::of(&packages);
        assert!(reach.message("a.Outer"));
        assert!(reach.message("a.Choice"));
        assert!(!reach.message("a.Plain"));
        assert!(reach.type_ref(&of("b.Inner")));
        assert!(!reach.type_ref(&of("b.Leaf")));
    }

    #[test]
    fn a_cycle_reaches_it_only_through_a_member_that_does() {
        let packages = [package(
            "A",
            vec![
                // Tree holds itself and Node; Node holds Tree and an Any.
                message(
                    "a.Tree",
                    vec![
                        field(Cardinality::Repeated, of("a.Tree")),
                        field(Cardinality::Singular, of("a.Node")),
                    ],
                    vec![],
                ),
                message(
                    "a.Node",
                    vec![field(Cardinality::Singular, of("a.Tree"))],
                    vec![oneof(ANY)],
                ),
                // Loop holds only itself.
                message(
                    "a.Loop",
                    vec![field(Cardinality::Singular, of("a.Loop"))],
                    vec![],
                ),
            ],
        )];
        let reach = AnyReach::of(&packages);
        assert!(reach.message("a.Tree"));
        assert!(reach.message("a.Node"));
        assert!(!reach.message("a.Loop"));
    }

    #[test]
    fn a_checked_well_known_type_makes_a_write_refusable_but_not_an_any_reach() {
        let packages = [package(
            "A",
            vec![
                message(
                    "a.Stamped",
                    vec![field(
                        Cardinality::Singular,
                        TypeRef::WellKnown(WellKnown::Timestamp),
                    )],
                    vec![],
                ),
                message(
                    "a.Holder",
                    vec![field(Cardinality::Repeated, of("a.Stamped"))],
                    vec![],
                ),
                message(
                    "a.Wrapped",
                    vec![field(
                        Cardinality::Singular,
                        TypeRef::WellKnown(WellKnown::StringValue),
                    )],
                    vec![oneof(TypeRef::WellKnown(WellKnown::Empty))],
                ),
            ],
        )];
        let refusable = AnyReach::refusable(&packages);
        assert!(refusable.message("a.Stamped"));
        assert!(refusable.message("a.Holder"));
        assert!(!refusable.message("a.Wrapped"));
        let reach = AnyReach::of(&packages);
        assert!(!reach.message("a.Stamped"));
        assert!(!reach.message("a.Holder"));
    }
}
