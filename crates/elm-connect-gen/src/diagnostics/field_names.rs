//! The descriptor library's refusal of two fields of one message whose
//! names are the same once lowercased without underscores (`aB` and
//! `ab`), which protoc accepts. prost-reflect reports it as a
//! `DescriptorError` whose kind it does not expose, so both front ends
//! recognise it by its text and find the message in the file themselves,
//! to report it as `input::field_name_conflict`.

use prost_types::{DescriptorProto, FileDescriptorProto};

use super::Site;
use super::spans::{Spans, tag};

/// The text prost-reflect gives the refusal, around the two field names.
const PREFIX: &str = "camel-case name of field '";
const MIDDLE: &str = "' conflicts with field '";
const SUFFIX: &str = "'";

/// The two field names of the refusal's text (`camel-case name of field
/// 'aB' conflicts with field 'ab'`), the first declared first, or `None`
/// for any other text.
pub fn field_name_conflict_names(text: &str) -> Option<(&str, &str)> {
    let rest = text.strip_prefix(PREFIX)?;
    let (first, rest) = rest.split_once(MIDDLE)?;
    let second = rest.strip_suffix(SUFFIX)?;
    Some((first, second))
}

/// A message of a file with a field of each of two names.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FieldNameConflict {
    /// The message's full name.
    pub message: String,
    /// The descriptor path of the second field's name, where
    /// prost-reflect's error points.
    pub path: Vec<i32>,
    /// The first field's name and the second's, labelled.
    pub sites: Vec<Site>,
}

/// Every message of `file`, nested ones included and in declaration
/// order, with a field named `first` and a field named `second`: where
/// the refusal of the two can be.
pub fn field_name_conflicts(
    file: &FileDescriptorProto,
    first: &str,
    second: &str,
) -> Vec<FieldNameConflict> {
    let spans = Spans::new(file);
    let mut found = Vec::new();
    let mut pending: Vec<(String, Vec<i32>, &DescriptorProto)> = file
        .message_type
        .iter()
        .enumerate()
        .map(|(index, message)| {
            let path = vec![tag::FILE_MESSAGE, index_tag(index)];
            (qualify(file.package(), message.name()), path, message)
        })
        .collect();
    pending.reverse();
    while let Some((name, path, message)) = pending.pop() {
        let index = |wanted: &str| message.field.iter().position(|f| f.name() == wanted);
        if let (Some(i), Some(j)) = (index(first), index(second)) {
            let name_path = |k: usize| {
                [
                    &path[..],
                    &[tag::MESSAGE_FIELD, index_tag(k), tag::FIELD_NAME],
                ]
                .concat()
            };
            let site = |path: &[i32], label: String| Site {
                file: file.name().to_owned(),
                span: spans.get(path),
                label,
                within: Vec::new(),
            };
            found.push(FieldNameConflict {
                message: name.clone(),
                path: name_path(j),
                sites: vec![
                    site(&name_path(i), format!("field `{first}`")),
                    site(&name_path(j), format!("and field `{second}`")),
                ],
            });
        }
        let nested = message.nested_type.iter().enumerate().rev();
        for (index, inner) in nested {
            let inner_path = [&path[..], &[tag::MESSAGE_NESTED, index_tag(index)]].concat();
            pending.push((qualify(&name, inner.name()), inner_path, inner));
        }
    }
    found
}

fn qualify(scope: &str, name: &str) -> String {
    if scope.is_empty() {
        name.to_owned()
    } else {
        format!("{scope}.{name}")
    }
}

fn index_tag(index: usize) -> i32 {
    i32::try_from(index).unwrap_or(i32::MAX)
}

#[cfg(test)]
mod tests {
    use super::*;
    use prost_types::FieldDescriptorProto;

    fn message(name: &str, fields: &[&str], nested: Vec<DescriptorProto>) -> DescriptorProto {
        DescriptorProto {
            name: Some(name.into()),
            field: fields
                .iter()
                .map(|field| FieldDescriptorProto {
                    name: Some((*field).into()),
                    ..FieldDescriptorProto::default()
                })
                .collect(),
            nested_type: nested,
            ..DescriptorProto::default()
        }
    }

    #[test]
    fn reads_the_two_names_from_the_text_alone() {
        assert_eq!(
            field_name_conflict_names("camel-case name of field 'aB' conflicts with field 'ab'"),
            Some(("aB", "ab"))
        );
        assert_eq!(
            field_name_conflict_names("name 'p.v1.M' is defined twice"),
            None
        );
    }

    /// The front ends recognise the refusal by prost-reflect's text alone,
    /// since it exposes no kind: a release that rewords it must fail here,
    /// not quietly turn `input::field_name_conflict` back into its own
    /// uncoded message.
    #[test]
    fn prost_reflect_still_words_the_refusal_so() {
        let mut file = FileDescriptorProto {
            name: Some("p.proto".into()),
            package: Some("p.v1".into()),
            syntax: Some("proto3".into()),
            message_type: vec![message("M", &["aB", "ab"], Vec::new())],
            ..FileDescriptorProto::default()
        };
        for (number, field) in file.message_type[0].field.iter_mut().enumerate() {
            field.number = Some(i32::try_from(number).expect("small") + 1);
            field.r#type = Some(prost_types::field_descriptor_proto::Type::String.into());
            field.label = Some(prost_types::field_descriptor_proto::Label::Optional.into());
        }
        let error = prost_reflect::DescriptorPool::from_file_descriptor_set(
            prost_types::FileDescriptorSet { file: vec![file] },
        )
        .expect_err("prost-reflect refuses the two fields");
        assert_eq!(
            field_name_conflict_names(&error.to_string()),
            Some(("aB", "ab")),
            "{error}"
        );
        assert_eq!(error.path(), Some(&[4, 0, 2, 1, 1][..]));
    }

    #[test]
    fn finds_each_message_with_both_fields_nested_ones_included() {
        let file = FileDescriptorProto {
            name: Some("p.proto".into()),
            package: Some("p.v1".into()),
            message_type: vec![
                message("A", &["ID"], Vec::new()),
                message(
                    "B",
                    &["x", "ID", "id"],
                    vec![message("C", &["id", "ID"], Vec::new())],
                ),
            ],
            ..FileDescriptorProto::default()
        };
        let found = field_name_conflicts(&file, "ID", "id");
        let messages: Vec<(&str, &[i32])> = found
            .iter()
            .map(|conflict| (conflict.message.as_str(), conflict.path.as_slice()))
            .collect();
        assert_eq!(
            messages,
            [
                ("p.v1.B", &[4, 1, 2, 2, 1][..]),
                ("p.v1.B.C", &[4, 1, 3, 0, 2, 0, 1][..])
            ]
        );
        assert_eq!(found[0].sites[0].label, "field `ID`");
        assert_eq!(found[0].sites[1].span, None);
    }
}
