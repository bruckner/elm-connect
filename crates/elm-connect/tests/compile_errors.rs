use std::path::PathBuf;

use miette::{GraphicalReportHandler, GraphicalTheme};

fn fixtures() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures")
}

fn render(report: &miette::Report) -> String {
    let handler =
        GraphicalReportHandler::new_themed(GraphicalTheme::unicode_nocolor()).with_width(80);
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
fn an_editions_file_is_refused_in_elm_connects_words() {
    let dir = inputs(
        "cli-editions",
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
    for file in ["edition.proto", "importer.proto"] {
        let report = elm_connect::compile(&[PathBuf::from(file)], std::slice::from_ref(&dir))
            .expect_err("editions are not supported");
        let rendered = render(&report);
        assert!(rendered.contains("input::editions"), "{rendered}");
        assert!(
            rendered.contains("The file `edition.proto` declares `edition = \"2023\"`"),
            "{rendered}"
        );
        assert!(rendered.contains("╭─[edition.proto:2:1]"), "{rendered}");
        assert!(rendered.contains("syntax = \"proto3\";"), "{rendered}");
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
    let rendered = render(&report);
    assert!(
        rendered.contains("import 'users/v1/user.proto' not found"),
        "protox's own message stays: {rendered}"
    );
    assert!(rendered.contains("imported here"), "{rendered}");
    let help = report.help().expect("a help").to_string();
    assert!(
        help.starts_with(&format!(
            "The include paths searched were `{}`, `{}` (`-I`",
            dir.display(),
            other.display()
        )),
        "{help}"
    );
    assert!(help.contains("with `-I`"), "{help}");

    let report = elm_connect::compile(&[PathBuf::from("absent.proto")], std::slice::from_ref(&dir))
        .expect_err("no such file");
    assert!(render(&report).contains("The include paths searched were"));
}
