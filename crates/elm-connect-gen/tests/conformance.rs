//! The conformance corpus (design §7, `conformance/README.md`): every case
//! under `conformance/cases/` regenerates to its expected output, and that
//! output compiles against the runtime package and is in elm-format's
//! layout.
//!
//! A case is `input/` (proto files, compiled with protox and all
//! generated), an optional `include/` (protos the input may import, not
//! generated) and `expected/`, holding either the Elm modules generated
//! from the input, at their module paths, or `diagnostics.txt`, the
//! narrow rendering of the problems generating reports instead. An
//! optional `options.txt` holds the generator's options as a protoc plugin
//! parameter.
//!
//! With `ELM_CONNECT_BLESS=1` the golden and diagnostics tests rewrite
//! `expected/` to match the generator and pass; `just bless` does that.
//!
//! The tools come from `mise.toml`; the tests fail, rather than skip, when
//! one is missing from PATH.

use std::collections::{BTreeMap, HashMap};
use std::fs;
use std::io::ErrorKind;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};

use elm_connect_gen::diagnostics::{Columns, render_narrow};
use elm_connect_gen::{GeneratedFile, Options, generate};
use similar::TextDiff;

/// The file in `expected/` that makes a case a diagnostics case.
const DIAGNOSTICS: &str = "diagnostics.txt";
/// The optional file in a case that sets the generator's options.
const OPTIONS: &str = "options.txt";

// The corpus.

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../..")
}

/// Every case directory, sorted by name.
fn cases() -> Vec<PathBuf> {
    let root = repo_root().join("conformance/cases");
    let mut cases: Vec<PathBuf> = fs::read_dir(&root)
        .unwrap_or_else(|e| panic!("read {}: {e}", root.display()))
        .map(|entry| entry.expect("read a case").path())
        .filter(|path| path.is_dir())
        .collect();
    cases.sort();
    assert!(!cases.is_empty(), "no cases under {}", root.display());
    cases
}

fn case_name(case: &Path) -> String {
    case.file_name()
        .expect("a case has a name")
        .to_string_lossy()
        .into_owned()
}

fn is_diagnostics_case(case: &Path) -> bool {
    case.join("expected").join(DIAGNOSTICS).is_file()
}

/// Every file under `dir`, as `/`-separated paths relative to it, sorted.
fn files_under(dir: &Path) -> Vec<String> {
    fn walk(root: &Path, dir: &Path, out: &mut Vec<String>) {
        let Ok(entries) = fs::read_dir(dir) else {
            return;
        };
        for entry in entries {
            let path = entry.expect("read a directory entry").path();
            if path.is_dir() {
                walk(root, &path, out);
            } else {
                let relative = path.strip_prefix(root).expect("under the root");
                let parts: Vec<_> = relative
                    .components()
                    .map(|c| c.as_os_str().to_string_lossy().into_owned())
                    .collect();
                out.push(parts.join("/"));
            }
        }
    }
    let mut out = Vec::new();
    walk(dir, dir, &mut out);
    out.sort();
    out
}

/// The generator options of `case`: its optional `options.txt`, a protoc
/// plugin parameter (`int64=int`) on one line, or the defaults.
fn case_options(case: &Path) -> Options {
    match fs::read_to_string(case.join(OPTIONS)) {
        Ok(text) => Options::from_parameter(text.trim())
            .unwrap_or_else(|e| panic!("{}: {e}", case.join(OPTIONS).display())),
        Err(e) if e.kind() == ErrorKind::NotFound => Options::default(),
        Err(e) => panic!("read {}: {e}", case.join(OPTIONS).display()),
    }
}

/// What generating a case's input gives: the files, or the narrow
/// rendering of the problems, with the proto sources attached. Protos in
/// the case's optional `include/` can be imported but are not generated.
/// The case's `options.txt`, if any, sets the generator's options.
fn run_generator(case: &Path) -> Result<Vec<GeneratedFile>, String> {
    let input = case.join("input");
    let include = case.join("include");
    let protos = |dir: &Path| -> Vec<String> {
        files_under(dir)
            .into_iter()
            .filter(|name| name.ends_with(".proto"))
            .collect()
    };
    let names = protos(&input);
    assert!(!names.is_empty(), "{} has no input protos", input.display());
    let mut include_paths = vec![input.clone()];
    if include.is_dir() {
        include_paths.push(include.clone());
    }
    let mut compiler = protox::Compiler::with_file_resolver(elm_connect_gen::googleapis::resolver(
        include_paths.clone(),
    ));
    compiler.include_source_info(true).include_imports(true);
    compiler
        .open_files(&names)
        .unwrap_or_else(|e| panic!("{} does not compile: {e:?}", input.display()));
    let generate_set: Vec<&str> = names.iter().map(String::as_str).collect();
    generate(
        &compiler.descriptor_pool(),
        &generate_set,
        &case_options(case),
    )
    .map_err(|mut diagnostics| {
        let mut sources = HashMap::new();
        for dir in &include_paths {
            for name in protos(dir) {
                let text = fs::read_to_string(dir.join(&name)).expect("read a proto");
                sources.entry(name).or_insert(text);
            }
        }
        diagnostics.attach_sources(&sources, Columns::Bytes);
        render_narrow(&diagnostics)
    })
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
/// byte, no more and no fewer. Blessing rewrites `expected/` instead.
fn check_golden(case: &Path, bless: bool) -> Result<(), String> {
    let generated = run_generator(case).map_err(|rendered| {
        format!(
            "generating failed; to expect that, put an empty expected/{DIAGNOSTICS} in the \
             case and bless it:\n{rendered}"
        )
    })?;
    let expected_dir = case.join("expected");
    let generated: BTreeMap<String, String> = generated
        .into_iter()
        .map(|file| (file.path, file.content))
        .collect();
    let expected: BTreeMap<String, String> = files_under(&expected_dir)
        .into_iter()
        .map(|path| {
            let text = fs::read_to_string(expected_dir.join(&path)).expect("read an expected file");
            (path, text)
        })
        .collect();
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
        Ok(files) => {
            let paths: Vec<_> = files.into_iter().map(|file| file.path).collect();
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
