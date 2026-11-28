//! The codec names two types of a package can share although their type
//! names differ. A type's binary codecs are its JSON codecs' names with
//! `Bytes` at the end, and the JSON decoder of a message or oneof that
//! reaches a `google.protobuf.Any` takes the registry and has `With` at
//! the end, so a type named for another with that suffix can take one of
//! the other's codec names. Both checks read a package's namespace of
//! types once all of them are claimed.

use prost_reflect::{DescriptorPool, FileDescriptor, Kind};

use super::{Builder, Namespace};
use crate::diagnostics::{Problem, Site};
use crate::ir::{Enum, Message, TypeRef, WellKnown};
use crate::naming;

impl Builder {
    /// Reports each type of `package` named for another with `Bytes` at
    /// the end (`NoteBytes` beside `Note`) whose JSON codecs take the
    /// names of the other's binary codecs (`encodeNoteBytes`,
    /// `decodeNoteBytes`). A type's binary codecs are its JSON codecs'
    /// names with `Bytes` at the end, and only a message's merge starts
    /// with `merge`, which no JSON codec does, so these are the only
    /// generated values the binary codecs can meet.
    pub(super) fn check_codec_names(
        &mut self,
        package: &str,
        types: &Namespace,
        messages: &[Message],
        enums: &[Enum],
    ) {
        let mut names: Vec<&String> = types.claimed.keys().collect();
        names.sort();
        for name in names {
            let Some(stem) = name.strip_suffix("Bytes") else {
                continue;
            };
            let Some(first) = types.claimed.get(stem) else {
                continue;
            };
            let second = &types.claimed[name.as_str()];
            let is_enum = |elm: &str| enums.iter().any(|e| e.elm_name == elm);
            // A oneof's binary codec is an encoder alone.
            let decodes = is_enum(stem) || messages.iter().any(|m| m.elm_name == stem);
            let mut values = vec![naming::encoder_name(name)];
            if decodes {
                values.push(naming::decoder_name(name));
            }
            let listed = values
                .iter()
                .map(|value| format!("`{value}`"))
                .collect::<Vec<_>>()
                .join(" and ");
            let (codecs, verb, does) = if values.len() == 1 {
                ("codec", "becomes", "does")
            } else {
                ("codecs", "become", "do")
            };
            let first_site = Site {
                label: format!("the binary {codecs} of {} {verb} {listed}", first.what),
                ..first.site.clone()
            };
            let second_site = Site {
                label: format!("and so {does} the JSON {codecs} of {}", second.what),
                ..second.site.clone()
            };
            let renamed = [second, first]
                .into_iter()
                .find(|claim| {
                    claim
                        .given
                        .as_ref()
                        .is_some_and(|(given, _)| given == name || given == stem)
                })
                .and_then(|claim| Some((claim.proto.clone()?, claim.given.clone()?.0)));
            let values = if values.len() == 1 {
                format!("value {listed}")
            } else {
                format!("values {listed}")
            };
            self.diagnostics.push(Problem::codec_collision(
                package,
                &values,
                first_site,
                second_site,
                &self.rename_of(second.proto.as_deref().or(first.proto.as_deref())),
                self.renamed_by(renamed.as_ref()).as_deref(),
            ));
        }
    }

    /// Reports each type of `package` named for a message or oneof that
    /// reaches a `google.protobuf.Any` with `With` at the end (`NoteWith`
    /// beside `Note`): the JSON decoder of such a
    /// message or oneof takes the registry and is named with `With` at the
    /// end (`decodeNoteWith`), so the JSON decoder of the other takes that
    /// name.
    pub(super) fn check_registry_codec_names(
        &mut self,
        package: &str,
        types: &Namespace,
        messages: &[Message],
        files: &[FileDescriptor],
    ) {
        let Some(pool) = files.first().map(FileDescriptor::parent_pool) else {
            return;
        };
        let reaches = |ty: &TypeRef| match ty {
            TypeRef::WellKnown(WellKnown::Any) => true,
            TypeRef::Message(name) => {
                pool_reaches_any(pool, &name.proto_full_name, &mut Vec::new())
            }
            _ => false,
        };
        let mut names: Vec<&String> = types.claimed.keys().collect();
        names.sort();
        for name in names {
            let Some(stem) = name.strip_suffix(naming::WITH_SUFFIX) else {
                continue;
            };
            let Some(first) = types.claimed.get(stem) else {
                continue;
            };
            let message = messages.iter().find(|m| m.elm_name == stem);
            let oneof = messages
                .iter()
                .flat_map(|m| &m.oneofs)
                .find(|o| o.elm_type_name == stem);
            let reaching = match (message, oneof) {
                (Some(message), _) => {
                    message.fields.iter().any(|field| reaches(&field.ty))
                        || message
                            .oneofs
                            .iter()
                            .flat_map(|o| &o.variants)
                            .any(|variant| reaches(&variant.ty))
                }
                (None, Some(oneof)) => oneof.variants.iter().any(|variant| reaches(&variant.ty)),
                (None, None) => false,
            };
            if !reaching {
                continue;
            }
            let second = &types.claimed[name.as_str()];
            let listed = format!("`{}`", naming::with_registry(naming::decoder_name(stem)));
            let first_site = Site {
                label: format!(
                    "the JSON decoder of {} taking the registry becomes {listed}",
                    first.what
                ),
                ..first.site.clone()
            };
            let second_site = Site {
                label: format!("and so does the JSON decoder of {}", second.what),
                ..second.site.clone()
            };
            let renamed = [second, first]
                .into_iter()
                .find(|claim| {
                    claim
                        .given
                        .as_ref()
                        .is_some_and(|(given, _)| given == name || given == stem)
                })
                .and_then(|claim| Some((claim.proto.clone()?, claim.given.clone()?.0)));
            self.diagnostics.push(Problem::registry_codec_collision(
                package,
                &format!("value {listed}"),
                first_site,
                second_site,
                &self.rename_of(second.proto.as_deref().or(first.proto.as_deref())),
                self.renamed_by(renamed.as_ref()).as_deref(),
            ));
        }
    }
}

/// Whether the message `full_name` of `pool` holds a `google.protobuf.Any`, in
/// a field, a map value or a oneof member, or holds a message that does;
/// `seen` holds the messages on the way, so that a cycle ends.
fn pool_reaches_any(pool: &DescriptorPool, full_name: &str, seen: &mut Vec<String>) -> bool {
    if full_name == "google.protobuf.Any" {
        return true;
    }
    if seen.iter().any(|name| name == full_name) {
        return false;
    }
    seen.push(full_name.to_owned());
    let Some(message) = pool.get_message_by_name(full_name) else {
        return false;
    };
    message.fields().any(|field| {
        let kind = match field.kind() {
            Kind::Message(entry) if field.is_map() => entry.map_entry_value_field().kind(),
            kind => kind,
        };
        match kind {
            Kind::Message(held) => pool_reaches_any(pool, held.full_name(), seen),
            _ => false,
        }
    })
}
