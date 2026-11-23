//! The conformance corpus (design §7, `conformance/README.md`): every case
//! under `conformance/cases/` regenerates to its expected output, and that
//! output compiles against the runtime package and is in elm-format's
//! layout.
//!
//! A case is `input/` (proto files, compiled with protox and all
//! requested), an optional `include/` (protos the input may import, not
//! requested, though one of a requested package is generated with it) and
//! `expected/`, holding either the Elm modules generated
//! from the input, at their module paths, or `diagnostics.txt`, the
//! narrow rendering of the problems generating reports instead. Beside the
//! modules, `warnings.txt` is the narrow rendering of the warnings a
//! successful run reports, present exactly when there are some. An
//! optional `options.txt` holds the generator's options as a protoc plugin
//! parameter.
//!
//! A case with a `focus.txt` beside its inputs is focused: its `expected/`
//! holds `focused.txt`, the excerpt of the declarations and modules the
//! list names ([`common::focus`]), in place of the modules, and the golden
//! test compares only that, while the compiles and formatted tests take
//! the whole output generated afresh.
//!
//! With `ELM_CONNECT_BLESS=1` the golden and diagnostics tests rewrite
//! `expected/` to match the generator and pass; `just bless` does that.
//!
//! Expected modules carry `0.2.X` (the major and minor version, `X` for
//! the patch) in place of the generator's version on their header line
//! ([`placeholder_header`]), so a patch release does not rewrite the
//! corpus.
//!
//! The tools come from `mise.toml`; the tests fail, rather than skip, when
//! one is missing from PATH.

use std::collections::{BTreeMap, HashMap};
use std::fs;
use std::io::ErrorKind;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};

use elm_connect_gen::diagnostics::{Columns, Diagnostics, render_narrow};
use elm_connect_gen::{GeneratedFile, HEADER_PREFIX, VERSION, generate};

mod common;
use common::focus::{FOCUS, FOCUSED, Focus, Keep, case_focus, excerpt, parse_focus, split_module};
use common::{
    Compiled, DIAGNOSTICS, OPTIONS, WARNINGS, case_name, case_options, cases, compile_case,
    files_under, is_diagnostics_case, placeholder_header, protos, repo_root,
};
use similar::TextDiff;

/// What a successful run of the generator over a case gives.
struct Run {
    files: Vec<GeneratedFile>,
    /// The narrow rendering of the warnings, with the proto sources
    /// attached; empty for none.
    warnings: String,
}

/// What generating a case's input gives: the files and warnings, or the
/// narrow rendering of the problems, with the proto sources attached; the
/// problems in its `options.txt`, if it has any, instead.
/// Protos in the case's optional `include/` can be imported but are not
/// requested; those of a requested package are generated with it. The
/// case's `options.txt`, if any, sets the generator's
/// options.
fn run_generator(case: &Path) -> Result<Run, String> {
    let Compiled {
        compiler,
        names,
        include_paths,
    } = compile_case(case);
    let generate_set: Vec<&str> = names.iter().map(String::as_str).collect();
    let render = |mut diagnostics: Diagnostics| {
        let mut sources = HashMap::new();
        for dir in &include_paths {
            for name in protos(dir) {
                let text = fs::read_to_string(dir.join(&name)).expect("read a proto");
                sources.entry(name).or_insert(text);
            }
        }
        diagnostics.attach_sources(&sources, Columns::Bytes);
        render_narrow(&diagnostics)
    };
    let options = case_options(case).map_err(render)?;
    match generate(&compiler.descriptor_pool(), &generate_set, &options) {
        Ok(generated) => Ok(Run {
            files: generated.files,
            warnings: if generated.warnings.is_empty() {
                String::new()
            } else {
                render(generated.warnings)
            },
        }),
        Err(diagnostics) => Err(render(diagnostics)),
    }
}

fn blessing() -> bool {
    std::env::var_os("ELM_CONNECT_BLESS").is_some_and(|v| v == "1")
}

fn unified_diff(path: &str, expected: &str, actual: &str) -> String {
    TextDiff::from_lines(expected, actual)
        .unified_diff()
        .context_radius(3)
        .header(&format!("expected/{path}"), &format!("generated/{path}"))
        .to_string()
}

// The checks, each over one case. `Err` is the failure report.

/// The generated modules of `case` are its expected `.elm` files, byte for
/// byte, no more and no fewer, or for a focused case its excerpt is its
/// expected `focused.txt`; its warnings are its expected `warnings.txt`,
/// which is absent when there are none. Blessing rewrites `expected/`
/// instead. A focus list naming what the case does not generate fails,
/// also when blessing.
fn check_golden(case: &Path, bless: bool) -> Result<(), String> {
    let run = run_generator(case).map_err(|rendered| {
        format!(
            "generating failed; to expect that, put an empty expected/{DIAGNOSTICS} in the \
             case and bless it:\n{rendered}"
        )
    })?;
    let expected_dir = case.join("expected");
    let generated: BTreeMap<String, String> = run
        .files
        .into_iter()
        .map(|file| (file.path, placeholder_header(&file.content)))
        .collect();
    let mut problems = match case_focus(case) {
        None => check_modules(&expected_dir, &generated, bless),
        Some(focus) => check_excerpt(&expected_dir, &focus?, &generated, bless)?,
    };
    problems.extend(check_warnings(&expected_dir, &run.warnings, bless));
    if problems.is_empty() {
        Ok(())
    } else {
        Err(problems.join("\n"))
    }
}

/// The modules in `expected_dir` are `generated`, or blessing writes them.
fn check_modules(
    expected_dir: &Path,
    generated: &BTreeMap<String, String>,
    bless: bool,
) -> Vec<String> {
    let expected: BTreeMap<String, String> = files_under(expected_dir)
        .into_iter()
        .filter(|path| path != WARNINGS)
        .map(|path| {
            let text = fs::read_to_string(expected_dir.join(&path)).expect("read an expected file");
            (path, text)
        })
        .collect();
    if bless {
        for path in expected.keys().filter(|p| !generated.contains_key(*p)) {
            fs::remove_file(expected_dir.join(path)).expect("remove a stale expected file");
        }
        for (path, content) in generated {
            let target = expected_dir.join(path);
            fs::create_dir_all(target.parent().expect("a file has a parent"))
                .expect("create an expected directory");
            fs::write(&target, content).expect("write an expected file");
        }
        return Vec::new();
    }
    let mut problems = Vec::new();
    for path in expected.keys().filter(|p| !generated.contains_key(*p)) {
        problems.push(format!("expected/{path} is not generated"));
    }
    for (path, content) in generated {
        match expected.get(path) {
            None => problems.push(format!("{path} is generated but not expected")),
            Some(want) if want != content => problems.push(unified_diff(path, want, content)),
            Some(_) => {}
        }
    }
    problems
}

/// `expected_dir` holds `focused.txt`, the excerpt `focus` keeps of
/// `generated`, and no module, or blessing writes it and removes them.
/// `Err` when `focus` names what is not generated.
fn check_excerpt(
    expected_dir: &Path,
    focus: &Focus,
    generated: &BTreeMap<String, String>,
    bless: bool,
) -> Result<Vec<String>, String> {
    let text = excerpt(focus, generated).map_err(|stale| stale.join("\n"))?;
    let path = expected_dir.join(FOCUSED);
    let left: Vec<String> = files_under(expected_dir)
        .into_iter()
        .filter(|p| p != WARNINGS && p != FOCUSED)
        .collect();
    if bless {
        for p in &left {
            fs::remove_file(expected_dir.join(p)).expect("remove an expected module");
        }
        remove_empty_dirs(expected_dir);
        fs::create_dir_all(expected_dir).expect("create expected/");
        fs::write(&path, &text).expect("write focused.txt");
        return Ok(Vec::new());
    }
    let mut problems: Vec<String> = left
        .iter()
        .map(|p| {
            format!(
                "expected/{p} is left over: the case has a {FOCUS}, so only expected/{FOCUSED} \
                 is compared; bless to remove it"
            )
        })
        .collect();
    match fs::read_to_string(&path) {
        Ok(want) if want != text => problems.push(unified_diff(FOCUSED, &want, &text)),
        Ok(_) => {}
        Err(e) if e.kind() == ErrorKind::NotFound => {
            problems.push(format!("expected/{FOCUSED} is absent; bless to write it"));
        }
        Err(e) => panic!("read {}: {e}", path.display()),
    }
    Ok(problems)
}

/// Removes the empty directories under `dir`, not `dir` itself.
fn remove_empty_dirs(dir: &Path) {
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    for entry in entries {
        let path = entry.expect("read a directory entry").path();
        if path.is_dir() {
            remove_empty_dirs(&path);
            let _ = fs::remove_dir(&path);
        }
    }
}

/// The warnings are the expected `warnings.txt`, absent for none, or
/// blessing writes or removes it.
fn check_warnings(expected_dir: &Path, warnings: &str, bless: bool) -> Vec<String> {
    let warnings_path = expected_dir.join(WARNINGS);
    let expected_warnings = match fs::read_to_string(&warnings_path) {
        Ok(text) => Some(text),
        Err(e) if e.kind() == ErrorKind::NotFound => None,
        Err(e) => panic!("read {}: {e}", warnings_path.display()),
    };
    if bless {
        if warnings.is_empty() {
            if expected_warnings.is_some() {
                fs::remove_file(&warnings_path).expect("remove a stale warnings.txt");
            }
        } else {
            fs::write(&warnings_path, warnings).expect("write warnings.txt");
        }
        return Vec::new();
    }
    let mut problems = Vec::new();
    match (expected_warnings, warnings.is_empty()) {
        (None, true) => {}
        (None, false) => problems.push(format!(
            "generating warns, but expected/{WARNINGS} is absent:\n{warnings}"
        )),
        (Some(_), true) => problems.push(format!(
            "expected/{WARNINGS} is present, but generating does not warn"
        )),
        (Some(want), false) if want != warnings => {
            problems.push(unified_diff(WARNINGS, &want, warnings));
        }
        (Some(_), false) => {}
    }
    problems
}

/// Generating `case` fails, rendering exactly its expected
/// `diagnostics.txt`. Blessing rewrites that file instead.
fn check_diagnostics(case: &Path, bless: bool) -> Result<(), String> {
    let rendered = match run_generator(case) {
        Ok(run) => {
            let paths: Vec<_> = run.files.into_iter().map(|file| file.path).collect();
            return Err(format!(
                "expected problems, but generating succeeded with {}",
                paths.join(", ")
            ));
        }
        Err(rendered) => rendered,
    };
    let path = case.join("expected").join(DIAGNOSTICS);
    if bless {
        fs::write(&path, &rendered).expect("write diagnostics.txt");
        return Ok(());
    }
    let want = fs::read_to_string(&path).expect("read diagnostics.txt");
    if want == rendered {
        Ok(())
    } else {
        Err(unified_diff(DIAGNOSTICS, &want, &rendered))
    }
}

/// Runs `check` over `cases`, failing with every case's report.
fn over_cases(cases: &[PathBuf], check: impl Fn(&Path) -> Result<(), String>) {
    let failures: Vec<String> = cases
        .iter()
        .filter_map(|case| {
            check(case)
                .err()
                .map(|report| format!("case `{}`:\n{report}", case_name(case)))
        })
        .collect();
    assert!(failures.is_empty(), "\n{}", failures.join("\n\n"));
}

// Running the tools.

fn run(cmd: &mut Command) -> Output {
    let program = cmd.get_program().to_string_lossy().into_owned();
    match cmd.stdin(Stdio::null()).output() {
        Ok(output) => output,
        Err(e) if e.kind() == ErrorKind::NotFound => panic!(
            "`{program}` is not on PATH. It is pinned in mise.toml: run `mise install` and \
             run the tests through mise (`just test`, or `mise exec -- cargo test`)."
        ),
        Err(e) => panic!("could not start `{program}`: {e}"),
    }
}

fn output_text(output: &Output) -> String {
    format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    )
}

/// The whole Elm modules of an output case, by path under `expected/`:
/// its expected modules, or for a focused case, which holds only an
/// excerpt, what generating it gives now. The compiles and formatted
/// checks take these.
fn whole_modules(case: &Path) -> Result<Vec<(String, String)>, String> {
    if case_focus(case).is_none() {
        let expected = case.join("expected");
        return Ok(files_under(&expected)
            .into_iter()
            .filter(|path| path.ends_with(".elm"))
            .map(|path| {
                let text =
                    fs::read_to_string(expected.join(&path)).expect("read an expected module");
                (path, text)
            })
            .collect());
    }
    let run = run_generator(case).map_err(|rendered| format!("generating failed:\n{rendered}"))?;
    Ok(run
        .files
        .into_iter()
        .map(|file| (file.path, placeholder_header(&file.content)))
        .collect())
}

/// Writes `modules` under `dir`, emptied first.
fn write_modules(dir: &Path, modules: &[(String, String)]) {
    let _ = fs::remove_dir_all(dir);
    for (path, content) in modules {
        let target = dir.join(path);
        fs::create_dir_all(target.parent().expect("a file has a parent"))
            .expect("create a directory");
        fs::write(&target, content).expect("write a module");
    }
}

fn output_cases() -> Vec<PathBuf> {
    cases()
        .into_iter()
        .filter(|case| !is_diagnostics_case(case))
        .collect()
}

// The tests.

#[test]
fn golden() {
    let bless = blessing();
    over_cases(&output_cases(), |case| check_golden(case, bless));
}

#[test]
fn diagnostics() {
    let cases: Vec<_> = cases()
        .into_iter()
        .filter(|c| is_diagnostics_case(c))
        .collect();
    let bless = blessing();
    over_cases(&cases, |case| check_diagnostics(case, bless));
}

/// Each case's whole modules ([`whole_modules`]) compile in
/// `conformance/harness`, whose source directories are the runtime
/// package's `src/` and a scratch `generated/`. Cases are compiled one at
/// a time because two cases may define the same module.
#[test]
fn compiles() {
    let harness = repo_root().join("conformance/harness");
    let scratch = harness.join("generated");
    // A bare `elm make` resolves and writes the dependencies before the
    // real build, avoiding the first-build d.dat race the Justfile
    // describes. It fails for want of input files; that is expected.
    let _ = fs::create_dir_all(&scratch);
    let _ = run(Command::new("elm").arg("make").current_dir(&harness));
    let mut failures = Vec::new();
    for case in output_cases() {
        let modules = match whole_modules(&case) {
            Ok(modules) => modules,
            Err(report) => {
                failures.push(format!("case `{}`:\n{report}", case_name(&case)));
                continue;
            }
        };
        write_modules(&scratch, &modules);
        let build = run(Command::new("elm")
            .arg("make")
            .args(
                modules
                    .iter()
                    .map(|(path, _)| Path::new("generated").join(path)),
            )
            .arg("--output=/dev/null")
            .current_dir(&harness));
        if !build.status.success() {
            failures.push(format!(
                "case `{}`:\n{}",
                case_name(&case),
                output_text(&build)
            ));
        }
    }
    let _ = fs::remove_dir_all(&scratch);
    assert!(
        failures.is_empty(),
        "elm make rejected the corpus's output:\n{}",
        failures.join("\n\n")
    );
}

/// `elm-format --validate` accepts each case's whole modules: the expected
/// modules in place, and a focused case's, generated afresh, from a
/// scratch directory named after the case.
#[test]
fn formatted() {
    let scratch = Path::new(env!("CARGO_TARGET_TMPDIR")).join("conformance-formatted");
    let _ = fs::remove_dir_all(&scratch);
    let mut files: Vec<PathBuf> = Vec::new();
    for case in output_cases() {
        if case_focus(&case).is_none() {
            let expected = case.join("expected");
            files.extend(
                files_under(&expected)
                    .into_iter()
                    .filter(|path| path.ends_with(".elm"))
                    .map(|path| expected.join(path)),
            );
        } else {
            let modules = whole_modules(&case)
                .unwrap_or_else(|report| panic!("case `{}`: {report}", case_name(&case)));
            let dir = scratch.join(case_name(&case));
            write_modules(&dir, &modules);
            files.extend(modules.iter().map(|(path, _)| dir.join(path)));
        }
    }
    assert!(!files.is_empty(), "the corpus has no modules");
    let validate = run(Command::new("elm-format").arg("--validate").args(&files));
    assert!(
        validate.status.success(),
        "elm-format --validate rejected the corpus's output:\n{}",
        output_text(&validate)
    );
}

/// Writes each focused case's whole modules, generated afresh, under
/// `conformance/harness/full/<case>/` (gitignored), where
/// `conformance/compile-with.sh` compiles them with another Elm compiler,
/// as it compiles the other cases' expected modules.
#[test]
fn the_focused_cases_are_written_whole() {
    let full = repo_root().join("conformance/harness/full");
    let _ = fs::remove_dir_all(&full);
    for case in output_cases()
        .iter()
        .filter(|case| case_focus(case).is_some())
    {
        let modules = whole_modules(case)
            .unwrap_or_else(|report| panic!("case `{}`: {report}", case_name(case)));
        write_modules(&full.join(case_name(case)), &modules);
    }
}

/// The diagnostics mechanism on a throwaway case, for the paths the corpus
/// never takes: a mismatch fails with a diff, blessing writes the
/// rendering, a case that generates fails.
#[test]
fn diagnostics_cases_compare_and_bless() {
    let case = Path::new(env!("CARGO_TARGET_TMPDIR")).join("conformance-diagnostics-case");
    let _ = fs::remove_dir_all(&case);
    fs::create_dir_all(case.join("input")).expect("create input");
    fs::create_dir_all(case.join("expected")).expect("create expected");
    fs::write(
        case.join("input/clash.proto"),
        "syntax = \"proto3\";\n\npackage clash.v1;\n\nmessage Note {\n  \
         string display_name = 1;\n  oneof displayName {\n    string text = 2;\n  }\n}\n",
    )
    .expect("write input");
    let expected = case.join("expected").join(DIAGNOSTICS);
    fs::write(&expected, "").expect("write diagnostics.txt");

    let report = check_diagnostics(&case, false).expect_err("an empty expectation differs");
    assert!(report.contains("+naming::field_collision"), "{report}");

    check_diagnostics(&case, true).expect("blessing passes");
    let blessed = fs::read_to_string(&expected).expect("read diagnostics.txt");
    assert!(
        blessed.starts_with("naming::field_collision\n"),
        "{blessed}"
    );
    assert!(blessed.contains("╭─[clash.proto:6:"), "{blessed}");
    check_diagnostics(&case, false).expect("the blessed rendering matches");

    fs::write(
        case.join("input/clash.proto"),
        "syntax = \"proto3\";\n\npackage clash.v1;\n\nmessage Note {}\n",
    )
    .expect("write input");
    let report = check_diagnostics(&case, false).expect_err("generating succeeds");
    assert!(report.contains("Clash/V1.elm"), "{report}");
}

/// The warnings mechanism on a throwaway case: a run that warns without a
/// `warnings.txt` fails, blessing writes it, and a run that stops warning
/// fails until blessing removes it.
#[test]
fn warnings_compare_and_bless() {
    let case = Path::new(env!("CARGO_TARGET_TMPDIR")).join("conformance-warnings-case");
    let _ = fs::remove_dir_all(&case);
    fs::create_dir_all(case.join("input")).expect("create input");
    fs::create_dir_all(case.join("expected")).expect("create expected");
    fs::write(case.join(OPTIONS), "streaming=skip\n").expect("write options.txt");
    let streaming = "syntax = \"proto3\";\n\npackage feed.v1;\n\nmessage Item {}\n\n\
                     service Feed {\n  rpc Get(Item) returns (Item);\n  \
                     rpc Watch(Item) returns (stream Item);\n}\n";
    fs::write(case.join("input/feed.proto"), streaming).expect("write input");
    let warnings = case.join("expected").join(WARNINGS);

    check_golden(&case, true).expect("blessing passes");
    let blessed = fs::read_to_string(&warnings).expect("read warnings.txt");
    assert!(blessed.starts_with("services::streaming\n"), "{blessed}");
    assert!(blessed.contains("╭─[feed.proto:9:"), "{blessed}");
    check_golden(&case, false).expect("the blessed output matches");

    fs::remove_file(&warnings).expect("remove warnings.txt");
    let report = check_golden(&case, false).expect_err("the warning is unexpected");
    assert!(report.contains("warnings.txt is absent"), "{report}");

    check_golden(&case, true).expect("blessing passes");
    fs::write(
        case.join("input/feed.proto"),
        streaming.replace("stream Item", "Item"),
    )
    .expect("write input");
    let report = check_golden(&case, false).expect_err("the warning is gone");
    assert!(report.contains("does not warn"), "{report}");
    check_golden(&case, true).expect("blessing passes");
    assert!(!warnings.exists(), "blessing removes a stale warnings.txt");
}

#[test]
fn the_header_names_a_placeholder_version() {
    let mut parts = VERSION.split('.');
    let (major, minor) = (parts.next().unwrap(), parts.next().unwrap());
    let header = format!("-- {HEADER_PREFIX}{VERSION} from a.proto. Do not edit.\nmodule A\n");
    assert_eq!(
        placeholder_header(&header),
        format!(
            "-- Generated by elm-connect {major}.{minor}.X from a.proto. Do not edit.\nmodule A\n"
        )
    );
    let elsewhere = format!("module A\n-- {HEADER_PREFIX}{VERSION} from a.proto.\n");
    assert_eq!(placeholder_header(&elsewhere), elsewhere);
}

/// The names of a split, in order, `-` for an unnamed piece.
fn piece_names(text: &str) -> Vec<String> {
    split_module(text)
        .into_iter()
        .map(|(name, _)| name.unwrap_or_else(|| "-".into()))
        .collect()
}

#[test]
fn a_module_splits_into_its_declarations() {
    let module = "\
-- Generated by elm-connect 0.2.X from a.proto. Do not edit; regenerate instead.
-- Options: defaults


module A exposing (..)

{-| The module's doc.

At column 0 after a blank line, inside the comment.

-}

import Json.Decode


-- TYPES


{-| A type, with {- a nested -} comment.

type NotADeclaration

-}
type Shape
    = Round
    | Square


type alias Pair =
    { left : Int, right : Int }


quoted : String
quoted =
    \"{- not a comment\"


braces : Char
braces =
    '\"'


long : String
long =
    \"\"\"
first

notADeclaration = 1
\"\"\"


{-| Last, with trailing blank lines.
-}
last : Int
last =
    1


";
    assert_eq!(
        piece_names(module),
        [
            "-", "module", "import", "-", "Shape", "Pair", "quoted", "braces", "long", "last"
        ]
    );
    let pieces = split_module(module);
    let piece = |name: &str| {
        pieces
            .iter()
            .find(|(n, _)| n.as_deref() == Some(name))
            .map(|(_, text)| text.as_str())
            .unwrap_or_else(|| panic!("no {name}"))
    };
    assert_eq!(
        piece("module"),
        "module A exposing (..)\n\n{-| The module's doc.\n\nAt column 0 after a blank line, \
         inside the comment.\n\n-}"
    );
    assert!(
        piece("Shape").starts_with("{-| A type,"),
        "{}",
        piece("Shape")
    );
    assert!(
        piece("Shape").ends_with("    | Square"),
        "{}",
        piece("Shape")
    );
    assert!(
        piece("long").ends_with("notADeclaration = 1\n\"\"\""),
        "{}",
        piece("long")
    );
    assert_eq!(
        piece("last"),
        "{-| Last, with trailing blank lines.\n-}\nlast : Int\nlast =\n    1"
    );
}

/// Over every module the corpus holds or generates: the pieces keep every
/// non-blank line once, in order, their names are distinct, and every
/// value annotated at column 0 is a piece of its own, so no declaration is
/// glued to the one before it.
#[test]
fn every_corpus_module_splits_cleanly() {
    let mut modules = 0;
    for case in output_cases() {
        let whole = whole_modules(&case).unwrap_or_else(|report| panic!("{report}"));
        for (path, text) in whole {
            modules += 1;
            let at = format!("{}: {path}", case_name(&case));
            let pieces = split_module(&text);
            let kept: Vec<&str> = pieces
                .iter()
                .flat_map(|(_, piece)| piece.lines())
                .filter(|line| !line.trim().is_empty())
                .collect();
            let all: Vec<&str> = text
                .lines()
                .filter(|line| !line.trim().is_empty())
                .collect();
            assert_eq!(kept, all, "{at}");
            let mut names: Vec<&str> = pieces.iter().filter_map(|(n, _)| n.as_deref()).collect();
            names.sort_unstable();
            let count = names.len();
            names.dedup();
            assert_eq!(names.len(), count, "{at}: a name names two pieces");
            for line in text.lines() {
                if let Some((name, _)) = line.split_once(" : ")
                    && name.starts_with(|c: char| c.is_ascii_lowercase())
                    && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
                {
                    assert!(
                        names.contains(&name),
                        "{at}: `{name}` is not a piece of its own"
                    );
                }
            }
        }
    }
    assert!(modules > 200, "only {modules} modules");
}

#[test]
fn a_focus_list_reads_modules_and_declarations() {
    let focus = parse_focus(
        "# A comment.\n\nA/V1.elm module Shape  # kept in this order\nA/V1/Note.elm\nA/V1.elm decodeShape\n",
    )
    .expect("a valid list");
    assert_eq!(
        focus,
        [
            (
                "A/V1.elm".to_owned(),
                Keep::Declarations(vec!["module".into(), "Shape".into(), "decodeShape".into()])
            ),
            ("A/V1/Note.elm".to_owned(), Keep::Module),
        ]
    );
    let problem = |text: &str| parse_focus(text).expect_err(text);
    assert!(problem("# nothing\n").contains("names no module"));
    assert!(problem("A.V1 Shape\n").contains("not a module's path"));
    assert!(
        problem("A/V1.elm Shape\nA/V1.elm Shape\n").contains("`Shape` in A/V1.elm is named twice")
    );
    assert!(problem("A/V1.elm Shape Shape\n").contains("named twice"));
    assert!(problem("A/V1.elm\nA/V1.elm\n").contains("A/V1.elm is named twice"));
    assert!(problem("A/V1.elm\nA/V1.elm Shape\n").contains("whole and also by declaration"));
    assert!(problem("A/V1.elm Shape\nA/V1.elm\n").contains("line 2: A/V1.elm is kept whole"));
}

/// The focused mechanism on a throwaway case: blessing writes the excerpt
/// in place of the modules; a change to a focused declaration fails with a
/// diff, a change elsewhere passes; a focus list naming what is not
/// generated fails, blessing or not; the compiles and formatted checks'
/// modules are the whole output.
#[test]
fn focused_cases_compare_and_bless() {
    let case = Path::new(env!("CARGO_TARGET_TMPDIR")).join("conformance-focused-case");
    let _ = fs::remove_dir_all(&case);
    fs::create_dir_all(case.join("input")).expect("create input");
    let proto = "syntax = \"proto3\";\n\npackage notes.v1;\n\n// How a note reads.\nenum Tone {\n  \
                 TONE_UNSPECIFIED = 0;\n  TONE_DRY = 1;\n}\n\nmessage Note {\n  string title = 1;\n}\n";
    fs::write(case.join("input/notes.proto"), proto).expect("write input");
    check_golden(&case, true).expect("blessing an unfocused case passes");
    assert!(case.join("expected/Notes/V1.elm").is_file());

    fs::write(
        case.join(FOCUS),
        "Notes/V1.elm Tone decodeTone\nNotes/V1/Note.elm\n",
    )
    .expect("write focus.txt");
    let report = check_golden(&case, false).expect_err("the modules are left over");
    assert!(
        report.contains("expected/Notes/V1.elm is left over"),
        "{report}"
    );
    assert!(
        report.contains("expected/focused.txt is absent"),
        "{report}"
    );

    check_golden(&case, true).expect("blessing passes");
    assert_eq!(files_under(&case.join("expected")), [FOCUSED]);
    let focused =
        fs::read_to_string(case.join("expected").join(FOCUSED)).expect("read focused.txt");
    assert!(
        focused.starts_with("-- An excerpt, not a module: what ../focus.txt names"),
        "{focused}"
    );
    assert!(
        focused.contains("--   Notes/V1.elm\n--   Notes/V1/Note.elm\n--   Notes/V1/Tone.elm\n"),
        "{focused}"
    );
    assert!(
        focused.contains("\n\n-- Notes/V1.elm: Tone\n\n{-| How a note reads."),
        "{focused}"
    );
    assert!(
        focused.contains("\n\n-- Notes/V1.elm: decodeTone\n\n"),
        "{focused}"
    );
    assert!(
        focused.contains("\n\n-- Notes/V1/Note.elm, whole\n\n-- Generated by elm-connect"),
        "{focused}"
    );
    assert!(!focused.contains("encodeTone"), "{focused}");
    check_golden(&case, false).expect("the blessed excerpt matches");

    // Outside the focus: a new field changes the record, its codecs and
    // the descriptor module, none of them focused.
    let wider = proto.replace("string title = 1;", "string title = 1;\n  int32 stars = 2;");
    fs::write(case.join("input/notes.proto"), &wider).expect("write input");
    let report = check_golden(&case, false).expect_err("the whole Note.elm is focused");
    assert!(
        report.contains("+stars : Proto.Field.Descriptor"),
        "{report}"
    );
    fs::write(case.join(FOCUS), "Notes/V1.elm Tone decodeTone\n").expect("write focus.txt");
    check_golden(&case, true).expect("blessing passes");
    fs::write(
        case.join("input/notes.proto"),
        wider.replace("int32 stars", "int64 stars"),
    )
    .expect("write input");
    check_golden(&case, false).expect("a change outside the focus passes");

    // Inside it.
    fs::write(
        case.join("input/notes.proto"),
        wider.replace("TONE_DRY", "TONE_WRY"),
    )
    .expect("write input");
    let report = check_golden(&case, false).expect_err("a focused declaration changed");
    assert!(report.contains("--- expected/focused.txt"), "{report}");
    assert!(report.contains("-    | ToneDry"), "{report}");
    assert!(report.contains("+    | ToneWry"), "{report}");

    // A stale focus list.
    fs::write(
        case.join(FOCUS),
        "Notes/V1.elm Tone decodeMood\nNotes/V2.elm\n",
    )
    .expect("write focus.txt");
    for bless in [false, true] {
        let report = check_golden(&case, bless).expect_err("the list is stale");
        assert!(
            report.contains(
                "focus.txt names `decodeMood` in Notes/V1.elm, which does not declare it"
            ),
            "{report}"
        );
        assert!(
            report.contains("focus.txt names Notes/V2.elm, which this case does not generate"),
            "{report}"
        );
    }

    let whole = whole_modules(&case).expect("the case generates");
    let paths: Vec<&str> = whole.iter().map(|(path, _)| path.as_str()).collect();
    assert_eq!(
        paths,
        ["Notes/V1.elm", "Notes/V1/Note.elm", "Notes/V1/Tone.elm"]
    );
    assert!(whole[0].1.contains("| ToneWry"));

    // Unfocusing: blessing puts the modules back.
    fs::remove_file(case.join(FOCUS)).expect("remove focus.txt");
    let report = check_golden(&case, false).expect_err("focused.txt is stale");
    assert!(
        report.contains("expected/focused.txt is not generated"),
        "{report}"
    );
    check_golden(&case, true).expect("blessing passes");
    assert!(!case.join("expected").join(FOCUSED).exists());
    assert!(case.join("expected/Notes/V1.elm").is_file());
}
