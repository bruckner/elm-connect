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
//! With `ELM_CONNECT_BLESS=1` the golden and diagnostics tests rewrite
//! `expected/` to match the generator and pass; `just bless` does that.
//!
//! Expected modules carry `0.1.X` (the major and minor version, `X` for
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
use common::{
    Compiled, DIAGNOSTICS, OPTIONS, WARNINGS, case_name, case_options, cases, compile_case,
    files_under, front_end_case, is_diagnostics_case, placeholder_header, protos, repo_root,
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
///
/// A case whose input protox refuses for an edition it cannot parse or
/// for names that break the naming style gives the problems the CLI
/// reports in place of protox's errors.
fn run_generator(case: &Path) -> Result<Run, String> {
    if let Some(mut diagnostics) = front_end_case(case) {
        let input = case.join("input");
        let sources: HashMap<String, String> = protos(&input)
            .into_iter()
            .map(|name| {
                let text = fs::read_to_string(input.join(&name)).expect("read a proto");
                (name, text)
            })
            .collect();
        diagnostics.attach_sources(&sources, Columns::Bytes);
        return Err(render_narrow(&diagnostics));
    }
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
/// byte, no more and no fewer, and its warnings are its expected
/// `warnings.txt`, which is absent when there are none. Blessing rewrites
/// `expected/` instead.
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
    let expected: BTreeMap<String, String> = files_under(&expected_dir)
        .into_iter()
        .filter(|path| path != WARNINGS)
        .map(|path| {
            let text = fs::read_to_string(expected_dir.join(&path)).expect("read an expected file");
            (path, text)
        })
        .collect();
    let warnings_path = expected_dir.join(WARNINGS);
    let expected_warnings = match fs::read_to_string(&warnings_path) {
        Ok(text) => Some(text),
        Err(e) if e.kind() == ErrorKind::NotFound => None,
        Err(e) => panic!("read {}: {e}", warnings_path.display()),
    };
    if bless {
        for path in expected.keys().filter(|p| !generated.contains_key(*p)) {
            fs::remove_file(expected_dir.join(path)).expect("remove a stale expected file");
        }
        for (path, content) in &generated {
            let target = expected_dir.join(path);
            fs::create_dir_all(target.parent().expect("a file has a parent"))
                .expect("create an expected directory");
            fs::write(&target, content).expect("write an expected file");
        }
        if run.warnings.is_empty() {
            if expected_warnings.is_some() {
                fs::remove_file(&warnings_path).expect("remove a stale warnings.txt");
            }
        } else {
            fs::write(&warnings_path, &run.warnings).expect("write warnings.txt");
        }
        return Ok(());
    }
    let mut problems = Vec::new();
    for path in expected.keys().filter(|p| !generated.contains_key(*p)) {
        problems.push(format!("expected/{path} is not generated"));
    }
    for (path, content) in &generated {
        match expected.get(path) {
            None => problems.push(format!("{path} is generated but not expected")),
            Some(want) if want != content => problems.push(unified_diff(path, want, content)),
            Some(_) => {}
        }
    }
    match (expected_warnings, run.warnings.is_empty()) {
        (None, true) => {}
        (None, false) => problems.push(format!(
            "generating warns, but expected/{WARNINGS} is absent:\n{}",
            run.warnings
        )),
        (Some(_), true) => problems.push(format!(
            "expected/{WARNINGS} is present, but generating does not warn"
        )),
        (Some(want), false) if want != run.warnings => {
            problems.push(unified_diff(WARNINGS, &want, &run.warnings));
        }
        (Some(_), false) => {}
    }
    if problems.is_empty() {
        Ok(())
    } else {
        Err(problems.join("\n"))
    }
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

/// The expected Elm modules of every output case: case, path under
/// `expected/`, file.
fn expected_modules() -> Vec<(PathBuf, String, PathBuf)> {
    cases()
        .into_iter()
        .filter(|case| !is_diagnostics_case(case))
        .flat_map(|case| {
            let expected = case.join("expected");
            files_under(&expected)
                .into_iter()
                .filter(|path| path.ends_with(".elm"))
                .map(|path| {
                    let file = expected.join(&path);
                    (case.clone(), path, file)
                })
                .collect::<Vec<_>>()
        })
        .collect()
}

// The tests.

#[test]
fn golden() {
    let cases: Vec<_> = cases()
        .into_iter()
        .filter(|case| !is_diagnostics_case(case))
        .collect();
    let bless = blessing();
    over_cases(&cases, |case| check_golden(case, bless));
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

/// Each case's expected modules compile in `conformance/harness`, whose
/// source directories are the runtime package's `src/` and a scratch
/// `generated/`. Cases are compiled one at a time because two cases may
/// define the same module.
#[test]
fn compiles() {
    let harness = repo_root().join("conformance/harness");
    let scratch = harness.join("generated");
    let mut by_case: BTreeMap<PathBuf, Vec<String>> = BTreeMap::new();
    for (case, path, _) in expected_modules() {
        by_case.entry(case).or_default().push(path);
    }
    // A bare `elm make` resolves and writes the dependencies before the
    // real build, avoiding the first-build d.dat race the Justfile
    // describes. It fails for want of input files; that is expected.
    let _ = fs::create_dir_all(&scratch);
    let _ = run(Command::new("elm").arg("make").current_dir(&harness));
    let mut failures = Vec::new();
    for (case, paths) in &by_case {
        let _ = fs::remove_dir_all(&scratch);
        for path in paths {
            let target = scratch.join(path);
            fs::create_dir_all(target.parent().expect("a file has a parent"))
                .expect("create a scratch directory");
            fs::copy(case.join("expected").join(path), &target).expect("copy an expected module");
        }
        let build = run(Command::new("elm")
            .arg("make")
            .args(paths.iter().map(|path| Path::new("generated").join(path)))
            .arg("--output=/dev/null")
            .current_dir(&harness));
        if !build.status.success() {
            failures.push(format!(
                "case `{}`:\n{}",
                case_name(case),
                output_text(&build)
            ));
        }
    }
    let _ = fs::remove_dir_all(&scratch);
    assert!(
        failures.is_empty(),
        "elm make rejected expected output:\n{}",
        failures.join("\n\n")
    );
}

#[test]
fn formatted() {
    let files: Vec<PathBuf> = expected_modules()
        .into_iter()
        .map(|(_, _, file)| file)
        .collect();
    assert!(!files.is_empty(), "the corpus has no expected modules");
    let validate = run(Command::new("elm-format").arg("--validate").args(&files));
    assert!(
        validate.status.success(),
        "elm-format --validate rejected expected output:\n{}",
        output_text(&validate)
    );
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

/// An edition 2023 or 2024 file that only restates proto3 in features
/// generates what its proto3 twin does: `editions_2023_proto3_equivalent`
/// and `editions_2024_proto3_equivalent` hold the twins of `codec_both`'s
/// inputs, with its options, and their expected modules are
/// `codec_both`'s, byte for byte. The golden test holds each case to the
/// generator, so the two together hold the generator to this.
#[test]
fn the_proto3_equivalent_editions_generate_their_twin() {
    for edition in ["2023", "2024"] {
        proto3_equivalent_edition_generates_its_twin(edition);
    }
}

fn proto3_equivalent_edition_generates_its_twin(edition: &str) {
    let cases = repo_root().join("conformance/cases");
    let twin = cases.join(format!("editions_{edition}_proto3_equivalent"));
    let proto3 = cases.join("codec_both");
    assert_eq!(
        read(&twin.join(OPTIONS)),
        read(&proto3.join(OPTIONS)),
        "the twin takes the proto3 case's options"
    );
    for name in protos(&twin.join("input")) {
        let source = read(&twin.join("input").join(&name));
        assert!(
            source.contains(&format!("\nedition = \"{edition}\";\n"))
                && !source.contains("syntax ="),
            "{name} is an edition {edition} file"
        );
    }
    let modules = |case: &Path| -> BTreeMap<String, String> {
        let expected = case.join("expected");
        files_under(&expected)
            .into_iter()
            .map(|path| {
                let text = read(&expected.join(&path));
                (path, text)
            })
            .collect()
    };
    let (twin_modules, proto3_modules) = (modules(&twin), modules(&proto3));
    assert!(!proto3_modules.is_empty());
    assert_eq!(
        twin_modules.keys().collect::<Vec<_>>(),
        proto3_modules.keys().collect::<Vec<_>>(),
        "the same modules"
    );
    for (path, text) in &proto3_modules {
        if twin_modules[path] != *text {
            panic!(
                "{path} differs from its proto3 twin:\n{}",
                unified_diff(path, text, &twin_modules[path])
            );
        }
    }
}

/// Visibility decides which files may use a type, not what is generated:
/// `editions_2024_visibility` generates the same modules with its `export`
/// and `local` modifiers and its `default_symbol_visibility` removed.
#[test]
fn visibility_does_not_change_the_generated_modules() {
    let case = repo_root().join("conformance/cases/editions_2024_visibility");
    let stripped = Path::new(env!("CARGO_TARGET_TMPDIR")).join("visibility-stripped-case");
    let _ = fs::remove_dir_all(&stripped);
    fs::create_dir_all(stripped.join("input")).expect("create the case");
    let mut changed = 0;
    for name in protos(&case.join("input")) {
        let source = read(&case.join("input").join(&name));
        let without: String = source
            .lines()
            .filter(|line| !line.contains("default_symbol_visibility"))
            .map(|line| {
                let indent = line.len() - line.trim_start().len();
                let rest = &line[indent..];
                let rest = rest
                    .strip_prefix("export ")
                    .or_else(|| rest.strip_prefix("local "))
                    .unwrap_or(rest);
                format!("{}{rest}\n", &line[..indent])
            })
            .collect();
        changed += usize::from(without != source);
        fs::write(stripped.join("input").join(&name), without).expect("write the proto");
    }
    assert_eq!(changed, 2, "both files carry visibility");
    let files = |case: &Path| -> Vec<(String, String)> {
        let run = run_generator(case).unwrap_or_else(|rendered| panic!("{rendered}"));
        run.files
            .into_iter()
            .map(|file| (file.path, file.content))
            .collect()
    };
    assert_eq!(files(&case), files(&stripped));
}

fn read(path: &Path) -> String {
    fs::read_to_string(path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()))
}
