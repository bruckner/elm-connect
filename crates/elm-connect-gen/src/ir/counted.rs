//! Which messages a read counts as levels of nesting, and so whose codecs
//! take the depth (design §5.5): the messages that nest. A message nests
//! when, through its fields, map values and oneof members, at any depth, it
//! reaches a message on a cycle of references, a `google.protobuf.Value`,
//! `Struct` or `ListValue`, or an `Any`; a message on a cycle nests. Every
//! message that nests counts, the outermost read at 1.
//!
//! What nests is found as [`super::AnyReach`] finds what reaches an `Any`,
//! until nothing changes, over the graph of messages holding messages that
//! the cycle analysis and `nesting::longest` walk. It depends only on the
//! messages a message reaches, which are those of its own package and the
//! packages it imports, never on what holds it: a package generates the
//! same code whatever else the build holds. A message that does not nest
//! holds nothing a read could count, so its codecs are those it always had.

use std::collections::{BTreeSet, HashMap};

use super::{Message, Package, TypeRef, WellKnown};

/// The messages whose codecs take the nesting depth, and those of them on
/// a cycle, by full proto name.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Counted {
    nests: BTreeSet<String>,
    recursive: BTreeSet<String>,
}

impl Counted {
    /// The messages of `packages` that nest.
    pub fn of<'p>(packages: impl IntoIterator<Item = &'p Package>) -> Self {
        let messages: Vec<&Message> = packages
            .into_iter()
            .flat_map(|package| &package.messages)
            .collect();
        let by_name: HashMap<&str, &Message> = messages
            .iter()
            .map(|message| (message.proto_full_name.as_str(), *message))
            .collect();

        // A message on a cycle, or one holding a value that nests.
        let mut nests: BTreeSet<&str> = messages
            .iter()
            .filter(|message| message.recursive)
            .map(|message| message.proto_full_name.as_str())
            .collect();
        loop {
            let found: Vec<&str> = messages
                .iter()
                .map(|message| message.proto_full_name.as_str())
                .filter(|name| !nests.contains(name))
                .filter(|name| {
                    held(by_name[name]).any(|ty| match ty {
                        TypeRef::WellKnown(
                            WellKnown::Value
                            | WellKnown::Struct
                            | WellKnown::ListValue
                            | WellKnown::Any,
                        ) => true,
                        TypeRef::Message(target) => nests.contains(target.proto_full_name.as_str()),
                        _ => false,
                    })
                })
                .collect();
            if found.is_empty() {
                break;
            }
            nests.extend(found);
        }
        Counted {
            nests: nests.into_iter().map(str::to_owned).collect(),
            recursive: messages
                .iter()
                .filter(|message| message.recursive)
                .map(|message| message.proto_full_name.clone())
                .collect(),
        }
    }

    /// Whether the message `full_name` nests, so its codecs take the depth.
    pub fn message(&self, full_name: &str) -> bool {
        self.nests.contains(full_name)
    }

    /// Whether the message `full_name` is on a cycle of references.
    pub fn recursive(&self, full_name: &str) -> bool {
        self.recursive.contains(full_name)
    }

    /// Whether a value of `ty` is a message whose codecs take the depth.
    pub fn type_ref(&self, ty: &TypeRef) -> bool {
        match ty {
            TypeRef::Message(name) => self.message(&name.proto_full_name),
            _ => false,
        }
    }
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
        Annotations, Cardinality, Doc, Field, JsType, ModuleName, Oneof, OneofVariant, TypeName,
    };

    fn of(full_name: &str) -> TypeRef {
        let (package, name) = full_name.rsplit_once('.').unwrap();
        TypeRef::Message(TypeName {
            module: ModuleName::new(vec![package.to_uppercase()]).expect("valid"),
            name: name.into(),
            proto_full_name: full_name.into(),
        })
    }

    fn field(ty: TypeRef) -> Field {
        Field {
            proto_name: "f".into(),
            json_name: "f".into(),
            number: 1,
            elm_name: "f".into(),
            cardinality: Cardinality::Singular,
            ty,
            cyclic: false,
            recursive: false,
            jstype: JsType::Normal,
            unpacked: false,
            annotations: Annotations::default(),
            doc: Doc::default(),
        }
    }

    fn member(ty: TypeRef) -> Oneof {
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

    /// A message holding `held` in fields, and `oneof` in a oneof member;
    /// `recursive` as the cycle analysis would mark it.
    fn message(
        full_name: &str,
        recursive: bool,
        held: &[TypeRef],
        oneof: Option<TypeRef>,
    ) -> Message {
        Message {
            proto_full_name: full_name.into(),
            elm_name: full_name.rsplit('.').next().unwrap().into(),
            fields: held.iter().cloned().map(field).collect(),
            oneofs: oneof.into_iter().map(member).collect(),
            wrapper: None,
            recursive,
            doc: Doc::default(),
        }
    }

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

    const STRUCT: TypeRef = TypeRef::WellKnown(WellKnown::Struct);
    const TIMESTAMP: TypeRef = TypeRef::WellKnown(WellKnown::Timestamp);

    #[test]
    fn a_message_nests_when_it_reaches_a_cycle_a_struct_or_an_any() {
        let packages = [
            package(
                "A",
                vec![
                    // Node is on a cycle; it holds Wrap, Leaf and Bag, and
                    // through a oneof Choice.
                    message(
                        "a.Node",
                        true,
                        &[of("a.Node"), of("a.Wrap"), of("a.Leaf"), of("b.Bag")],
                        Some(of("a.Choice")),
                    ),
                    // Through Inner, Wrap reaches a Struct.
                    message("a.Wrap", false, &[of("a.Inner")], None),
                    message("a.Inner", false, &[STRUCT], None),
                    // Leaf reaches nothing that nests.
                    message("a.Leaf", false, &[TIMESTAMP], None),
                    message("a.Choice", false, &[], Some(of("c.Tree"))),
                    // Top holds a cycle, and nothing holds Top.
                    message("a.Top", false, &[of("a.Node")], None),
                    // Plain holds Leaf, which does not nest.
                    message("a.Plain", false, &[of("a.Leaf")], None),
                ],
            ),
            package(
                "B",
                vec![message(
                    "b.Bag",
                    false,
                    &[TypeRef::WellKnown(WellKnown::Any)],
                    None,
                )],
            ),
            package("C", vec![message("c.Tree", true, &[of("c.Tree")], None)]),
        ];
        let counted = Counted::of(&packages);
        let nests: Vec<bool> = [
            "a.Node", "a.Wrap", "a.Inner", "a.Leaf", "a.Choice", "a.Top", "a.Plain", "b.Bag",
            "c.Tree",
        ]
        .iter()
        .map(|name| counted.message(name))
        .collect();
        assert_eq!(
            nests,
            [true, true, true, false, true, true, false, true, true]
        );
        assert!(counted.type_ref(&of("a.Wrap")));
        assert!(!counted.type_ref(&of("a.Leaf")));
        assert!(!counted.type_ref(&STRUCT));
    }

    #[test]
    fn whether_a_message_nests_does_not_depend_on_what_holds_it() {
        let inner = || {
            package(
                "B",
                vec![
                    message("b.Meta", false, &[STRUCT], None),
                    message("b.Leaf", false, &[TIMESTAMP], None),
                ],
            )
        };
        let alone = Counted::of(&[inner()]);
        // A recursive message of another package holds both.
        let held = Counted::of(&[
            package(
                "A",
                vec![message(
                    "a.Node",
                    true,
                    &[of("a.Node"), of("b.Meta"), of("b.Leaf")],
                    None,
                )],
            ),
            inner(),
        ]);
        for name in ["b.Meta", "b.Leaf"] {
            assert_eq!(alone.message(name), held.message(name), "{name}");
        }
        assert!(alone.message("b.Meta") && !alone.message("b.Leaf"));
    }
}
