//! The documentation of generated declarations (design §3): what the
//! proto says about each element, on the declaration it becomes.
//!
//! The declaration an element becomes carries the proto's comment, then
//! the element's one-line declaration, and `Deprecated.` first when the
//! proto deprecates it: a message's record alias lists its fields, an
//! enum's custom type its constructors, a oneof's custom type its members,
//! each with its comment and, for a field, its behaviors in words. A
//! descriptor carries the comment and the declaration line alone, a
//! field's descriptor value the field's full line. Codecs, defaults and
//! typed values get one sentence naming their type. The text is Markdown, which the printer
//! puts in elm-format's form ([`crate::elm::markdown`]); each comment is
//! settled on its own first, so a construct it leaves open cannot take in
//! the text after it.

use std::fmt::Display;

use crate::elm::markdown;
use crate::ir::{Doc, Enum, FieldBehavior, HttpRule, Message, Method, Oneof, Service};
use crate::naming::RUNTIME_DOCS;

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

/// The page of `module` in the documentation the package site and
/// elm-doc-preview render, which a link names: `Notes-V1-Note` for
/// `Notes.V1.Note`.
pub(super) fn page(module: &impl Display) -> String {
    module.to_string().replace('.', "-")
}

/// A link with `text` as code to `target`, a page and an anchor
/// (`Notes-V1-Note#title`), an anchor of this page (`#Note`) or a URL.
pub(super) fn link(text: &str, target: &str) -> String {
    format!("[{}]({target})", code(text))
}

/// A link to the declaration `name` of the module being documented.
pub(super) fn local(name: &str) -> String {
    link(name, &format!("#{name}"))
}

/// A link to the declaration `name` of the runtime's module `module` on
/// the package site, an absolute URL, which an editor's hover makes
/// clickable where it does not follow a page link.
pub(super) fn runtime(module: &str, name: &str) -> String {
    link(
        &format!("{module}.{name}"),
        &format!("{RUNTIME_DOCS}{}#{name}", page(&module)),
    )
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
/// declaration linked to its descriptor in `descriptors`, its descriptor
/// module, then `items`, one per record field ([`field_item`],
/// [`oneof_item`]).
pub(super) fn message(message: &Message, descriptors: &str, items: Vec<String>) -> String {
    paragraphs(proto_part(&message.doc).into_iter().chain([
        link(&message.doc.declaration, &descriptor_target(descriptors)),
        list(items),
    ]))
}

/// The target of a link to the `descriptor` of the descriptor module
/// whose page is `descriptors`.
fn descriptor_target(descriptors: &str) -> String {
    format!("{descriptors}#{}", crate::naming::DESCRIPTOR_VALUE)
}

/// The item of a record field: its Elm name linked to `target`, its
/// descriptor value, then `Deprecated.`, its comment and its behaviors as
/// words (`Required.`); the name alone when there is nothing else. The
/// field's declaration is on its descriptor value.
pub(super) fn field_item(
    elm_name: &str,
    target: &str,
    doc: &Doc,
    behavior: &[FieldBehavior],
) -> String {
    let words = behavior_words(behavior);
    named_item(
        &link(elm_name, target),
        with_sentence(item_rest(doc), &words),
    )
}

/// The item of a oneof in its message's record: its Elm field name, its
/// comment, and the name of its custom type.
pub(super) fn oneof_item(oneof: &Oneof) -> String {
    let pointer = format!("See {}.", local(&oneof.elm_type_name));
    named_item(
        &code(&oneof.elm_field_name),
        with_sentence(item_rest(&oneof.doc), &pointer),
    )
}

/// An item of `head` followed by a colon and `rest`, or `head` alone
/// when `rest` is empty.
fn named_item(head: &str, rest: Vec<String>) -> String {
    if rest.is_empty() {
        item(head, &[])
    } else {
        item(&format!("{head}:"), &rest)
    }
}

/// `parts` followed by `sentence`: on the same line when `parts` is one
/// paragraph, as a paragraph of its own when it has several blocks, alone
/// when it is empty. Nothing is added for an empty `sentence`.
fn with_sentence(mut parts: Vec<String>, sentence: &str) -> Vec<String> {
    if sentence.is_empty() {
        return parts;
    }
    match parts.as_mut_slice() {
        [] => parts.push(sentence.to_owned()),
        [only] if is_one_paragraph(only) => {
            only.push(' ');
            only.push_str(sentence);
        }
        _ => parts.push(sentence.to_owned()),
    }
    parts
}

/// Whether `blocks`, in elm-format's form, is a single paragraph.
fn is_one_paragraph(blocks: &str) -> bool {
    markdown::starts_with_paragraph(blocks) && !blocks.contains("\n\n")
}

/// A field's `google.api.field_behavior` values as words, in the proto's
/// order: `Required. Output only.` `OPTIONAL` says nothing a reader
/// needs, and `NON_EMPTY_DEFAULT` concerns the server's defaults, so
/// neither is written.
fn behavior_words(behavior: &[FieldBehavior]) -> String {
    behavior
        .iter()
        .filter_map(|behavior| match behavior {
            FieldBehavior::Required => Some("Required."),
            FieldBehavior::OutputOnly => Some("Output only."),
            FieldBehavior::InputOnly => Some("Input only."),
            FieldBehavior::Immutable => Some("Immutable."),
            FieldBehavior::Identifier => Some("Identifier."),
            FieldBehavior::UnorderedList => Some("Unordered."),
            FieldBehavior::Optional | FieldBehavior::NonEmptyDefault => None,
        })
        .collect::<Vec<_>>()
        .join(" ")
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

/// The doc of an enum's custom type: the proto's part, its declaration
/// linked to its descriptor in `descriptors`, its descriptor module, then
/// an item per constructor: the constructor, the proto name of its
/// value and of each alias, the value's comment, and `Deprecated.` when
/// the value is. The number and each alias's own comment are on the
/// enum's descriptor.
pub(super) fn enumeration(enumeration: &Enum, descriptors: &str) -> String {
    let items = enumeration
        .values()
        .map(|value| {
            let names = std::iter::once(code(&value.proto_name))
                .chain(
                    value
                        .aliases
                        .iter()
                        .map(|alias| format!("also {}", code(alias))),
                )
                .collect::<Vec<_>>()
                .join(", ");
            let head = format!("{} ({names})", code(&value.elm_ctor));
            let doc = enumeration.value_doc(&value.proto_name);
            let rest = doc.and_then(item_comment).into_iter().collect();
            let deprecated = doc.is_some_and(|doc| doc.deprecated);
            named_item(
                &head,
                with_sentence(rest, if deprecated { "Deprecated." } else { "" }),
            )
        })
        .collect();
    paragraphs(proto_part(&enumeration.doc).into_iter().chain([
        link(
            &enumeration.doc.declaration,
            &descriptor_target(descriptors),
        ),
        list(items),
    ]))
}

/// The doc of a oneof's custom type: the proto's part, its declaration
/// with its message's name, then an item for the unset constructor and
/// one per member, shaped as a record field's ([`field_item`]) and linked
/// to the member's value in `descriptors`, its message's descriptor
/// module.
pub(super) fn oneof(message: &str, oneof: &Oneof, descriptors: &str) -> String {
    let unset = item(
        &format!("{}: none of the fields is set.", code(&oneof.unset_ctor)),
        &[],
    );
    let members = oneof.variants.iter().map(|variant| {
        field_item(
            &variant.elm_ctor,
            &format!("{descriptors}#{}", variant.elm_name),
            &variant.doc,
            &variant.annotations.behavior,
        )
    });
    paragraphs(proto_part(&oneof.doc).into_iter().chain([
        format!("{} of {}", code(&oneof.doc.declaration), code(message)),
        list(std::iter::once(unset).chain(members).collect()),
    ]))
}

/// The doc of a message's `descriptor` or a method's: the proto's part,
/// then the declaration, then `described`, a link to the type it
/// describes, if any.
pub(super) fn descriptor(doc: &Doc, described: Option<String>) -> String {
    paragraphs(
        proto_part(doc)
            .into_iter()
            .chain([code(&doc.declaration)])
            .chain(described.map(|link| format!("Describes {link}."))),
    )
}

/// The doc of a field's descriptor value: the proto's part, then the
/// field's declaration and the oneof it is a member of, if any.
pub(super) fn field_descriptor(doc: &Doc, oneof: Option<&str>) -> String {
    let line = match oneof {
        Some(oneof) => format!("{}, in oneof {}", code(&doc.declaration), code(oneof)),
        None => code(&doc.declaration),
    };
    paragraphs(proto_part(doc).into_iter().chain([line]))
}

/// The doc of an enum's `descriptor`: the proto's part, the declaration
/// and `described`, a link to the enum's type, then an item per declared
/// value name, aliases included.
pub(super) fn enum_descriptor(enumeration: &Enum, described: &str) -> String {
    let items = enumeration
        .declared()
        .filter_map(|(name, _)| enumeration.value_doc(name))
        .map(|doc| item(&code(&doc.declaration), &item_rest(doc)))
        .collect();
    paragraphs(proto_part(&enumeration.doc).into_iter().chain([
        code(&enumeration.doc.declaration),
        format!("Describes {described}."),
        list(items),
    ]))
}

/// The doc of a method's call: the proto's part, then its declaration,
/// its Connect path and its HTTP bindings as its rule writes them, and
/// its `request` and `response` types and its descriptor, as links.
pub(super) fn method(service: &str, method: &Method, request: &str, response: &str) -> String {
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
        None => "Transcode: no HTTP rule, follows the Connect path.".to_owned(),
    };
    let head = format!(
        "{}.\nConnect: {}.\n{routes}\nFrom {request} to {response}, described by {}.",
        code(&method.doc.declaration),
        code(&format!("POST /{service}/{}", method.proto_name)),
        local(&method.descriptor_name()),
    );
    paragraphs(proto_part(&method.doc).into_iter().chain([head]))
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
    fn links_name_a_page_with_dashes_and_the_runtime_by_url() {
        assert_eq!(page(&"Notes.V1.Note"), "Notes-V1-Note");
        assert_eq!(local("Note_"), "[`Note_`](#Note_)");
        assert_eq!(
            runtime("Proto.Message", "Descriptor"),
            "[`Proto.Message.Descriptor`](https://package.elm-lang.org/packages/\
             bruckner/elm-connect/latest/Proto-Message#Descriptor)"
        );
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

    #[test]
    fn field_items_give_the_comment_then_the_behaviors() {
        use FieldBehavior::*;
        let doc = |comment: Option<&str>, deprecated| Doc {
            comment: comment.map(str::to_owned),
            declaration: "string a = 1;".into(),
            deprecated,
        };
        assert_eq!(
            field_item("a", "M#a", &doc(None, false), &[]),
            "  - [`a`](M#a)"
        );
        assert_eq!(
            field_item(
                "a",
                "M#a",
                &doc(Some("The a."), false),
                &[Required, Optional]
            ),
            "  - [`a`](M#a): The a. Required."
        );
        assert_eq!(
            field_item("a", "M#a", &doc(None, true), &[OutputOnly, UnorderedList]),
            "  - [`a`](M#a): Deprecated. Output only. Unordered."
        );
        assert_eq!(
            field_item("a", "M#a", &doc(Some("One.\n\nTwo."), false), &[Immutable]),
            "  - [`a`](M#a): One.\n\n    Two.\n\n    Immutable."
        );
        assert_eq!(
            behavior_words(&[NonEmptyDefault, Identifier, InputOnly]),
            "Identifier. Input only."
        );
    }
}
