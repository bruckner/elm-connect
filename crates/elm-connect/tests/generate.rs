//! `elm-connect gen` end to end, in-process: the conformance corpus's
//! scalars case, and a problem rendered against its proto source.

use std::fs;
use std::path::{Path, PathBuf};

use elm_connect_gen::Options;
use miette::{GraphicalReportHandler, GraphicalTheme};

fn scalars_case() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../conformance/cases/scalars")
}

#[test]
fn scalars_case_generates_its_expected_output() {
    let case = scalars_case();
    let generated = elm_connect::generate(
        &[PathBuf::from("scalars.proto")],
        &[case.join("input")],
        &Options::default(),
    )
    .unwrap_or_else(|report| panic!("{report:?}"));
    let out = Path::new(env!("CARGO_TARGET_TMPDIR")).join("cli-scalars");
    let _ = fs::remove_dir_all(&out);
    let written = elm_connect::write(&generated, &out).expect("write the output");

    assert_eq!(written, [out.join("Scalars/V1.elm")]);
    let expected = fs::read_to_string(case.join("expected/Scalars/V1.elm")).expect("blessed");
    let actual = fs::read_to_string(&written[0]).expect("written");
    assert!(
        actual == expected,
        "the CLI's output differs from the blessed expected output; run the \
         conformance tests for a diff"
    );
}

#[test]
fn problems_render_against_the_proto_source() {
    let dir = Path::new(env!("CARGO_TARGET_TMPDIR")).join("cli-problem");
    fs::create_dir_all(&dir).expect("create the input directory");
    fs::write(
        dir.join("clash.proto"),
        "syntax = \"proto3\";\n\npackage clash.v1;\n\nmessage Note {\n  string display_name = 1;\n  \
         oneof displayName {\n    string text = 2;\n  }\n}\n",
    )
    .expect("write the input");
    let report =
        elm_connect::generate(&[PathBuf::from("clash.proto")], &[dir], &Options::default())
            .expect_err("two fields become `displayName`");
    let mut rendered = String::new();
    GraphicalReportHandler::new_themed(GraphicalTheme::unicode_nocolor())
        .with_width(80)
        .render_report(&mut rendered, report.as_ref())
        .expect("rendering into a String cannot fail");

    assert!(rendered.contains("naming::field_collision"), "{rendered}");
    assert!(rendered.contains("╭─[clash.proto:6:10]"), "{rendered}");
    assert!(rendered.contains("string display_name = 1;"), "{rendered}");
}
