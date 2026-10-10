//! protoc plugin: reads a `CodeGeneratorRequest` on stdin and writes a
//! `CodeGeneratorResponse` on stdout.

use std::io::{self, Read, Write};
use std::process::ExitCode;

use elm_connect_gen::diagnostics::NOT_IMPLEMENTED;
use prost::Message;
use prost_types::compiler::code_generator_response::Feature;
use prost_types::compiler::{CodeGeneratorRequest, CodeGeneratorResponse};

/// Answers one plugin request. Errors in the user's protos travel back to
/// protoc in `error`; only a failure to talk to protoc is a process error.
fn run(_request: CodeGeneratorRequest) -> CodeGeneratorResponse {
    CodeGeneratorResponse {
        error: Some(NOT_IMPLEMENTED.to_owned()),
        supported_features: Some(Feature::Proto3Optional as u64),
        file: Vec::new(),
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
    use super::*;

    #[test]
    fn empty_request_round_trips_to_not_implemented() {
        let bytes = CodeGeneratorRequest::default().encode_to_vec();
        let request = CodeGeneratorRequest::decode(bytes.as_slice()).unwrap();

        let bytes = run(request).encode_to_vec();
        let response = CodeGeneratorResponse::decode(bytes.as_slice()).unwrap();

        assert_eq!(response.error.as_deref(), Some(NOT_IMPLEMENTED));
        assert_eq!(
            response.supported_features,
            Some(Feature::Proto3Optional as u64)
        );
        assert!(response.file.is_empty());
    }
}
