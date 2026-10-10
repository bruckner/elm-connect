//! protoc plugin: reads a `CodeGeneratorRequest` on stdin and writes a
//! `CodeGeneratorResponse` on stdout.

use std::io::{self, Read, Write};
use std::process::ExitCode;

use elm_connect_gen::diagnostics::render_narrow;
use elm_connect_gen::{Options, generate};
use prost::Message;
use prost_reflect::DescriptorPool;
use prost_types::FileDescriptorSet;
use prost_types::compiler::code_generator_response::{Feature, File};
use prost_types::compiler::{CodeGeneratorRequest, CodeGeneratorResponse};

/// Answers one plugin request. Errors in the user's protos travel back to
/// protoc in `error`; only a failure to talk to protoc is a process error.
///
/// protoc sends no proto sources, so problems render without snippets,
/// naming the proto elements instead.
fn run(request: CodeGeneratorRequest) -> CodeGeneratorResponse {
    let response = |error: Option<String>, file: Vec<File>| CodeGeneratorResponse {
        error,
        supported_features: Some(Feature::Proto3Optional as u64),
        file,
    };
    let pool = match DescriptorPool::from_file_descriptor_set(FileDescriptorSet {
        file: request.proto_file,
    }) {
        Ok(pool) => pool,
        Err(err) => {
            return response(
                Some(format!("elm-connect: reading the descriptors: {err}")),
                Vec::new(),
            );
        }
    };
    let generate_set: Vec<&str> = request
        .file_to_generate
        .iter()
        .map(String::as_str)
        .collect();
    match generate(&pool, &generate_set, &Options::default()) {
        Ok(files) => response(
            None,
            files
                .into_iter()
                .map(|file| File {
                    name: Some(file.path),
                    content: Some(file.content),
                    ..File::default()
                })
                .collect(),
        ),
        Err(diagnostics) => response(Some(render_narrow(&diagnostics)), Vec::new()),
    }
}

fn main() -> ExitCode {
    let mut input = Vec::new();
    if let Err(err) = io::stdin().read_to_end(&mut input) {
        eprintln!("protoc-gen-elm-connect: reading the request: {err}");
        return ExitCode::FAILURE;
    }
    let request = match CodeGeneratorRequest::decode(input.as_slice()) {
        Ok(request) => request,
        Err(err) => {
            eprintln!("protoc-gen-elm-connect: decoding the request: {err}");
            return ExitCode::FAILURE;
        }
    };
    let output = run(request).encode_to_vec();
    if let Err(err) = io::stdout().write_all(&output) {
        eprintln!("protoc-gen-elm-connect: writing the response: {err}");
        return ExitCode::FAILURE;
    }
    ExitCode::SUCCESS
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use super::*;

    fn scalars_case() -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../conformance/cases/scalars")
    }

    /// The request protoc would send for the scalars case, round-tripped
    /// through the wire format.
    fn scalars_request() -> CodeGeneratorRequest {
        let mut compiler =
            protox::Compiler::new([scalars_case().join("input")]).expect("an include path");
        compiler.include_source_info(true).include_imports(true);
        compiler
            .open_file("scalars.proto")
            .expect("the case compiles");
        let request = CodeGeneratorRequest {
            file_to_generate: vec!["scalars.proto".into()],
            proto_file: compiler.file_descriptor_set().file,
            ..CodeGeneratorRequest::default()
        };
        CodeGeneratorRequest::decode(request.encode_to_vec().as_slice()).expect("decode")
    }

    fn round_trip(request: CodeGeneratorRequest) -> CodeGeneratorResponse {
        let bytes = run(request).encode_to_vec();
        CodeGeneratorResponse::decode(bytes.as_slice()).expect("decode the response")
    }

    #[test]
    fn scalars_case_generates_its_expected_output() {
        let response = round_trip(scalars_request());

        assert_eq!(response.error, None);
        assert_eq!(
            response.supported_features,
            Some(Feature::Proto3Optional as u64)
        );
        let [file] = response.file.as_slice() else {
            panic!("expected one file, got {:?}", response.file);
        };
        assert_eq!(file.name.as_deref(), Some("Scalars/V1.elm"));
        let expected = std::fs::read_to_string(scalars_case().join("expected/Scalars/V1.elm"))
            .expect("the blessed output");
        assert!(
            file.content.as_deref() == Some(expected.as_str()),
            "the plugin's output differs from the blessed expected output; run the \
             conformance tests for a diff"
        );
    }

    #[test]
    fn problems_come_back_rendered_in_error() {
        let mut request = scalars_request();
        request.file_to_generate = vec!["missing.proto".into()];
        let response = round_trip(request);

        let error = response.error.expect("an error");
        assert!(error.starts_with("generate::unknown_file\n"), "{error}");
        assert!(error.contains("`missing.proto`"), "{error}");
        assert!(response.file.is_empty());
    }
}
