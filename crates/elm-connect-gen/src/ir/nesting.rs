//! The longest chain of nested messages a schema allows. A read counts the
//! nesting of the messages on a cycle of references alone (design §5.5),
//! so a chain off every cycle is read to its end however long it is; the
//! generator measures it here and warns past the runtime's limit.

use std::collections::HashMap;

use super::graph::strongly_connected;
use super::{Package, TypeRef};

/// Protobuf's nesting limit, the generator's one definition of it: the
/// most levels a read nests, as the runtime limits them
/// (`Proto.Internal.Depth.limit`, held to this by `tests/lockstep.rs`) and
/// as protobuf's own parsers do
/// (<https://protobuf.dev/programming-guides/proto-limits/>). Its users
/// count from different starting points: the `types::deep_nesting`
/// warning counts messages the outermost at 1, the runtime's unit, and
/// warns past `LIMIT`; the route checker (`crate::route`) counts messages
/// below the request, and refuses past `LIMIT` of them, so at
/// `LIMIT + 2` counted the runtime's way. The places that write the
/// number out are listed in design §5.5.
pub const LIMIT: usize = 100;

/// A longest chain of messages, each held by the one before it through a
/// field (singular, repeated or a map's values) or a oneof member.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Chain {
    /// The messages' full names, the outermost first. The members of a
    /// cycle of references count once each, in declaration order, since
    /// a cycle has no longest chain of its own.
    pub messages: Vec<String>,
    /// The first message along the chain that is on a cycle, if any: the
    /// chain is longer still through it, and the runtime counts it.
    pub recursive: Option<String>,
}

/// The longest chain starting from any message of `packages`, the
/// first-declared message's on a tie; `None` when they hold no message.
/// Well-known types end a chain: an `Any`'s message is not in the schema,
/// and a `Struct`, `Value` or `ListValue` is limited by itself.
pub(crate) fn longest(packages: &[Package]) -> Option<Chain> {
    let mut index = HashMap::new();
    let mut names = Vec::new();
    for package in packages {
        for message in &package.messages {
            index.insert((&package.module, message.elm_name.as_str()), names.len());
            names.push(message.proto_full_name.as_str());
        }
    }
    let target = |ty: &TypeRef| match ty {
        TypeRef::Message(name) => index.get(&(&name.module, name.name.as_str())).copied(),
        _ => None,
    };
    let mut edges = vec![Vec::new(); names.len()];
    for package in packages {
        for message in &package.messages {
            let from = index[&(&package.module, message.elm_name.as_str())];
            let fields = message.fields.iter().map(|field| &field.ty);
            let members = message
                .oneofs
                .iter()
                .flat_map(|oneof| &oneof.variants)
                .map(|variant| &variant.ty);
            edges[from].extend(fields.chain(members).filter_map(target));
        }
    }

    // Components come sinks first, so each one's successors are measured
    // before it is.
    let components = strongly_connected(&edges);
    let mut component_of = vec![0; names.len()];
    for (id, component) in components.iter().enumerate() {
        for &node in component {
            component_of[node] = id;
        }
    }
    let mut length = vec![0; components.len()];
    let mut next = vec![None; components.len()];
    for (id, component) in components.iter().enumerate() {
        let mut best = 0;
        for &node in component {
            for &to in &edges[node] {
                let other = component_of[to];
                if other != id && length[other] > best {
                    best = length[other];
                    next[id] = Some(other);
                }
            }
        }
        length[id] = component.len() + best;
    }

    let start = (0..names.len()).fold(None, |best: Option<usize>, node| match best {
        Some(b) if length[component_of[node]] <= length[component_of[b]] => best,
        _ => Some(node),
    })?;
    let mut messages = Vec::new();
    let mut recursive = None;
    let mut at = Some(component_of[start]);
    while let Some(id) = at {
        let component = &components[id];
        let looped = component.len() > 1 || edges[component[0]].contains(&component[0]);
        if looped && recursive.is_none() {
            recursive = Some(names[component[0]].to_owned());
        }
        messages.extend(component.iter().map(|&node| names[node].to_owned()));
        at = next[id];
    }
    Some(Chain {
        messages,
        recursive,
    })
}
