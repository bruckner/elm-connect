use std::path::PathBuf;

use miette::{GraphicalReportHandler, GraphicalTheme};

fn fixtures() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures")
}

fn render(report: &miette::Report) -> String {
    render_at(report, 80)
}

/// `report` rendered `width` columns wide: wide enough, a long path stays
/// on one line.
fn render_at(report: &miette::Report, width: usize) -> String {
    let handler =
        GraphicalReportHandler::new_themed(GraphicalTheme::unicode_nocolor()).with_width(width);
    let mut out = String::new();
    handler
        .render_report(&mut out, report.as_ref())
        .expect("rendering a report into a String cannot fail");
    out
}

#[test]
fn syntax_error_renders_with_file_and_line() {
    let report = elm_connect::compile(&[PathBuf::from("broken.proto")], &[fixtures()])
        .expect_err("broken.proto has a missing semicolon");
    let rendered = render(&report);

    assert!(rendered.contains("broken.proto:7:"), "{rendered}");
    assert!(rendered.contains("string body = 2;"), "{rendered}");
}

/// A directory under the target's temporary directory holding `files`.
fn inputs(name: &str, files: &[(&str, &str)]) -> PathBuf {
    let dir = PathBuf::from(env!("CARGO_TARGET_TMPDIR")).join(name);
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("create the input directory");
    for (name, text) in files {
        std::fs::write(dir.join(name), text).expect("write the input");
    }
    dir
}

#[test]
fn an_edition_2023_file_generates() {
    let dir = inputs(
        "cli-edition-2023",
        &[
            (
                "edition.proto",
                "// An editions file.\nedition = \"2023\";\npackage e.v1;\nmessage M { string a = 1; }\n",
            ),
            (
                "importer.proto",
                "syntax = \"proto3\";\npackage i.v1;\nimport \"edition.proto\";\nmessage A { e.v1.M m = 1; }\n",
            ),
        ],
    );
    let generated = elm_connect::generate(
        &[PathBuf::from("importer.proto")],
        std::slice::from_ref(&dir),
        true,
        &elm_connect_gen::Options::default(),
    )
    .unwrap_or_else(|report| panic!("{}", render(&report)));
    let module = generated
        .files
        .iter()
        .find(|file| file.path == "E/V1.elm")
        .expect("the editions package is generated");
    // Edition 2023's presence is explicit by default.
    assert!(
        module.content.contains("{ a : Maybe String\n"),
        "{}",
        module.content
    );
    // The file's leading comment documents its package, as a proto3 file's does.
    assert!(
        module.content.contains("{-| An editions file.\n-}"),
        "{}",
        module.content
    );
}

#[test]
fn an_edition_2024_file_generates() {
    let dir = inputs(
        "cli-edition-2024",
        &[
            (
                "edition.proto",
                "edition = \"2024\";\npackage e.v1;\nimport option \"labels.proto\";\n\
                 export message M { local message N {} N n = 1; string a = 2 [(l.v1.text) = \"A\"]; }\n",
            ),
            (
                "labels.proto",
                "edition = \"2024\";\npackage l.v1;\nimport \"google/protobuf/descriptor.proto\";\n\
                 extend google.protobuf.FieldOptions { string text = 50001; }\n",
            ),
        ],
    );
    let generated = elm_connect::generate(
        &[PathBuf::from("edition.proto")],
        std::slice::from_ref(&dir),
        false,
        &elm_connect_gen::Options::default(),
    )
    .unwrap_or_else(|report| panic!("{}", render(&report)));
    let paths: Vec<&str> = generated.files.iter().map(|f| f.path.as_str()).collect();
    // The local nested message is generated with the rest; the option import's
    // package is not.
    assert_eq!(paths, ["E/V1.elm", "E/V1/M.elm", "E/V1/MN.elm"]);
}

#[test]
fn edition_2024_names_that_break_the_style_get_a_code() {
    let dir = inputs(
        "cli-edition-2024-naming",
        &[(
            "naming.proto",
            "edition = \"2024\";\npackage n.v1;\nmessage bad_name { int32 camelCase = 1; }\n",
        )],
    );
    let report = elm_connect::compile(&[PathBuf::from("naming.proto")], std::slice::from_ref(&dir))
        .expect_err("the names break the style");
    let rendered = render(&report);
    assert_eq!(
        rendered.matches("input::naming_style").count(),
        2,
        "{rendered}"
    );
    assert!(
        rendered.contains("Message name bad_name should be TitleCase."),
        "{rendered}"
    );
    assert!(rendered.contains("╭─[naming.proto:3:9]"), "{rendered}");
    assert!(
        rendered.contains("Field name camelCase should be lower_snake_case."),
        "{rendered}"
    );
}

#[test]
fn a_later_edition_is_refused_in_elm_connects_words() {
    let dir = inputs(
        "cli-editions",
        &[
            (
                "edition.proto",
                "// A later edition.\nedition = \"2025\";\npackage e.v1;\nmessage M { string a = 1; }\n",
            ),
            (
                "importer.proto",
                "syntax = \"proto3\";\npackage i.v1;\nimport \"edition.proto\";\nmessage A { e.v1.M m = 1; }\n",
            ),
        ],
    );
    for file in ["edition.proto", "importer.proto"] {
        let report = elm_connect::compile(&[PathBuf::from(file)], std::slice::from_ref(&dir))
            .expect_err("edition 2025 is not supported");
        let rendered = render(&report);
        assert!(rendered.contains("input::editions"), "{rendered}");
        assert!(
            rendered.contains("The file `edition.proto` declares `edition = \"2025\"`"),
            "{rendered}"
        );
        assert!(rendered.contains("╭─[edition.proto:2:1]"), "{rendered}");
        assert!(rendered.contains("`edition = \"2024\";`"), "{rendered}");
    }

    let output = std::process::Command::new(env!("CARGO_BIN_EXE_elm-connect"))
        .args(["gen", "edition.proto", "--out", "out", "-I"])
        .arg(&dir)
        .output()
        .expect("run elm-connect");
    assert_eq!(output.status.code(), Some(1), "{output:?}");
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("input::editions"), "{stderr}");
    assert!(!stderr.contains("panicked"), "{stderr}");
}

#[test]
fn an_edition_2023_file_that_does_not_parse_keeps_the_parsers_errors() {
    let dir = inputs(
        "cli-edition-2023-error",
        &[(
            "broken.proto",
            "edition = \"2023\";\npackage b.v1;\nmessage M { optional string a = 1; }\n",
        )],
    );
    let report = elm_connect::compile(&[PathBuf::from("broken.proto")], &[dir])
        .expect_err("`optional` is not an editions label");
    let rendered = render(&report);
    assert!(!rendered.contains("input::editions"), "{rendered}");
    assert!(rendered.contains("optional"), "{rendered}");
}

#[test]
fn fields_the_descriptor_library_refuses_get_a_code() {
    let dir = inputs(
        "cli-field-name-conflict",
        &[(
            "p.proto",
            "syntax = \"proto3\"; package p.v1;\nmessage M { string aB = 1; string ab = 2; }\n",
        )],
    );
    let report = elm_connect::compile(&[PathBuf::from("p.proto")], std::slice::from_ref(&dir))
        .expect_err("prost-reflect refuses `aB` beside `ab`");
    let rendered = render(&report);
    assert!(
        rendered.contains("input::field_name_conflict"),
        "{rendered}"
    );
    assert!(
        rendered.contains("The fields `aB` and `ab` of the message `p.v1.M` have names"),
        "{rendered}"
    );
    assert!(
        rendered.contains("elm-connect found a problem in the protos"),
        "{rendered}"
    );
    assert!(rendered.contains("╭─[p.proto:2:20]"), "{rendered}");
    assert!(rendered.contains("this field"), "{rendered}");
    assert!(
        rendered.contains("has the same name as this one once lowercased"),
        "{rendered}"
    );
    assert!(rendered.contains("`--rename` cannot help"), "{rendered}");
    assert!(!rendered.contains("prost-reflect"), "{rendered}");

    let output = std::process::Command::new(env!("CARGO_BIN_EXE_elm-connect"))
        .args(["gen", "p.proto", "--out", "out", "-I"])
        .arg(&dir)
        .output()
        .expect("run elm-connect");
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("Error: input::field_name_conflict"),
        "{stderr}"
    );
    assert!(stderr.contains("Codes and their escapes:"), "{stderr}");
}

#[test]
fn a_proto3_file_turned_proto2_is_refused_before_its_labels() {
    let dir = inputs(
        "cli-proto2-labels",
        &[
            (
                "flipped.proto",
                "// Was proto3.\nsyntax = \"proto2\";\npackage f.v1;\nmessage M { string a = 1; int32 b = 2; }\n",
            ),
            (
                "bare.proto",
                "// No syntax.\npackage b.v1;\nmessage M { string a = 1; }\n",
            ),
        ],
    );
    let report = elm_connect::compile(
        &[PathBuf::from("flipped.proto")],
        std::slice::from_ref(&dir),
    )
    .expect_err("a proto2 file");
    let rendered = render(&report);
    assert!(rendered.contains("input::not_proto3"), "{rendered}");
    assert!(rendered.contains("uses proto2 syntax"), "{rendered}");
    assert!(rendered.contains("╭─[flipped.proto:2:1]"), "{rendered}");
    assert!(!rendered.contains("label"), "no parser errors: {rendered}");

    let report = elm_connect::compile(&[PathBuf::from("bare.proto")], std::slice::from_ref(&dir))
        .expect_err("a file without syntax is proto2");
    let rendered = render(&report);
    assert!(rendered.contains("input::not_proto3"), "{rendered}");
    assert!(rendered.contains("has no `syntax` statement"), "{rendered}");
    assert!(rendered.contains("╭─[bare.proto:1:1]"), "{rendered}");
}

#[test]
fn a_proto2_import_that_does_not_parse_stays_a_parse_error() {
    let dir = inputs(
        "cli-proto2-import",
        &[
            (
                "old.proto",
                "syntax = \"proto2\";\npackage o.v1;\nmessage O { string a = 1; }\n",
            ),
            (
                "new.proto",
                "syntax = \"proto3\";\npackage n.v1;\nimport \"old.proto\";\nmessage N { o.v1.O o = 1; }\n",
            ),
        ],
    );
    let report = elm_connect::compile(&[PathBuf::from("new.proto")], std::slice::from_ref(&dir))
        .expect_err("the import does not parse");
    assert!(!render(&report).contains("input::not_proto3"));
}

#[test]
fn other_syntax_errors_stay_protoxs() {
    let dir = inputs(
        "cli-edition-word",
        &[(
            "word.proto",
            "syntax = \"proto3\";\npackage w.v1;\nmessage M { edition = 1; }\n",
        )],
    );
    let report = elm_connect::compile(&[PathBuf::from("word.proto")], &[dir])
        .expect_err("a field without a type");
    assert!(!render(&report).contains("input::editions"));
}

#[test]
fn a_missing_import_names_the_include_paths_searched() {
    let dir = inputs(
        "cli-missing-import",
        &[(
            "library.proto",
            "syntax = \"proto3\";\npackage l.v1;\nimport \"users/v1/user.proto\";\nmessage M {}\n",
        )],
    );
    let other = inputs("cli-missing-import-other", &[]);
    let report = elm_connect::compile(
        &[PathBuf::from("library.proto")],
        &[dir.clone(), other.clone()],
    )
    .expect_err("the import is on no include path");
    let rendered = render_at(&report, 400);
    assert!(
        rendered.contains("elm-connect found a problem in the protos"),
        "{rendered}"
    );
    assert!(rendered.contains("input::file_not_found"), "{rendered}");
    assert!(
        rendered.contains(
            "The file `library.proto` imports `users/v1/user.proto`, which is under none of \
             the include paths."
        ),
        "{rendered}"
    );
    assert!(rendered.contains("╭─[library.proto:3:1]"), "{rendered}");
    assert!(rendered.contains("imported here"), "{rendered}");
    let flat = rendered;
    assert!(
        flat.contains(&format!(
            "The include paths searched were `{}`, `{}` (`-I`",
            dir.display(),
            other.display()
        )),
        "{flat}"
    );
    assert!(flat.contains("with `-I`"), "{flat}");
    assert!(!flat.contains("does not exist"), "{flat}");

    let absent = dir.join("protos");
    let report = elm_connect::compile(
        &[PathBuf::from("library.proto")],
        std::slice::from_ref(&absent),
    )
    .expect_err("the include path does not exist");
    let flat = render_at(&report, 400);
    assert!(
        flat.contains(&format!("`{}` does not exist.", absent.display())),
        "{flat}"
    );
    assert!(
        flat.contains("The file `library.proto` is under none of the include paths."),
        "{flat}"
    );
}

#[test]
fn a_missing_file_is_a_report_without_a_snippet() {
    let dir = inputs("cli-missing-file", &[]);
    let report = elm_connect::compile(&[PathBuf::from("absent.proto")], std::slice::from_ref(&dir))
        .expect_err("no such file");
    let rendered = render(&report);
    assert!(
        rendered.contains("elm-connect found a problem in the protos"),
        "{rendered}"
    );
    assert!(
        rendered.contains("The file `absent.proto` is under none of the include paths."),
        "{rendered}"
    );
    assert!(
        rendered.contains("The include paths searched were"),
        "{rendered}"
    );
    assert!(!rendered.contains("╭─["), "no snippet: {rendered}");

    let output = std::process::Command::new(env!("CARGO_BIN_EXE_elm-connect"))
        .args(["gen", "absent.proto", "--out", "out", "-I"])
        .arg(&dir)
        .output()
        .expect("run elm-connect");
    assert_eq!(output.status.code(), Some(1), "{output:?}");
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("elm-connect found a problem in the protos"),
        "{stderr}"
    );
    assert!(stderr.contains("Error: input::file_not_found"), "{stderr}");
    assert!(stderr.contains("Codes and their escapes:"), "{stderr}");
}
