//! The plugin as protoc runs it: the built binary, a `CodeGeneratorRequest`
//! on stdin, a `CodeGeneratorResponse` on stdout and warnings on stderr.
//!
//! Every case of the conformance corpus (`conformance/cases`) is sent as
//! the request protoc would send for it, and the response must carry the
//! case's expected modules, or its problems in `error`. The corpus's
//! warnings and diagnostics are rendered with the proto sources attached;
//! protoc sends none, so the plugin names the proto elements instead, and
//! its rendering is compared with the generator's own without sources and,
//! by problem code, with the corpus's.

use std::collections::BTreeMap;
use std::fs;
use std::io::Write;
use std::path::Path;
use std::process::{Command, Output, Stdio};

use elm_connect_gen::diagnostics::render_narrow;
use elm_connect_gen::{Options, VERSION, generate};
use prost::Message;
use prost_types::compiler::{CodeGeneratorRequest, CodeGeneratorResponse};

#[path = "../../elm-connect-gen/tests/common/mod.rs"]
mod common;
use common::{
    Compiled, DIAGNOSTICS, WARNINGS, case_name, case_parameter, cases, compile_case, files_under,
    is_diagnostics_case, placeholder_header,
};

/// A set's files as protox encoded them, extension options intact, which
/// `prost_types` would drop.
#[derive(Clone, PartialEq, prost::Message)]
struct RawSet {
    #[prost(bytes = "vec", repeated, tag = "1")]
    file: Vec<Vec<u8>>,
}

/// `CodeGeneratorRequest.proto_file`, as raw bytes for the same reason.
#[derive(Clone, PartialEq, prost::Message)]
struct RawProtoFiles {
    #[prost(bytes = "vec", repeated, tag = "15")]
    proto_file: Vec<Vec<u8>>,
}

/// The request protoc sends for a case: its input protos requested, every
/// import beside them, and its options as the parameter.
fn request_for(case: &Path) -> (Vec<u8>, Compiled) {
    let compiled = compile_case(case);
    let set = RawSet::decode(compiled.compiler.encode_file_descriptor_set().as_slice())
        .expect("decode the set");
    let parameter = case_parameter(case);
    let mut request = CodeGeneratorRequest {
        file_to_generate: compiled.names.clone(),
        parameter: (!parameter.is_empty()).then_some(parameter),
        ..CodeGeneratorRequest::default()
    }
    .encode_to_vec();
    RawProtoFiles {
        proto_file: set.file,
    }
    .encode(&mut request)
    .expect("encode the files");
    (request, compiled)
}

fn plugin() -> Command {
    Command::new(env!("CARGO_BIN_EXE_protoc-gen-elm-connect"))
}

/// Runs the plugin with `stdin` as its input.
fn run_with(stdin: &[u8]) -> Output {
    let mut child = plugin()
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("start the plugin");
    child
        .stdin
        .take()
        .expect("stdin")
        .write_all(stdin)
        .expect("write the request");
    child.wait_with_output().expect("wait for the plugin")
}

/// The problem codes of a narrow rendering, in order: each problem opens
/// with its code alone on a line (`services::streaming`).
fn codes(rendered: &str) -> Vec<&str> {
    rendered
        .lines()
        .filter(|line| {
            line.contains("::")
                && line
                    .chars()
                    .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_' || c == ':')
        })
        .collect()
}

fn read(path: &Path) -> String {
    fs::read_to_string(path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()))
}

/// What one case's response gets wrong; empty when nothing.
fn check(case: &Path) -> Vec<String> {
    let mut problems = Vec::new();
    let (request, compiled) = request_for(case);
    let output = run_with(&request);
    let stderr = String::from_utf8_lossy(&output.stderr).into_owned();
    if !output.status.success() {
        problems.push(format!("exit {}: {stderr}", output.status));
        return problems;
    }
    let response = match CodeGeneratorResponse::decode(output.stdout.as_slice()) {
        Ok(response) => response,
        Err(e) => {
            problems.push(format!("stdout is not a response: {e}"));
            return problems;
        }
    };

    // The generator's own rendering of the same problems, without sources,
    // as the plugin renders them.
    let names: Vec<&str> = compiled.names.iter().map(String::as_str).collect();
    let direct = Options::from_parameter(&case_parameter(case))
        .and_then(|options| generate(&compiled.compiler.descriptor_pool(), &names, &options));
    // Located, as the plugin renders problems it was sent no source for.
    let direct = direct
        .map(|mut generated| {
            generated.warnings.locate();
            generated
        })
        .map_err(|mut diagnostics| {
            diagnostics.locate();
            diagnostics
        });
    let expected = case.join("expected");

    if is_diagnostics_case(case) {
        let Some(error) = response.error.as_deref() else {
            problems.push("no error for a diagnostics case".into());
            return problems;
        };
        if !response.file.is_empty() {
            problems.push("files beside the error".into());
        }
        match &direct {
            Err(diagnostics) if render_narrow(diagnostics) == error => {}
            _ => problems.push(format!(
                "the error is not the generator's rendering:\n{error}"
            )),
        }
        let golden = read(&expected.join(DIAGNOSTICS));
        if codes(&golden).is_empty() {
            problems.push(format!("no problem codes in expected/{DIAGNOSTICS}"));
        }
        if codes(error) != codes(&golden) {
            problems.push(format!(
                "problem codes {:?}, expected {:?}",
                codes(error),
                codes(&golden)
            ));
        }
        if !stderr.is_empty() {
            problems.push(format!("stderr for a failing request: {stderr}"));
        }
        return problems;
    }

    if let Some(error) = &response.error {
        problems.push(format!("error: {error}"));
        return problems;
    }
    let generated: BTreeMap<String, String> = response
        .file
        .iter()
        .map(|file| {
            (
                file.name.clone().unwrap_or_default(),
                placeholder_header(file.content.as_deref().unwrap_or_default()),
            )
        })
        .collect();
    let golden: BTreeMap<String, String> = files_under(&expected)
        .into_iter()
        .filter(|path| path != WARNINGS)
        .map(|path| {
            let text = read(&expected.join(&path));
            (path, text)
        })
        .collect();
    if generated.keys().ne(golden.keys()) {
        problems.push(format!(
            "files {:?}, expected {:?}",
            generated.keys().collect::<Vec<_>>(),
            golden.keys().collect::<Vec<_>>()
        ));
    }
    for (path, content) in &generated {
        if golden.get(path).is_some_and(|want| want != content) {
            problems.push(format!("{path} differs from the expected module"));
        }
    }
    let warnings = match &direct {
        Ok(generated) if generated.warnings.is_empty() => String::new(),
        Ok(generated) => render_narrow(&generated.warnings),
        Err(_) => "(the generator fails)".into(),
    };
    if stderr != warnings {
        problems.push(format!("stderr is not the generator's warnings:\n{stderr}"));
    }
    let golden_warnings = fs::read_to_string(expected.join(WARNINGS)).unwrap_or_default();
    if codes(&stderr) != codes(&golden_warnings) {
        problems.push(format!(
            "warning codes {:?}, expected {:?}",
            codes(&stderr),
            codes(&golden_warnings)
        ));
    }
    problems
}

#[test]
fn every_case_through_the_plugin() {
    let cases = cases();
    let failures: Vec<String> = cases
        .iter()
        .filter_map(|case| {
            let problems = check(case);
            (!problems.is_empty())
                .then(|| format!("case `{}`:\n{}", case_name(case), problems.join("\n")))
        })
        .collect();
    assert!(failures.is_empty(), "\n{}", failures.join("\n\n"));
    // Both kinds of case are in the corpus, so both paths ran.
    assert!(cases.iter().any(|case| is_diagnostics_case(case)));
    assert!(
        cases
            .iter()
            .any(|case| case.join("expected").join(WARNINGS).is_file())
    );
}

#[test]
fn a_bad_request_is_an_error_in_the_response() {
    // Field 1 (`file_to_generate`) as a varint, which a string field cannot be.
    let output = run_with(&[0x08, 0x01]);
    assert!(output.status.success(), "{output:?}");
    let response = CodeGeneratorResponse::decode(output.stdout.as_slice()).expect("a response");
    let error = response.error.expect("an error");
    assert!(
        error.starts_with("elm-connect: decoding the request"),
        "{error}"
    );
    assert!(!String::from_utf8_lossy(&output.stderr).contains("panicked"));

    let request = CodeGeneratorRequest {
        file_to_generate: vec!["missing.proto".into()],
        ..CodeGeneratorRequest::default()
    };
    let output = run_with(&request.encode_to_vec());
    assert!(output.status.success(), "{output:?}");
    let response = CodeGeneratorResponse::decode(output.stdout.as_slice()).expect("a response");
    let error = response.error.expect("an error");
    assert!(error.starts_with("input::unknown_file\n"), "{error}");
    assert!(response.file.is_empty());
}

#[test]
fn version_and_help_answer_without_reading_stdin() {
    for (arg, starts) in [
        ("--version", format!("protoc-gen-elm-connect {VERSION}\n")),
        ("--help", format!("protoc-gen-elm-connect {VERSION}:")),
    ] {
        // stdin stays open and empty: a plugin reading it would wait for
        // ever, and the test would hang.
        let mut child = plugin()
            .arg(arg)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .expect("start the plugin");
        let stdin = child.stdin.take();
        let output = child.wait_with_output().expect("wait for the plugin");
        drop(stdin);
        assert!(output.status.success(), "{arg}: {output:?}");
        let stdout = String::from_utf8_lossy(&output.stdout);
        assert!(stdout.starts_with(&starts), "{arg}: {stdout}");
    }
}
