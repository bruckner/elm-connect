//! What the IR carries for documentation: each element's comment, its
//! one-line declaration and its deprecation.

use elm_connect_gen::ir::{Doc, Package, declaration};

use crate::common::{package, pool};

const NOTES: &str = r#"syntax = "proto3";

// The notes API.
package notes.v1;

import "google/api/annotations.proto";
import "google/api/field_behavior.proto";
import "google/protobuf/empty.proto";
import "google/protobuf/timestamp.proto";

// Detached from Visibility: a blank line follows.

// Who may read a note.
enum Visibility {
  option allow_alias = true;
  // Nobody said.
  VISIBILITY_UNSPECIFIED = 0;
  VISIBILITY_PRIVATE = 1; // Only the author.
  VISIBILITY_PUBLIC = 2 [deprecated = true];
  VISIBILITY_OPEN = 2;
}

// A note.
//
//   Indented, after a blank line.
message Note {
  option deprecated = true;

  // The resource name.
  string name = 1 [(google.api.field_behavior) = IDENTIFIER];
  string title = 2 [json_name = "heading", deprecated = true];
  Visibility visibility = 3;
  repeated string tags = 4 [(google.api.field_behavior) = OPTIONAL, (google.api.field_behavior) = UNORDERED_LIST];
  map<string, int64> counts = 5;
  map<int32, Note> children = 6;
  optional bool pinned = 7;
  google.protobuf.Timestamp created = 8 [json_name = "created"];
  int64 revision = 9 [jstype = JS_STRING];
  bytes body = 10;
  // What happened last.
  oneof last {
    // Created.
    google.protobuf.Empty made = 11;
    Inner moved = 12; /* Moved
       elsewhere. */
  }
  message Inner {
    sfixed64 at = 1;
  }
  uint32 plain = 13;
}

// The notes service.
service NotesService {
  option deprecated = true;

  // Gets a note.
  rpc GetNote(Note.Inner) returns (Note) {
    option deprecated = true;
    option (google.api.http) = { get: "/v1/notes" };
  }
  rpc Clear(google.protobuf.Empty) returns (google.protobuf.Empty);
}
"#;

fn notes() -> Package {
    package(NOTES)
}

fn doc(comment: Option<&str>, declaration: &str, deprecated: bool) -> Doc {
    Doc {
        comment: comment.map(str::to_owned),
        declaration: declaration.to_owned(),
        deprecated,
    }
}

#[test]
fn messages_carry_their_comment_declaration_and_deprecation() {
    let package = notes();
    let note = &package.messages[0];
    assert_eq!(
        note.doc,
        doc(
            Some("A note.\n\n  Indented, after a blank line."),
            "message notes.v1.Note",
            true
        )
    );
    let inner = &package.messages[1];
    assert_eq!(inner.doc, doc(None, "message notes.v1.Note.Inner", false));
}

#[test]
fn fields_carry_every_shape_of_declaration() {
    let package = notes();
    let note = &package.messages[0];
    let lines: Vec<(&str, &str, Option<&str>, bool)> = note
        .fields
        .iter()
        .map(|field| {
            (
                field.proto_name.as_str(),
                field.doc.declaration.as_str(),
                field.doc.comment.as_deref(),
                field.doc.deprecated,
            )
        })
        .collect();
    assert_eq!(
        lines,
        [
            (
                "name",
                "string name = 1 [(google.api.field_behavior) = IDENTIFIER];",
                Some("The resource name."),
                false
            ),
            (
                "title",
                "string title = 2 [json_name = \"heading\", deprecated = true];",
                None,
                true
            ),
            (
                "visibility",
                "notes.v1.Visibility visibility = 3;",
                None,
                false
            ),
            (
                "tags",
                "repeated string tags = 4 [(google.api.field_behavior) = OPTIONAL, \
                 (google.api.field_behavior) = UNORDERED_LIST];",
                None,
                false
            ),
            ("counts", "map<string, int64> counts = 5;", None, false),
            (
                "children",
                "map<int32, notes.v1.Note> children = 6;",
                None,
                false
            ),
            ("pinned", "optional bool pinned = 7;", None, false),
            (
                "created",
                "google.protobuf.Timestamp created = 8 [json_name = \"created\"];",
                None,
                false
            ),
            (
                "revision",
                "int64 revision = 9 [jstype = JS_STRING];",
                None,
                false
            ),
            ("body", "bytes body = 10;", None, false),
            ("plain", "uint32 plain = 13;", None, false),
        ]
    );
}

#[test]
fn oneofs_and_members_carry_theirs() {
    let package = notes();
    let last = &package.messages[0].oneofs[0];
    assert_eq!(
        last.doc,
        doc(Some("What happened last."), "oneof last", false)
    );
    let members: Vec<&Doc> = last.variants.iter().map(|member| &member.doc).collect();
    assert_eq!(
        members,
        [
            &doc(Some("Created."), "google.protobuf.Empty made = 11;", false),
            &doc(
                Some("Moved\nelsewhere."),
                "notes.v1.Note.Inner moved = 12;",
                false
            ),
        ]
    );
}

#[test]
fn enums_and_their_values_carry_theirs_detached_comments_dropped() {
    let package = notes();
    let visibility = &package.enums[0];
    assert_eq!(
        visibility.doc,
        doc(
            Some("Who may read a note."),
            "enum notes.v1.Visibility",
            false
        )
    );
    let value = |name: &str| visibility.value_doc(name).cloned();
    assert_eq!(
        value("VISIBILITY_UNSPECIFIED"),
        Some(doc(
            Some("Nobody said."),
            "VISIBILITY_UNSPECIFIED = 0;",
            false
        ))
    );
    assert_eq!(
        value("VISIBILITY_PRIVATE"),
        Some(doc(
            Some("Only the author."),
            "VISIBILITY_PRIVATE = 1;",
            false
        ))
    );
    assert_eq!(
        value("VISIBILITY_PUBLIC"),
        Some(doc(
            None,
            "VISIBILITY_PUBLIC = 2 [deprecated = true];",
            true
        ))
    );
    // An alias has its own.
    assert_eq!(
        value("VISIBILITY_OPEN"),
        Some(doc(None, "VISIBILITY_OPEN = 2;", false))
    );
    assert_eq!(value("VISIBILITY_NONE"), None);
}

#[test]
fn services_and_methods_carry_theirs() {
    let package = notes();
    let service = &package.services[0];
    assert_eq!(
        service.doc,
        doc(
            Some("The notes service."),
            "service notes.v1.NotesService",
            true
        )
    );
    let docs: Vec<&Doc> = service.methods.iter().map(|method| &method.doc).collect();
    assert_eq!(
        docs,
        [
            &doc(
                Some("Gets a note."),
                "rpc GetNote(Note.Inner) returns (Note)",
                true
            ),
            &doc(
                None,
                "rpc Clear(google.protobuf.Empty) returns (google.protobuf.Empty)",
                false
            ),
        ]
    );
}

#[test]
fn method_declarations_say_where_they_stream() {
    let pool = pool(&[(
        "test.proto",
        r#"syntax = "proto3";
package t;
message M {}
service S {
  rpc Up(stream M) returns (M);
  rpc Down(M) returns (stream M);
  rpc Both(stream M) returns (stream M);
}
"#,
    )]);
    let service = pool.get_service_by_name("t.S").expect("the service");
    let lines: Vec<String> = service.methods().map(|m| declaration::method(&m)).collect();
    assert_eq!(
        lines,
        [
            "rpc Up(stream M) returns (M)",
            "rpc Down(M) returns (stream M)",
            "rpc Both(stream M) returns (stream M)",
        ]
    );
}

#[test]
fn options_of_every_value_kind_print_on_one_line() {
    let pool = pool(&[(
        "test.proto",
        r#"syntax = "proto3";
package t;
import "google/protobuf/descriptor.proto";
message Limits { int32 min = 1; int32 max = 2; }
extend google.protobuf.FieldOptions {
  Limits limits = 50001;
  string label = 50002;
  repeated int32 codes = 50003;
}
message M {
  string a = 1 [(t.limits) = { min: 1 max: 2 }, (t.label) = "say \"hi\"", (t.codes) = 3, (t.codes) = 4];
  string b = 2 [deprecated = false, json_name = "b"];
}
"#,
    )]);
    let message = pool.get_message_by_name("t.M").expect("the message");
    let lines: Vec<String> = message
        .fields()
        .map(|field| declaration::field(&field, false))
        .collect();
    assert_eq!(
        lines,
        [
            "string a = 1 [(t.limits) = { min: 1 max: 2 }, (t.label) = \"say \\\"hi\\\"\", \
             (t.codes) = 3, (t.codes) = 4];",
            "string b = 2 [deprecated = false];",
        ]
    );
}

#[test]
fn a_package_without_comments_has_none() {
    let package = package("syntax = \"proto3\"; package p; message A { int32 x = 1; }");
    let a = &package.messages[0];
    assert_eq!(a.doc, doc(None, "message p.A", false));
    assert_eq!(a.fields[0].doc, doc(None, "int32 x = 1;", false));
}
