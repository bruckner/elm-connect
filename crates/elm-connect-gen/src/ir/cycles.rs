//! Marking the cycles of message references once every package is built
//! (the [`super`] invariants): the cycles of record fields, which an Elm
//! type alias cannot express and so need a wrapper (design §3.2), and the
//! cycles of all references, whose decoders would define each other and
//! whose reads nest without bound (design §5.5). A cycle belongs to the
//! graph of messages, not to one message, so this runs over the built
//! packages, beside the other analyses of that graph.

use std::collections::HashMap;

use super::graph::strongly_connected;
use super::{Package, TypeRef, Wrapper};
use crate::naming;

/// Marks every cycle of message references (see the [`super`] invariants):
/// [`Field::cyclic`] and [`Message::wrapper`] from the cycles of record
/// fields, [`OneofVariant::cyclic`], [`Message::recursive`] and
/// [`Field::recursive`] from the cycles of all references.
pub(super) fn mark_cycles(packages: &mut [Package]) {
    let mut index = HashMap::new();
    for package in packages.iter() {
        for message in &package.messages {
            let key = (package.module.clone(), message.elm_name.clone());
            let next = index.len();
            index.entry(key).or_insert(next);
        }
    }
    let target = |ty: &TypeRef| match ty {
        TypeRef::Message(name) => index
            .get(&(name.module.clone(), name.name.clone()))
            .copied(),
        _ => None,
    };
    let mut fields = vec![Vec::new(); index.len()];
    let mut all = vec![Vec::new(); index.len()];
    for package in packages.iter() {
        for message in &package.messages {
            let from = index[&(package.module.clone(), message.elm_name.clone())];
            for to in message.fields.iter().filter_map(|field| target(&field.ty)) {
                fields[from].push(to);
                all[from].push(to);
            }
            let members = message.oneofs.iter().flat_map(|oneof| &oneof.variants);
            all[from].extend(members.filter_map(|variant| target(&variant.ty)));
        }
    }
    let field_cycle = cycles(&fields);
    let any_cycle = cycles(&all);
    let closes = |cycle: &[Option<usize>], from: usize, to: Option<usize>| {
        to.is_some_and(|to| cycle[from].is_some() && cycle[from] == cycle[to])
    };
    for package in packages.iter_mut() {
        let module = package.module.clone();
        for message in &mut package.messages {
            let from = index[&(module.clone(), message.elm_name.clone())];
            if field_cycle[from].is_some() {
                message.wrapper = Some(Wrapper {
                    elm_name: naming::recursive_wrapper(&message.elm_name),
                });
            }
            message.recursive = any_cycle[from].is_some();
            for field in &mut message.fields {
                field.cyclic = closes(&field_cycle, from, target(&field.ty));
                field.recursive = closes(&any_cycle, from, target(&field.ty));
            }
            for variant in message
                .oneofs
                .iter_mut()
                .flat_map(|oneof| &mut oneof.variants)
            {
                variant.cyclic = closes(&any_cycle, from, target(&variant.ty));
            }
        }
    }
}

/// For each node of the graph, the strongly-connected component it shares
/// with a cycle, if it is on one: a component of several nodes, or one
/// node with an edge to itself.
fn cycles(edges: &[Vec<usize>]) -> Vec<Option<usize>> {
    let mut cycle = vec![None; edges.len()];
    for (id, component) in strongly_connected(edges).into_iter().enumerate() {
        let looped = component.len() > 1 || edges[component[0]].contains(&component[0]);
        if looped {
            for node in component {
                cycle[node] = Some(id);
            }
        }
    }
    cycle
}
