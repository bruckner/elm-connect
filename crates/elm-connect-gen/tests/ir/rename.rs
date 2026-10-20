//! The rename map in the IR: what derives from a renamed name and what
//! does not, and the problems a rename can still meet.

use elm_connect_gen::Options;
use elm_connect_gen::diagnostics::{Code, Diagnostics};
use elm_connect_gen::ir::{self, Package};

use crate::common::pool;

const NOTES: &str = r#"syntax = "proto3";
package notes.v1;
import "google/protobuf/empty.proto";
message Outer {
  message Inner {}
  Inner inner = 1;
  google.protobuf.Empty nothing = 2;
}
message Note {}
"#;

fn build(renames: &[&str]) -> Result<Vec<Package>, Diagnostics> {
    let mut options = Options::default();
    for entry in renames {
        options.add_rename(entry).expect("a rename");
    }
    ir::build_with(&pool(&[("notes.proto", NOTES)]), &["notes.proto"], &options)
        .map(|built| built.packages)
}

fn type_names(package: &Package) -> Vec<&str> {
    package
        .messages
        .iter()
        .map(|message| message.elm_name.as_str())
        .collect()
}

fn codes(diagnostics: &Diagnostics) -> Vec<Code> {
    diagnostics.iter().map(|problem| problem.code()).collect()
}

#[test]
fn a_nested_type_follows_its_renamed_parent() {
    let packages = build(&["notes.v1.Outer:Shell"]).expect("builds");
    assert_eq!(type_names(&packages[0]), ["Shell", "ShellInner", "Note"]);
    let packages = build(&["notes.v1.Outer.Inner:Core"]).expect("builds");
    assert_eq!(type_names(&packages[0]), ["Outer", "Core", "Note"]);
}

#[test]
fn a_rename_can_collide() {
    let diagnostics = build(&["notes.v1.Outer:Note"]).expect_err("two types `Note`");
    // Two messages' record constructors collide with their types, which
    // is the one problem.
    assert_eq!(codes(&diagnostics), [Code::TypeCollision]);
}

#[test]
fn a_collision_a_rename_causes_points_at_the_rename() {
    let mut options = Options::default();
    options.spelling = elm_connect_gen::Spelling::Flags;
    options.add_rename("notes.v1.Outer:Note").expect("a rename");
    let diagnostics = ir::build_with(&pool(&[("notes.proto", NOTES)]), &["notes.proto"], &options)
        .expect_err("two types `Note`");
    let problem = diagnostics.iter().next().expect("a problem");
    let labels: Vec<&str> = problem
        .sites()
        .iter()
        .map(|site| site.label.as_str())
        .collect();
    assert_eq!(
        labels,
        [
            "message `notes.v1.Outer` is renamed to `Note` by `--rename`",
            "and so does message `notes.v1.Note`"
        ]
    );
    assert!(
        problem
            .help_text()
            .ends_with("That name comes from `--rename notes.v1.Outer:Note`: give it another there, or rename the other one in the proto."),
        "{}",
        problem.help_text()
    );
}

#[test]
fn a_rename_names_a_generated_element() {
    let diagnostics = build(&["google.protobuf.Empty:Nothing", "notes.v2:Notes.V2"])
        .expect_err("neither is generated");
    assert_eq!(codes(&diagnostics), [Code::UnknownRename; 2]);
}

#[test]
fn a_renamed_field_is_taken_as_written() {
    // A proto field `Label` becomes `label`; a rename to `Label` is not
    // converted, so it is no Elm field name.
    let diagnostics = build(&["notes.v1.Outer.inner:Label"]).expect_err("an uppercase field");
    assert_eq!(codes(&diagnostics), [Code::InvalidRename]);
}
