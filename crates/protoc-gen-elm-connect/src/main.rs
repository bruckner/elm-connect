//! protoc plugin: reads a `CodeGeneratorRequest` on stdin and writes a
//! `CodeGeneratorResponse` on stdout. Options arrive as the request's
//! parameter (`--elm-connect_opt=int64=int`), comma-separated `key=value`
//! pairs.
//!
//! Warnings, such as the streaming methods `streaming=skip` leaves out, go
//! to stderr, which protoc passes through: a response has no field for
//! them, and its `error` would fail the run.

use std::io::{self, Read, Write};
use std::process::ExitCode;

use elm_connect_gen::diagnostics::render_narrow;
use elm_connect_gen::{Options, generate, googleapis};
use prost::Message;
use prost_reflect::DescriptorPool;
use prost_types::compiler::code_generator_response::{Feature, File};
use prost_types::compiler::{CodeGeneratorRequest, CodeGeneratorResponse};

/// The request's `proto_file`s as protoc encoded them. Decoding them into
/// `prost_types` would drop extension options such as `google.api.http`,
/// which `prost_types::MethodOptions` has no field for, so the pool is
/// built from these bytes instead.
#[derive(Clone, PartialEq, prost::Message)]
struct RawProtoFiles {
    /// `CodeGeneratorRequest.proto_file`: every file to generate and
    /// everything it imports, each after its imports.
    #[prost(bytes = "vec", repeated, tag = "15")]
    proto_file: Vec<Vec<u8>>,
}

/// The descriptor pool of the files in `request` (its encoded bytes), with
/// extension options kept.
fn pool(request: &[u8]) -> Result<DescriptorPool, String> {
    let raw = RawProtoFiles::decode(request).map_err(|err| err.to_string())?;
    let mut pool = DescriptorPool::new();
    for file in &raw.proto_file {
        pool.decode_file_descriptor_proto(file.as_slice())
            .map_err(|err| err.to_string())?;
    }
    Ok(pool)
}

/// Answers one plugin request, given its encoded bytes, with the warnings
/// to print, rendered (empty for none). Errors in the user's protos travel
/// back to protoc in `error`; only a failure to talk to protoc is a process
/// error.
///
/// protoc sends no proto sources, so problems render without snippets,
/// naming the proto elements instead.
fn run(bytes: &[u8]) -> (CodeGeneratorResponse, String) {
    let request = match CodeGeneratorRequest::decode(bytes) {
        Ok(request) => request,
        Err(err) => {
            let response = CodeGeneratorResponse {
                error: Some(format!("elm-connect: decoding the request: {err}")),
                ..CodeGeneratorResponse::default()
            };
            return (response, String::new());
        }
    };
    let response = |error: Option<String>, file: Vec<File>| CodeGeneratorResponse {
        error,
        supported_features: Some(Feature::Proto3Optional as u64),
        file,
    };
    let options = match Options::from_parameter(request.parameter()) {
        Ok(options) => options,
        Err(err) => {
            let error = format!("elm-connect: the plugin parameter: {err}");
            return (response(Some(error), Vec::new()), String::new());
        }
    };
    let pool = match pool(bytes) {
        Ok(pool) => pool,
        Err(err) => {
            let error = format!("elm-connect: reading the descriptors: {err}");
            return (response(Some(error), Vec::new()), String::new());
        }
    };
    // `buf generate --include-imports` asks for every import, the
    // googleapis files that only carry `google.api.http` among them; they
    // are skipped, as the CLI's `--include-imports` skips them, so no
    // `Google.Api` module of `http.proto`'s messages appears.
    let generate_set: Vec<&str> = request
        .file_to_generate
        .iter()
        .map(String::as_str)
        .filter(|name| !googleapis::is_embedded(name))
        .collect();
    match generate(&pool, &generate_set, &options) {
        Ok(generated) => {
            let files = generated
                .files
                .into_iter()
                .map(|file| File {
                    name: Some(file.path),
                    content: Some(file.content),
                    ..File::default()
                })
                .collect();
            let warnings = if generated.warnings.is_empty() {
                String::new()
            } else {
                render_narrow(&generated.warnings)
            };
            (response(None, files), warnings)
        }
        Err(diagnostics) => (
            response(Some(render_narrow(&diagnostics)), Vec::new()),
            String::new(),
        ),
    }
}

fn main() -> ExitCode {
    let mut input = Vec::new();
    if let Err(err) = io::stdin().read_to_end(&mut input) {
        eprintln!("protoc-gen-elm-connect: reading the request: {err}");
        return ExitCode::FAILURE;
    }
    let (response, warnings) = run(&input);
    eprint!("{warnings}");
    let output = response.encode_to_vec();
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
        let bytes = run(&request.encode_to_vec()).0.encode_to_vec();
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
    fn the_parameter_sets_options() {
        let mut request = scalars_request();
        request.parameter = Some("int64=int".into());
        let response = round_trip(request);
        assert_eq!(response.error, None);
        let content = response.file[0].content.as_deref().expect("content");
        assert!(content.contains("int64Value : Int"), "{content}");

        let mut request = scalars_request();
        request.parameter = Some("int64=long".into());
        let error = round_trip(request).error.expect("an error");
        assert!(error.contains("`string` or `int`"), "{error}");
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

    #[test]
    fn warnings_come_back_beside_the_files() {
        let case = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../conformance/cases/services_streaming_skip");
        let mut compiler = protox::Compiler::new([case.join("input")]).expect("an include path");
        compiler.include_imports(true);
        compiler.open_file("chat.proto").expect("the case compiles");
        let request = CodeGeneratorRequest {
            file_to_generate: vec!["chat.proto".into()],
            parameter: Some("streaming=skip".into()),
            proto_file: compiler.file_descriptor_set().file,
            ..CodeGeneratorRequest::default()
        };
        let (response, warnings) = run(&request.encode_to_vec());

        assert_eq!(response.error, None);
        let names: Vec<&str> = response
            .file
            .iter()
            .filter_map(|f| f.name.as_deref())
            .collect();
        assert_eq!(names, ["Chat/V1.elm", "Chat/V1/Chat.elm"]);
        assert!(warnings.starts_with("services::streaming\n"), "{warnings}");
        assert!(warnings.contains("`chat.v1.Chat.Listen`"), "{warnings}");
        assert!(warnings.contains("`chat.v1.Uploads.Upload`"), "{warnings}");

        let (response, warnings) = run(&scalars_request().encode_to_vec());
        assert_eq!(response.error, None);
        assert_eq!(warnings, "");
    }

    #[test]
    fn a_requested_package_takes_its_files_from_the_imports() {
        let case = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../conformance/cases/packages_whole");
        let mut compiler =
            protox::Compiler::new([case.join("input"), case.join("include")]).expect("paths");
        compiler.include_imports(true);
        compiler
            .open_file("notes/v1/note.proto")
            .expect("the case compiles");
        let request = CodeGeneratorRequest {
            file_to_generate: vec!["notes/v1/note.proto".into()],
            proto_file: compiler.file_descriptor_set().file,
            ..CodeGeneratorRequest::default()
        };
        let response = round_trip(request);

        assert_eq!(response.error, None);
        let names: Vec<&str> = response
            .file
            .iter()
            .filter_map(|f| f.name.as_deref())
            .collect();
        assert_eq!(names, ["Notes/V1.elm"]);
        let expected =
            std::fs::read_to_string(case.join("expected/Notes/V1.elm")).expect("blessed");
        assert!(
            response.file[0].content.as_deref() == Some(expected.as_str()),
            "the plugin's Notes/V1.elm differs from the blessed expected output"
        );
    }

    /// A set's files as protox encoded them, options intact.
    #[derive(Clone, PartialEq, prost::Message)]
    struct RawSet {
        #[prost(bytes = "vec", repeated, tag = "1")]
        file: Vec<Vec<u8>>,
    }

    #[test]
    fn services_case_generates_its_expected_output() {
        let case =
            PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../conformance/cases/services");
        let mut compiler =
            protox::Compiler::with_file_resolver(elm_connect_gen::googleapis::resolver([
                case.join("input")
            ]));
        compiler.include_imports(true);
        compiler
            .open_file("notes.proto")
            .expect("the case compiles");
        let set = RawSet::decode(compiler.encode_file_descriptor_set().as_slice()).expect("set");
        let mut request = CodeGeneratorRequest {
            file_to_generate: vec!["notes.proto".into()],
            ..CodeGeneratorRequest::default()
        }
        .encode_to_vec();
        RawProtoFiles {
            proto_file: set.file,
        }
        .encode(&mut request)
        .expect("encode");
        let response = CodeGeneratorResponse::decode(run(&request).0.encode_to_vec().as_slice())
            .expect("decode");
        assert_eq!(response.error, None);
        let names: Vec<&str> = response
            .file
            .iter()
            .filter_map(|f| f.name.as_deref())
            .collect();
        assert_eq!(names, ["Notes/V1.elm", "Notes/V1/NotesService.elm"]);
        for file in &response.file {
            let name = file.name.as_deref().expect("a name");
            let expected =
                std::fs::read_to_string(case.join("expected").join(name)).expect("blessed");
            assert!(
                file.content.as_deref() == Some(expected.as_str()),
                "the plugin's {name} differs from the blessed expected output; run the \
                 conformance tests for a diff"
            );
        }
    }

    #[test]
    fn extension_options_survive_the_request() {
        let dir = std::env::temp_dir().join("protoc-gen-elm-connect-http");
        std::fs::create_dir_all(&dir).expect("create");
        std::fs::write(
            dir.join("notes.proto"),
            r#"syntax = "proto3";
package notes.v1;
import "google/api/annotations.proto";
message Note { string name = 1; }
service Notes {
  rpc GetNote(Note) returns (Note) {
    option (google.api.http) = { get: "/v1/{name=notes/*}" };
  }
}
"#,
        )
        .expect("write");
        let mut compiler =
            protox::Compiler::with_file_resolver(elm_connect_gen::googleapis::resolver([dir]));
        compiler.include_imports(true);
        compiler.open_file("notes.proto").expect("compiles");
        let set = RawSet::decode(compiler.encode_file_descriptor_set().as_slice()).expect("set");
        let mut request = CodeGeneratorRequest {
            file_to_generate: vec!["notes.proto".into()],
            ..CodeGeneratorRequest::default()
        }
        .encode_to_vec();
        RawProtoFiles {
            proto_file: set.file,
        }
        .encode(&mut request)
        .expect("encode");

        let pool = pool(&request).expect("a pool");
        let packages = elm_connect_gen::ir::build(&pool, &["notes.proto"]).expect("the IR builds");
        let method = &packages[0].services[0].methods[0];
        let rule = method.http.as_ref().expect("the rule survives");
        assert_eq!(rule.template, "/v1/{name=notes/*}");
    }

    /// The request `buf generate --include-imports` sends for `files`
    /// (each a name and its source, written under a temporary directory
    /// named `case`) asking for `to_generate`, compiled against the
    /// embedded googleapis files, options intact.
    fn request_for(case: &str, files: &[(&str, &str)], to_generate: &[&str]) -> Vec<u8> {
        let dir = std::env::temp_dir().join(format!("protoc-gen-elm-connect-{case}"));
        for (name, source) in files {
            let path = dir.join(name);
            std::fs::create_dir_all(path.parent().expect("a parent")).expect("create");
            std::fs::write(path, source).expect("write");
        }
        let mut compiler =
            protox::Compiler::with_file_resolver(elm_connect_gen::googleapis::resolver([dir]));
        compiler.include_imports(true);
        compiler
            .open_files(files.iter().map(|(name, _)| *name))
            .expect("compiles");
        let set = RawSet::decode(compiler.encode_file_descriptor_set().as_slice()).expect("set");
        let mut request = CodeGeneratorRequest {
            file_to_generate: to_generate.iter().map(|&name| name.to_owned()).collect(),
            ..CodeGeneratorRequest::default()
        }
        .encode_to_vec();
        RawProtoFiles {
            proto_file: set.file,
        }
        .encode(&mut request)
        .expect("encode");
        request
    }

    fn names(response: &CodeGeneratorResponse) -> Vec<&str> {
        response
            .file
            .iter()
            .filter_map(|f| f.name.as_deref())
            .collect()
    }

    const NOTES: &str = r#"syntax = "proto3";
package notes.v1;
import "google/api/annotations.proto";
message Note { string name = 1; }
service Notes {
  rpc GetNote(Note) returns (Note) {
    option (google.api.http) = { get: "/v1/{name=notes/*}" };
  }
}
"#;

    #[test]
    fn the_embedded_googleapis_files_are_not_generated() {
        let request = request_for(
            "googleapis-skipped",
            &[("notes.proto", NOTES)],
            &[
                "google/api/http.proto",
                "google/protobuf/descriptor.proto",
                "google/api/annotations.proto",
                "notes.proto",
            ],
        );
        let (response, warnings) = run(&request);
        assert_eq!(response.error, None);
        assert_eq!(warnings, "");
        assert_eq!(
            names(&response),
            ["Notes/V1.elm", "Notes/V1/Notes.elm"],
            "no Google/Api.elm"
        );
    }

    #[test]
    fn other_google_api_files_are_generated() {
        let httpbody = r#"syntax = "proto3";
package google.api;
import "google/protobuf/any.proto";
message HttpBody {
  string content_type = 1;
  bytes data = 2;
  repeated google.protobuf.Any extensions = 3;
}
"#;
        let upload = r#"syntax = "proto3";
package uploads.v1;
import "google/api/httpbody.proto";
service Uploads {
  rpc Upload(google.api.HttpBody) returns (google.api.HttpBody);
}
"#;
        let request = request_for(
            "httpbody",
            &[
                ("google/api/httpbody.proto", httpbody),
                ("uploads.proto", upload),
            ],
            &["google/api/httpbody.proto", "uploads.proto"],
        );
        let response = CodeGeneratorResponse::decode(run(&request).0.encode_to_vec().as_slice())
            .expect("decode");
        assert_eq!(response.error, None);
        assert_eq!(
            names(&response),
            ["Google/Api.elm", "Uploads/V1.elm", "Uploads/V1/Uploads.elm"]
        );
        let api = response.file[0].content.as_deref().expect("content");
        assert!(api.contains("type alias HttpBody ="), "{api}");
    }
}
