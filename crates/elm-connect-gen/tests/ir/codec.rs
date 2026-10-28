//! What the `codec` option asks of the IR: the names the binary codecs
//! claim, and which repeated fields protobuf binary writes unpacked.

use elm_connect_gen::diagnostics::{Code, Diagnostics};
use elm_connect_gen::ir::{self, Package};
use elm_connect_gen::{Codec, Options};

use crate::common::pool;

const BESIDE: &str = r#"syntax = "proto3";
package t;
message Note { string title = 1; }
message NoteBytes { bytes content = 1; }
message Status { int32 code = 1; }
enum StatusBytes { STATUS_BYTES_UNSPECIFIED = 0; }
"#;

fn build(source: &str, codec: Codec, renames: &[&str]) -> Result<Vec<Package>, Diagnostics> {
    let mut options = Options::default();
    options.codec = codec;
    for entry in renames {
        options.add_rename(entry).expect("a rename");
    }
    ir::build_with(&pool(&[("t.proto", source)]), &["t.proto"], &options)
        .map(|built| built.packages)
}

fn collisions(diagnostics: &Diagnostics) -> Vec<String> {
    diagnostics
        .iter()
        .inspect(|problem| assert_eq!(problem.code(), Code::CodecCollision))
        .map(|problem| problem.message().to_owned())
        .collect()
}

#[test]
fn json_codecs_alone_claim_no_bytes_names() {
    assert!(build(BESIDE, Codec::Json, &[]).is_ok());
}

#[test]
fn both_codecs_meet_a_type_named_with_bytes() {
    let diagnostics = build(BESIDE, Codec::Both, &[]).expect_err("two collisions");
    let messages = collisions(&diagnostics);
    assert_eq!(messages.len(), 2, "{messages:?}");
    assert!(
        messages[0].contains("`encodeNoteBytes` and `decodeNoteBytes`"),
        "{messages:?}"
    );
    assert!(
        messages[1].contains("`encodeStatusBytes` and `decodeStatusBytes`"),
        "{messages:?}"
    );
}

#[test]
fn binary_codecs_alone_meet_only_an_enum() {
    // Under codec=binary the message `NoteBytes` has no JSON codecs, but
    // the enum `StatusBytes` keeps its.
    let diagnostics = build(BESIDE, Codec::Binary, &[]).expect_err("one collision");
    let messages = collisions(&diagnostics);
    assert_eq!(messages.len(), 1, "{messages:?}");
    assert!(messages[0].contains("`encodeStatusBytes`"), "{messages:?}");
}

#[test]
fn a_rename_parts_the_codecs() {
    let renames = ["t.NoteBytes:NoteContent", "t.StatusBytes:StatusKind"];
    assert!(build(BESIDE, Codec::Both, &renames).is_ok());
}

#[test]
fn a_rename_that_makes_the_collision_is_named() {
    let source = r#"syntax = "proto3";
package t;
message Note { string title = 1; }
message Memo { bytes content = 1; }
"#;
    let diagnostics = build(source, Codec::Both, &["t.Memo:NoteBytes"]).expect_err("a collision");
    assert_eq!(collisions(&diagnostics).len(), 1);
    let help = diagnostics.iter().next().unwrap().help_text();
    assert!(help.contains("That name comes from"), "{help}");
}

#[test]
fn a_field_declared_unpacked_is_read_from_its_own_options() {
    let source = r#"syntax = "proto3";
package t;
message Lists {
  repeated int32 packed = 1;
  repeated int32 unpacked = 2 [packed = false];
  repeated string names = 3;
}
"#;
    let packages = build(source, Codec::Both, &[]).expect("built");
    let unpacked: Vec<(&str, bool)> = packages[0].messages[0]
        .fields
        .iter()
        .map(|field| (field.elm_name.as_str(), field.unpacked))
        .collect();
    assert_eq!(
        unpacked,
        [("packed", false), ("unpacked", true), ("names", false)]
    );
}
