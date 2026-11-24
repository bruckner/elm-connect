//! Which messages a read counts as levels of nesting, and so whose codecs
//! take the depth (design §5.5): the messages on a cycle of references,
//! across packages. A message on a cycle reads every message it holds whose
//! codecs take the depth one level deeper, whether on its own cycle or on
//! another.

use std::collections::BTreeSet;

use super::{Message, Package, TypeRef};

/// The messages whose codecs take the nesting depth, by full proto name.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Counted {
    recursive: BTreeSet<String>,
}

impl Counted {
    /// The counted messages of `packages`.
    pub fn of<'p>(packages: impl IntoIterator<Item = &'p Package>) -> Self {
        let recursive = packages
            .into_iter()
            .flat_map(|package| &package.messages)
            .filter(|message: &&Message| message.recursive)
            .map(|message| message.proto_full_name.clone())
            .collect();
        Counted { recursive }
    }

    /// Whether the codecs of the message `full_name` take the depth.
    pub fn message(&self, full_name: &str) -> bool {
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ir::{Doc, ModuleName, TypeName, WellKnown};

    fn message(full_name: &str, recursive: bool) -> Message {
        Message {
            proto_full_name: full_name.into(),
            elm_name: full_name.rsplit('.').next().unwrap().into(),
            fields: Vec::new(),
            oneofs: Vec::new(),
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

    #[test]
    fn the_messages_on_cycles_are_counted_across_packages() {
        let packages = [
            package("A", vec![message("a.Node", true), message("a.Leaf", false)]),
            package("B", vec![message("b.Tree", true)]),
        ];
        let counted = Counted::of(&packages);
        assert!(counted.message("a.Node") && counted.message("b.Tree"));
        assert!(!counted.message("a.Leaf"));
        let tree = TypeRef::Message(TypeName {
            module: ModuleName::new(vec!["B".into()]).expect("valid"),
            name: "Tree".into(),
            proto_full_name: "b.Tree".into(),
        });
        assert!(counted.type_ref(&tree));
        assert!(!counted.type_ref(&TypeRef::WellKnown(WellKnown::Struct)));
    }
}
