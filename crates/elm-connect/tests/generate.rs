//! `elm-connect gen` end to end, in-process: the conformance corpus's
//! scalars case, a problem rendered against its proto source, and
//! `--include-imports` and where `--module-prefix` writes, which the
//! corpus cannot express (its `options.txt` is the plugin parameter).

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
        false,
        &Options::default(),
    )
    .unwrap_or_else(|report| panic!("{report:?}"));
    let out = Path::new(env!("CARGO_TARGET_TMPDIR")).join("cli-scalars");
    let _ = fs::remove_dir_all(&out);
    let written = elm_connect::write(&generated.files, &out).expect("write the output");

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
    let report = elm_connect::generate(
        &[PathBuf::from("clash.proto")],
        &[dir],
        false,
        &Options::default(),
    )
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

#[test]
fn google_api_annotations_need_no_include_path() {
    let dir = Path::new(env!("CARGO_TARGET_TMPDIR")).join("cli-annotations");
    fs::create_dir_all(&dir).expect("create the input directory");
    fs::write(
        dir.join("notes.proto"),
        "syntax = \"proto3\";\npackage notes.v1;\nimport \"google/api/annotations.proto\";\n\
         message Note { string name = 1; }\nservice Notes {\n  rpc GetNote(Note) returns (Note) {\n    \
         option (google.api.http) = { get: \"/v1/{name=notes/*}\" };\n  }\n}\n",
    )
    .expect("write the input");
    let compiled =
        elm_connect::compile(&[PathBuf::from("notes.proto")], &[dir]).expect("it compiles");
    assert_eq!(compiled.inputs, ["notes.proto"]);
    let packages = elm_connect_gen::ir::build(&compiled.pool, &["notes.proto"]).expect("builds");
    let rule = packages[0].services[0].methods[0].http.as_ref();
    assert_eq!(
        rule.map(|rule| rule.template.as_str()),
        Some("/v1/{name=notes/*}")
    );
}

#[test]
fn warnings_come_back_with_the_files() {
    let case = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../conformance/cases/services_streaming_skip");
    let mut options = Options::default();
    options.streaming = elm_connect_gen::Streaming::Skip;
    let generated = elm_connect::generate(
        &[PathBuf::from("chat.proto")],
        &[case.join("input")],
        false,
        &options,
    )
    .unwrap_or_else(|report| panic!("{report:?}"));

    let paths: Vec<&str> = generated.files.iter().map(|f| f.path.as_str()).collect();
    assert_eq!(paths, ["Chat/V1.elm", "Chat/V1/Chat.elm"]);
    let warnings = elm_connect_gen::diagnostics::render_narrow(&generated.warnings);
    assert_eq!(
        warnings,
        fs::read_to_string(case.join("expected/warnings.txt")).expect("blessed"),
        "the CLI's warnings carry the proto source, as the corpus pins them"
    );
}

/// Two packages, `notes.v1` importing `users.v1`, which imports a
/// well-known type, the googleapis annotations and a file declaring
/// nothing.
fn two_packages(name: &str) -> PathBuf {
    let dir = Path::new(env!("CARGO_TARGET_TMPDIR")).join(name);
    let _ = fs::remove_dir_all(&dir);
    for (path, text) in [
        (
            "notes/v1/note.proto",
            "syntax = \"proto3\";\npackage notes.v1;\nimport \"users/v1/user.proto\";\n\
             message Note {\n  string title = 1;\n  users.v1.User author = 2;\n}\n",
        ),
        (
            "users/v1/user.proto",
            "syntax = \"proto3\";\npackage users.v1;\n\
             import \"google/protobuf/timestamp.proto\";\n\
             import \"google/api/annotations.proto\";\nimport \"shared/v1/empty.proto\";\n\
             message User {\n  string name = 1;\n  google.protobuf.Timestamp joined = 2;\n}\n",
        ),
        (
            "shared/v1/empty.proto",
            "syntax = \"proto3\";\npackage shared.v1;\n",
        ),
    ] {
        let path = dir.join(path);
        fs::create_dir_all(path.parent().unwrap()).expect("create the input directory");
        fs::write(path, text).expect("write the input");
    }
    dir
}

#[test]
fn imported_packages_are_not_generated_by_default() {
    let dir = two_packages("cli-imports-off");
    let report = elm_connect::generate(
        &[PathBuf::from("notes/v1/note.proto")],
        &[dir],
        false,
        &Options::default(),
    )
    .expect_err("`users.v1` is not requested");
    let diagnostics = report
        .downcast_ref::<elm_connect_gen::diagnostics::Diagnostics>()
        .expect("the generator's diagnostics");
    let codes: Vec<_> = diagnostics.iter().map(|d| d.code()).collect();
    assert_eq!(codes, [elm_connect_gen::diagnostics::Code::NotGenerated]);
}

#[test]
fn include_imports_generates_the_imported_packages() {
    let dir = two_packages("cli-imports-on");
    let generated = elm_connect::generate(
        &[PathBuf::from("notes/v1/note.proto")],
        &[dir],
        true,
        &Options::default(),
    )
    .unwrap_or_else(|report| panic!("{report:?}"));

    let paths: Vec<&str> = generated.files.iter().map(|f| f.path.as_str()).collect();
    assert_eq!(paths, ["Notes/V1.elm", "Users/V1.elm"]);
    assert!(generated.files[0].content.contains("import Users.V1"));
}

#[test]
fn include_imports_leaves_out_runtime_googleapis_and_empty_files() {
    let dir = two_packages("cli-imports-set");
    let mut compiled =
        elm_connect::compile(&[PathBuf::from("notes/v1/note.proto")], &[dir]).expect("compiles");
    assert_eq!(compiled.inputs, ["notes/v1/note.proto"]);
    compiled.include_imports();
    assert_eq!(
        compiled.inputs,
        ["notes/v1/note.proto", "users/v1/user.proto"]
    );
}

#[test]
fn module_prefix_moves_every_generated_module_and_its_path() {
    let dir = two_packages("cli-module-prefix");
    let mut options = Options::default();
    options.module_prefix = Some(elm_connect_gen::parse_module_prefix("Api.Example").unwrap());
    let generated = elm_connect::generate(
        &[PathBuf::from("notes/v1/note.proto")],
        std::slice::from_ref(&dir),
        true,
        &options,
    )
    .unwrap_or_else(|report| panic!("{report:?}"));
    let out = dir.join("out");
    let written = elm_connect::write(&generated.files, &out).expect("write the output");

    assert_eq!(
        written,
        [
            out.join("Api/Example/Notes/V1.elm"),
            out.join("Api/Example/Users/V1.elm"),
        ]
    );
    let notes = &generated.files[0].content;
    assert!(notes.contains("module Api.Example.Notes.V1 exposing"));
    assert!(notes.contains("import Api.Example.Users.V1\n"));
    assert!(notes.contains("import Proto.Json\n"));
}
