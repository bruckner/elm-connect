//! Rendered diagnostics, pinned: the register and the spans.

use crate::common::{problems, render};

const COLLISION: &str = r#"syntax = "proto3";

package notes.v1;

message Note {
  string display_name = 1;
  oneof displayName {
    string text = 2;
  }
}
"#;

#[test]
fn field_collision_renders_both_sites() {
    let files = [("notes/v1/note.proto", COLLISION)];
    let diagnostics = problems(&files, &["notes/v1/note.proto"]);
    assert_eq!(render(&diagnostics, &files), EXPECTED);
}

const EXPECTED: &str = r#"naming::field_collision

  × The message `notes.v1.Note` has two fields that both become `displayName`
  │ in Elm.
   ╭─[notes/v1/note.proto:6:10]
 5 │ message Note {
 6 │   string display_name = 1;
   ·          ──────┬─────
   ·                ╰── field `display_name` becomes `displayName`
 7 │   oneof displayName {
   ·         ─────┬─────
   ·              ╰── and so does oneof `displayName`
 8 │     string text = 2;
   ╰────
  help: Elm record fields are the proto field names in lowerCamelCase, so
        names that differ only in underscores or reserved-word escaping end up
        the same, and a record cannot have two fields with one name. Rename
        one of them in the proto.
"#;

#[test]
fn without_sources_a_problem_still_names_its_elements() {
    let files = [("notes/v1/note.proto", COLLISION)];
    let diagnostics = crate::common::build(&files, &["notes/v1/note.proto"]).unwrap_err();
    let rendered = elm_connect_gen::diagnostics::render_narrow(&diagnostics);
    assert!(
        rendered.starts_with("naming::field_collision\n"),
        "{rendered}"
    );
    assert!(rendered.contains("`notes.v1.Note`"), "{rendered}");
    assert!(!rendered.contains("╭─["), "{rendered}");
}
