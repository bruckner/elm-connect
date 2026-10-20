//! The documentation of generated declarations (design §3): what the
//! proto says about each element, on the declaration it becomes.
//!
//! The declaration an element becomes carries the proto's comment and the
//! element's one-line declaration, and `Deprecated.` first when the proto
//! deprecates it: a message's record alias lists its fields, an enum's
//! custom type its constructors, a oneof's custom type its members, each
//! with its own declaration line and comment. Descriptors keep their
//! sentence and add the same. Codecs, defaults and typed values get one
//! sentence naming their type. The text is Markdown, which the printer
//! puts in elm-format's form ([`crate::elm::markdown`]); each comment is
//! settled on its own first, so a construct it leaves open cannot take in
//! the text after it.

use crate::elm::markdown;
use crate::ir::{Doc, Enum, HttpRule, Message, Method, Oneof, Service};

/// `text` as a Markdown code span.
pub(super) fn code(text: &str) -> String {
    let longest = text
        .split(|c| c != '`')
        .map(str::len)
        .max()
        .unwrap_or_default();
    if longest == 0 {
        format!("`{text}`")
    } else {
        let ticks = "`".repeat(longest + 1);
        format!("{ticks} {text} {ticks}")
    }
}

/// The proto comment of `doc` as Markdown blocks, if it has one.
fn comment(doc: &Doc) -> Option<String> {
    doc.comment
        .as_deref()
        .map(markdown::blocks)
        .filter(|blocks| !blocks.is_empty())
}

/// [`comment`] for a list item, its headings strong text
/// ([`markdown::item_blocks`]).
fn item_comment(doc: &Doc) -> Option<String> {
    doc.comment
        .as_deref()
        .map(markdown::item_blocks)
        .filter(|blocks| !blocks.is_empty())
}

/// `Deprecated.` when `doc` says so, then its comment: the proto's part of
/// a doc comment, as paragraphs.
fn proto_part(doc: &Doc) -> Vec<String> {
    doc.deprecated
        .then(|| "Deprecated.".to_owned())
        .into_iter()
        .chain(comment(doc))
        .collect()
}

/// Paragraphs joined into one doc comment.
fn paragraphs(parts: impl IntoIterator<Item = String>) -> String {
    parts
        .into_iter()
        .filter(|part| !part.is_empty())
        .collect::<Vec<_>>()
        .join("\n\n")
}

/// One item of a Markdown list: `head`, then each of `rest`, the first on
/// the head's line when it begins with a paragraph, the others as blocks
/// of the item.
fn item(head: &str, rest: &[String]) -> String {
    let mut text = head.to_owned();
    for (index, part) in rest.iter().enumerate() {
        if index == 0 && markdown::starts_with_paragraph(part) {
            text.push(' ');
        } else {
            text.push_str("\n\n");
        }
        text.push_str(part);
    }
    let mut out = String::new();
    for (index, line) in text.lines().enumerate() {
        if index == 0 {
            out.push_str("  - ");
        } else {
            out.push('\n');
            if !line.is_empty() {
                out.push_str("    ");
            }
        }
        out.push_str(line);
    }
    out
}

/// A list of `items`, or nothing for none: a blank line between them when
/// one has several blocks, which makes the list loose as elm-format prints
/// it, and ends a link reference definition at an item's end before the
/// next item, which Cheapskate would otherwise nest in the item.
fn list(items: Vec<String>) -> String {
    let loose = items.iter().any(|item| item.contains("\n\n"));
    items.join(if loose { "\n\n" } else { "\n" })
}

/// The doc of a message's record alias: the proto's part, its
/// declaration, then an item per record field (`fields`, each a head and
/// the field's doc).
pub(super) fn message(message: &Message, fields: &[(String, &Doc)]) -> String {
    let items = fields
        .iter()
        .map(|(head, doc)| item(head, &item_rest(doc)))
        .collect();
    paragraphs(
        proto_part(&message.doc)
            .into_iter()
            .chain([code(&message.doc.declaration), list(items)]),
    )
}

/// The head of a record field's item: `` `name`: `string name = 1;` ``.
pub(super) fn field_head(elm_name: &str, doc: &Doc) -> String {
    format!("{}: {}", code(elm_name), code(&doc.declaration))
}

/// The head of a oneof's item in its message's record:
/// `` `kind`: `oneof kind` (`NoteEventKind`) ``.
pub(super) fn oneof_head(oneof: &Oneof) -> String {
    format!(
        "{}: {} ({})",
        code(&oneof.elm_field_name),
        code(&oneof.doc.declaration),
        code(&oneof.elm_type_name)
    )
}

/// An item's text after its head: `Deprecated.` and the comment, as one
/// paragraph where the comment starts with one, so a list of items with
/// one-paragraph comments stays tight.
fn item_rest(doc: &Doc) -> Vec<String> {
    match (doc.deprecated, item_comment(doc)) {
        (false, comment) => comment.into_iter().collect(),
        (true, None) => vec!["Deprecated.".to_owned()],
        (true, Some(comment)) if markdown::starts_with_paragraph(&comment) => {
            vec![format!("Deprecated. {comment}")]
        }
        (true, Some(comment)) => vec!["Deprecated.".to_owned(), comment],
    }
}

/// The doc of an enum's custom type: the proto's part, its declaration,
/// then an item per constructor with the declaration and comment of the
/// value it is named for, then those of the value's aliases.
pub(super) fn enumeration(enumeration: &Enum) -> String {
    let items = enumeration
        .values()
        .map(|value| {
            let doc = enumeration.value_doc(&value.proto_name);
            let line = doc.map_or_else(String::new, |doc| doc.declaration.clone());
            let head = format!("{}: {}", code(&value.elm_ctor), code(&line));
            let mut rest = doc.map(item_rest).unwrap_or_default();
            for alias in &value.aliases {
                if let Some(doc) = enumeration.value_doc(alias) {
                    rest.push(paragraphs(
                        std::iter::once(format!("Also {}.", code(&doc.declaration)))
                            .chain(item_rest(doc)),
                    ));
                }
            }
            item(&head, &rest)
        })
        .collect();
    paragraphs(
        proto_part(&enumeration.doc)
            .into_iter()
            .chain([code(&enumeration.doc.declaration), list(items)]),
    )
}

/// The doc of a oneof's custom type: the proto's part, its declaration
/// with its message's name, then an item for the unset constructor and
/// one per member.
pub(super) fn oneof(message: &str, oneof: &Oneof) -> String {
    let unset = item(
        &format!("{}: none of the fields is set.", code(&oneof.unset_ctor)),
        &[],
    );
    let members = oneof.variants.iter().map(|variant| {
        let head = format!(
            "{}: {}",
            code(&variant.elm_ctor),
            code(&variant.doc.declaration)
        );
        item(&head, &item_rest(&variant.doc))
    });
    paragraphs(proto_part(&oneof.doc).into_iter().chain([
        format!("{} of {}", code(&oneof.doc.declaration), code(message)),
        list(std::iter::once(unset).chain(members).collect()),
    ]))
}

/// The doc of a message's `descriptor`: `sentence`, then the proto's part
/// and the declaration.
pub(super) fn descriptor(sentence: String, doc: &Doc) -> String {
    paragraphs(
        std::iter::once(sentence)
            .chain(proto_part(doc))
            .chain([code(&doc.declaration)]),
    )
}

/// The doc of a field's descriptor value: `sentence` ending in the field's
/// declaration, then the proto's part.
pub(super) fn field_descriptor(sentence: &str, doc: &Doc) -> String {
    paragraphs(
        std::iter::once(format!("{sentence}: {}", code(&doc.declaration))).chain(proto_part(doc)),
    )
}

/// The doc of an enum's `descriptor`: `sentence`, the proto's part and the
/// declaration, then an item per declared value name, aliases included.
pub(super) fn enum_descriptor(sentence: String, enumeration: &Enum) -> String {
    let items = enumeration
        .declared()
        .filter_map(|(name, _)| enumeration.value_doc(name))
        .map(|doc| item(&code(&doc.declaration), &item_rest(doc)))
        .collect();
    paragraphs(
        std::iter::once(sentence)
            .chain(proto_part(&enumeration.doc))
            .chain([code(&enumeration.doc.declaration), list(items)]),
    )
}

/// The doc of a method's call: `Deprecated.` when it is, then its
/// declaration, its Connect path and its HTTP bindings as its rule writes
/// them, then its comment.
pub(super) fn method(service: &str, method: &Method) -> String {
    let routes = match &method.http {
        Some(rule) => {
            let bindings = std::iter::once(rule)
                .chain(&rule.additional_bindings)
                .enumerate()
                .map(|(index, rule)| match index {
                    0 => binding(rule),
                    n => format!("binding {n}: {}", binding(rule)),
                })
                .collect::<Vec<_>>();
            format!("Transcode: {}.", bindings.join("; "))
        }
        None => "No HTTP rule: the Connect path.".to_owned(),
    };
    let head = format!(
        "{}. Connect: {}.\n{routes}",
        code(&method.doc.declaration),
        code(&format!("POST /{service}/{}", method.proto_name)),
    );
    let deprecated = method.doc.deprecated.then(|| "Deprecated.".to_owned());
    paragraphs(
        deprecated
            .into_iter()
            .chain([head])
            .chain(comment(&method.doc)),
    )
}

/// One binding of an HTTP rule: `` `GET /v1/{name=notes/*}` ``, then its
/// `body` and `response_body` where it sets them.
fn binding(rule: &HttpRule) -> String {
    let mut text = code(&format!("{} {}", rule.verb.as_str(), rule.template));
    if !rule.body.is_empty() {
        text.push_str(&format!(" body {}", code(&rule.body)));
    }
    if !rule.response_body.is_empty() {
        text.push_str(&format!(" response body {}", code(&rule.response_body)));
    }
    text
}

/// The doc of a service's module: the proto's part and the service's
/// declaration.
pub(super) fn service(service: &Service) -> String {
    paragraphs(
        proto_part(&service.doc)
            .into_iter()
            .chain([code(&service.doc.declaration)]),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn code_spans_take_more_backticks_than_they_hold() {
        assert_eq!(code("a"), "`a`");
        assert_eq!(code("a`b"), "`` a`b ``");
        assert_eq!(code("``"), "``` `` ```");
    }

    #[test]
    fn bindings_read_as_their_rule_writes_them() {
        use crate::ir::HttpVerb;
        let rule = |verb, template: &str, body: &str, response_body: &str| HttpRule {
            verb,
            template: template.into(),
            body: body.into(),
            response_body: response_body.into(),
            additional_bindings: Vec::new(),
        };
        assert_eq!(
            binding(&rule(HttpVerb::Get, "/v1/{name=notes/*}", "", "")),
            "`GET /v1/{name=notes/*}`"
        );
        assert_eq!(
            binding(&rule(HttpVerb::Post, "/v1/notes:batch", "*", "notes")),
            "`POST /v1/notes:batch` body `*` response body `notes`"
        );
        assert_eq!(
            binding(&rule(HttpVerb::Custom("PURGE".into()), "/v1/x", "", "")),
            "`PURGE /v1/x`"
        );
    }

    #[test]
    fn items_put_a_paragraph_on_the_head_line_and_indent_the_rest() {
        assert_eq!(
            item("`a`: `int32 a = 1;`", &["One.\nTwo.\n\nThree.".to_owned()]),
            "  - `a`: `int32 a = 1;` One.\n    Two.\n\n    Three."
        );
        assert_eq!(
            item("`a`", &["  - x\n  - y".to_owned()]),
            "  - `a`\n\n      - x\n      - y"
        );
        assert_eq!(item("`a`", &[]), "  - `a`");
    }
}
