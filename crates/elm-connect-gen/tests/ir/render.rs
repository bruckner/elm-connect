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
        one of them in the proto, or rename one with
        `rename=notes.v1.Note.displayName:<Elm name>`.
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

#[test]
fn help_names_options_as_each_front_end_writes_them() {
    use elm_connect_gen::Spelling;
    use elm_connect_gen::diagnostics::{Diagnostics, Problem, Site, render_narrow};

    let render = |spelling| {
        let site = Site {
            file: "chat.proto".into(),
            span: None,
            label: "streams here".into(),
        };
        let problem = Problem::streaming("chat.v1.Chat.Listen", "server", site, spelling);
        render_narrow(&Diagnostics::from(problem))
    };
    let plugin = render(Spelling::Parameter);
    let cli = render(Spelling::Flags);
    assert!(
        plugin.contains("Pass `streaming=skip` to leave"),
        "{plugin}"
    );
    assert!(!plugin.contains("--streaming"), "{plugin}");
    assert!(cli.contains("Pass `--streaming skip` to leave"), "{cli}");
    assert!(!cli.contains("streaming=skip"), "{cli}");
}

#[test]
fn a_suggestion_is_close_or_differs_only_in_case_and_underscores() {
    use elm_connect_gen::diagnostics::closest;

    let fields = ["name", "page_count", "books"];
    assert_eq!(closest("nme", fields), Some("name".to_owned()));
    assert_eq!(closest("pageCount", fields), Some("page_count".to_owned()));
    assert_eq!(closest("PAGE_COUNT", fields), Some("page_count".to_owned()));
    assert_eq!(closest("bokos", fields), Some("books".to_owned()));
    assert_eq!(closest("title", fields), None, "nothing is that close");
    assert_eq!(closest("name", fields), None, "a candidate needs none");
}
