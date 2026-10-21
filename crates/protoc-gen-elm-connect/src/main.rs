//! protoc plugin: reads a `CodeGeneratorRequest` on stdin and writes a
//! `CodeGeneratorResponse` on stdout. Options arrive as the request's
//! parameter (`--elm-connect_opt=int64=int`), comma-separated `key=value`
//! pairs.
//!
//! Warnings, such as the streaming methods `streaming=skip` leaves out, go
//! to stderr, which protoc passes through: a response has no field for
//! them, and its `error` would fail the run.
//!
//! `--version` and `--help` are answered before stdin is read, and run
//! from a terminal without either, the plugin prints its usage rather
//! than wait for a request.

use std::io::{self, IsTerminal, Read, Write};
use std::process::ExitCode;

use elm_connect_gen::diagnostics::{
    Diagnostics, Problem, Site, field_name_conflict_names, field_name_conflicts, render_narrow,
};
use elm_connect_gen::naming::REPOSITORY_FILES;
use elm_connect_gen::{Options, Spelling, VERSION, generate, googleapis};
use prost::Message;
use prost_reflect::{DescriptorError, DescriptorPool};
use prost_types::FileDescriptorProto;
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

/// The fields of a `FileDescriptorProto` that say whether it is an
/// editions file, read before the pool is built: a descriptor pool cannot
/// take one (design §1.3).
#[derive(Clone, PartialEq, prost::Message)]
struct FileHeader {
    #[prost(string, optional, tag = "1")]
    name: Option<String>,
    #[prost(string, optional, tag = "12")]
    syntax: Option<String>,
    /// `FileDescriptorProto.edition`, a `google.protobuf.Edition`.
    #[prost(int32, optional, tag = "14")]
    edition: Option<i32>,
}

/// An `input::editions` problem for every file of `raw` that declares an
/// edition.
fn editions(raw: &RawProtoFiles) -> Diagnostics {
    let mut diagnostics = Diagnostics::new();
    for file in &raw.proto_file {
        let Ok(header) = FileHeader::decode(file.as_slice()) else {
            continue;
        };
        if header.syntax.as_deref() != Some("editions") {
            continue;
        }
        let name = header.name.unwrap_or_default();
        // `google.protobuf.Edition`'s numbers for the editions protoc
        // accepts; any other is named generically.
        let edition = match header.edition {
            Some(1000) => Some("2023"),
            Some(1001) => Some("2024"),
            _ => None,
        };
        let site = Site {
            file: name.clone(),
            span: None,
            label: "the edition".into(),
            within: Vec::new(),
        };
        diagnostics.push(Problem::editions(&name, edition, site));
    }
    diagnostics
}

/// The descriptor pool of `raw`'s files, with extension options kept, or
/// the error building it, rendered: `input::field_name_conflict` for the
/// one refusal of protos protoc accepts, the library's own text for any
/// other.
fn pool(raw: &RawProtoFiles, spelling: Spelling) -> Result<DescriptorPool, String> {
    let mut pool = DescriptorPool::new();
    for file in &raw.proto_file {
        if let Err(err) = pool.decode_file_descriptor_proto(file.as_slice()) {
            return Err(match field_name_conflict(raw, &err, spelling) {
                Some(mut diagnostics) => {
                    diagnostics.locate();
                    render_narrow(&diagnostics)
                }
                None => format!("elm-connect: reading the descriptors: {err}"),
            });
        }
    }
    Ok(pool)
}

/// `err` as `input::field_name_conflict`, when it is the refusal of two
/// fields of a message whose names are the same once lowercased without
/// underscores: at both fields' names, found from the error's path in the
/// file it names.
fn field_name_conflict(
    raw: &RawProtoFiles,
    err: &DescriptorError,
    spelling: Spelling,
) -> Option<Diagnostics> {
    let text = err.to_string();
    let (first, second) = field_name_conflict_names(&text)?;
    let name = err.file().unwrap_or_default();
    let file = raw
        .proto_file
        .iter()
        .filter_map(|bytes| FileDescriptorProto::decode(bytes.as_slice()).ok())
        .find(|file| file.name() == name);
    let conflicts = file
        .as_ref()
        .map(|file| field_name_conflicts(file, first, second))
        .unwrap_or_default();
    let conflict = conflicts
        .iter()
        .find(|conflict| Some(conflict.path.as_slice()) == err.path())
        .or(conflicts.first());
    let problem = match conflict {
        Some(conflict) => Problem::field_name_conflict(
            name,
            Some(&conflict.message),
            first,
            second,
            spelling,
            conflict.sites.clone(),
        ),
        None => {
            let site = Site {
                file: name.to_owned(),
                span: None,
                label: format!("field `{second}`"),
                within: Vec::new(),
            };
            Problem::field_name_conflict(name, None, first, second, spelling, vec![site])
        }
    };
    Some(Diagnostics::from(problem))
}

/// Answers one plugin request, given its encoded bytes, with the warnings
/// to print, rendered (empty for none). Errors in the user's protos travel
/// back to protoc in `error`; only a failure to talk to protoc is a process
/// error.
///
/// protoc sends no proto sources, so problems render without snippets,
/// naming the proto elements, and each site as `file:line:col` from the
/// request's `SourceCodeInfo`.
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
        Err(problems) => {
            let error = render_narrow(&problems);
            return (response(Some(error), Vec::new()), String::new());
        }
    };
    let raw = match RawProtoFiles::decode(bytes) {
        Ok(raw) => raw,
        Err(err) => {
            let error = format!("elm-connect: reading the descriptors: {err}");
            return (response(Some(error), Vec::new()), String::new());
        }
    };
    let mut unsupported = editions(&raw);
    if !unsupported.is_empty() {
        unsupported.locate();
        let error = render_narrow(&unsupported);
        return (response(Some(error), Vec::new()), String::new());
    }
    let pool = match pool(&raw, options.spelling) {
        Ok(pool) => pool,
        Err(error) => return (response(Some(error), Vec::new()), String::new()),
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
            let mut warnings = generated.warnings;
            warnings.locate();
            let warnings = if warnings.is_empty() {
                String::new()
            } else {
                render_narrow(&warnings)
            };
            (response(None, files), warnings)
        }
        Err(mut diagnostics) => {
            diagnostics.locate();
            (
                response(Some(render_narrow(&diagnostics)), Vec::new()),
                String::new(),
            )
        }
    }
}

/// What `--help` prints, and what a run without a request on stdin prints
/// to stderr.
fn usage() -> String {
    format!(
        "protoc-gen-elm-connect {VERSION}: generate Elm clients for protobuf APIs.

A protoc plugin: protoc or buf runs it and sends it the protos on stdin.

    protoc --elm-connect_out=generated notes.proto
    protoc --elm-connect_out=generated --elm-connect_opt=int64=int notes.proto

Options go in the plugin parameter, comma-separated `key=value` pairs:
int64, bytes, unbound_methods, streaming, enum_unknown, rename (repeatable)
and module_prefix. To generate without protoc, use the `elm-connect` CLI.
To work with the generated code, run `elm-connect guide` or read
{REPOSITORY_FILES}docs/agent-guide.md.

Usage: protoc-gen-elm-connect [--version | --help]
"
    )
}

/// What the command line asks for before any request is read: `None` to
/// answer a request on stdin, or the exit status after answering the
/// command line itself. protoc and buf pass no arguments.
fn command_line(args: &[String], stdin_is_terminal: bool) -> Option<ExitCode> {
    match args.first().map(String::as_str) {
        Some("--version" | "-V") => {
            println!("protoc-gen-elm-connect {VERSION}");
            Some(ExitCode::SUCCESS)
        }
        Some("--help" | "-h") => {
            print!("{}", usage());
            Some(ExitCode::SUCCESS)
        }
        Some(other) => {
            eprint!(
                "protoc-gen-elm-connect: unknown argument `{other}`\n\n{}",
                usage()
            );
            Some(ExitCode::from(2))
        }
        // Run from a terminal, it would wait for a request no one sends.
        None if stdin_is_terminal => {
            eprint!("{}", usage());
            Some(ExitCode::from(2))
        }
        None => None,
    }
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if let Some(status) = command_line(&args, io::stdin().is_terminal()) {
        return status;
    }
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

    /// The expected module at `path` in the corpus, with the generator's
    /// version where the corpus has the placeholder `0.1.X`.
    fn blessed(path: &std::path::Path) -> String {
        std::fs::read_to_string(path)
            .expect("the blessed output")
            .replacen(
                &format!(
                    "elm-connect {} ",
                    elm_connect_gen::HEADER_VERSION_PLACEHOLDER
                ),
                &format!("elm-connect {} ", elm_connect_gen::VERSION),
                1,
            )
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
        let [file, _, _] = response.file.as_slice() else {
            panic!(
                "expected the package's module and two descriptor modules, got {:?}",
                response.file
            );
        };
        assert_eq!(file.name.as_deref(), Some("Scalars/V1.elm"));
        let expected = blessed(&scalars_case().join("expected/Scalars/V1.elm"));
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
        request.parameter = Some("bytes=bytes".into());
        let response = round_trip(request);
        assert_eq!(response.error, None);
        let content = response.file[0].content.as_deref().expect("content");
        assert!(content.contains("bytesValue : Bytes.Bytes"), "{content}");

        let mut request = scalars_request();
        request.parameter = Some("int64=long".into());
        let error = round_trip(request).error.expect("an error");
        assert!(error.starts_with("options::unknown_option\n"), "{error}");
        assert!(error.contains("`string` or `int`"), "{error}");
    }

    #[test]
    fn problems_come_back_rendered_in_error() {
        let mut request = scalars_request();
        request.file_to_generate = vec!["missing.proto".into()];
        let response = round_trip(request);

        let error = response.error.expect("an error");
        assert!(error.starts_with("input::unknown_file\n"), "{error}");
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
        assert_eq!(
            names,
            ["Chat/V1.elm", "Chat/V1/Chat.elm", "Chat/V1/Line.elm"]
        );
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
        compiler.include_imports(true).include_source_info(true);
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
        assert_eq!(
            names,
            ["Notes/V1.elm", "Notes/V1/Note.elm", "Notes/V1/Tag.elm"]
        );
        let expected = blessed(&case.join("expected/Notes/V1.elm"));
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
        // protoc sends source info, which the docs' comments come from.
        compiler.include_imports(true).include_source_info(true);
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
        assert_eq!(
            names,
            [
                "Notes/V1.elm",
                "Notes/V1/ArchiveNoteRequest.elm",
                "Notes/V1/CreateNoteRequest.elm",
                "Notes/V1/DeleteNoteRequest.elm",
                "Notes/V1/GetNoteRequest.elm",
                "Notes/V1/ListNotesRequest.elm",
                "Notes/V1/ListNotesRequestFilter.elm",
                "Notes/V1/ListNotesResponse.elm",
                "Notes/V1/Note.elm",
                "Notes/V1/NotesService.elm",
                "Notes/V1/ReadFileRequest.elm",
                "Notes/V1/Summary.elm",
                "Notes/V1/UpdateNoteRequest.elm",
                "Notes/V1/Visibility.elm"
            ]
        );
        for file in &response.file {
            let name = file.name.as_deref().expect("a name");
            let expected = blessed(&case.join("expected").join(name));
            assert!(
                file.content.as_deref() == Some(expected.as_str()),
                "the plugin's {name} differs from the blessed expected output; run the \
                 conformance tests for a diff"
            );
        }
    }

    #[test]
    fn extension_options_survive_the_request() {
        let request = request_for(&[("notes.proto", NOTES)], &["notes.proto"]);
        let raw = RawProtoFiles::decode(request.as_slice()).expect("the files");
        let pool = pool(&raw, Spelling::Parameter).expect("a pool");
        let packages = elm_connect_gen::ir::build(&pool, &["notes.proto"]).expect("the IR builds");
        let method = &packages[0].services[0].methods[0];
        let rule = method.http.as_ref().expect("the rule survives");
        assert_eq!(rule.template, "/v1/{name=notes/*}");
    }

    /// Protos held in memory, by import name, so that no test writes files
    /// another run, in this checkout or another, could share.
    struct Sources(Vec<(String, String)>);

    impl protox::file::FileResolver for Sources {
        fn open_file(&self, name: &str) -> Result<protox::file::File, protox::Error> {
            match self.0.iter().find(|(file, _)| file == name) {
                Some((_, source)) => protox::file::File::from_source(name, source),
                None => Err(protox::Error::file_not_found(name)),
            }
        }
    }

    /// The request `buf generate --include-imports` sends for `files`
    /// (each a name and its source) asking for `to_generate`, compiled
    /// against the embedded googleapis files, options intact.
    fn request_for(files: &[(&str, &str)], to_generate: &[&str]) -> Vec<u8> {
        let mut resolver = protox::file::ChainFileResolver::new();
        resolver.add(Sources(
            files
                .iter()
                .map(|&(name, source)| (name.to_owned(), source.to_owned()))
                .collect(),
        ));
        resolver.add(elm_connect_gen::googleapis::resolver([]));
        let mut compiler = protox::Compiler::with_file_resolver(resolver);
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
            ["Notes/V1.elm", "Notes/V1/Note.elm", "Notes/V1/Notes.elm"],
            "no Google/Api.elm"
        );
    }

    #[test]
    fn field_behavior_survives_the_request_and_is_not_generated() {
        let tasks = r#"syntax = "proto3";
package tasks.v1;
import "google/api/field_behavior.proto";
message Task {
  string name = 1 [(google.api.field_behavior) = IDENTIFIER, deprecated = true];
}
"#;
        let request = request_for(
            &[("tasks.proto", tasks)],
            &["google/api/field_behavior.proto", "tasks.proto"],
        );
        let raw = RawProtoFiles::decode(request.as_slice()).expect("the files");
        let pool = pool(&raw, Spelling::Parameter).expect("a pool");
        let packages = elm_connect_gen::ir::build(&pool, &["tasks.proto"]).expect("the IR builds");
        let annotations = &packages[0].messages[0].fields[0].annotations;
        assert_eq!(
            annotations.behavior,
            [elm_connect_gen::ir::FieldBehavior::Identifier]
        );
        assert!(annotations.deprecated);

        let (response, warnings) = run(&request);
        assert_eq!(response.error, None);
        assert_eq!(warnings, "");
        assert_eq!(
            names(&response),
            ["Tasks/V1.elm", "Tasks/V1/Task.elm"],
            "no Google/Api.elm"
        );
        let module = response.file[1].content.as_deref().expect("content");
        assert!(
            module.contains(
                "|> Proto.Field.withBehavior [ Proto.Field.BehaviorIdentifier ]\n        \
                 |> Proto.Field.withDeprecated"
            ),
            "{module}"
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
            [
                "Google/Api.elm",
                "Google/Api/HttpBody.elm",
                "Uploads/V1.elm",
                "Uploads/V1/Uploads.elm"
            ]
        );
        let api = response.file[0].content.as_deref().expect("content");
        assert!(api.contains("type alias HttpBody ="), "{api}");
    }

    #[test]
    fn an_editions_file_is_a_diagnostic_not_a_panic() {
        let file = prost_types::FileDescriptorProto {
            name: Some("ed.proto".into()),
            package: Some("e.v1".into()),
            syntax: Some("editions".into()),
            message_type: vec![prost_types::DescriptorProto {
                name: Some("M".into()),
                ..prost_types::DescriptorProto::default()
            }],
            ..prost_types::FileDescriptorProto::default()
        };
        // prost-types has no field for the edition; a second encoding
        // merges it in, as protoc's own encoding would carry it.
        let mut bytes = file.encode_to_vec();
        FileHeader {
            edition: Some(1000),
            ..FileHeader::default()
        }
        .encode(&mut bytes)
        .expect("encode");
        let mut request = CodeGeneratorRequest {
            file_to_generate: vec!["ed.proto".into()],
            ..CodeGeneratorRequest::default()
        }
        .encode_to_vec();
        RawProtoFiles {
            proto_file: vec![bytes],
        }
        .encode(&mut request)
        .expect("encode");

        let (response, warnings) = run(&request);
        let error = response.error.expect("an error");
        assert!(error.starts_with("input::editions\n"), "{error}");
        assert!(error.contains("`ed.proto`"), "{error}");
        assert!(error.contains("`edition = \"2023\"`"), "{error}");
        assert!(error.contains("syntax = \"proto3\""), "{error}");
        assert!(response.file.is_empty());
        assert_eq!(warnings, "");
        assert_eq!(
            response.supported_features,
            Some(Feature::Proto3Optional as u64),
            "editions are not claimed"
        );
    }

    #[test]
    fn fields_the_descriptor_library_refuses_get_a_code() {
        // protox's checks refuse the file too, so it is parsed alone, with
        // source info, as protoc would send it.
        let source =
            "syntax = \"proto3\";\npackage p.v1;\nmessage M { string aB = 1; string ab = 2; }\n";
        let file = protox::file::File::from_source("p.proto", source).expect("parses");
        let request = CodeGeneratorRequest {
            file_to_generate: vec!["p.proto".into()],
            proto_file: vec![file.file_descriptor_proto().clone()],
            ..CodeGeneratorRequest::default()
        };

        let (response, warnings) = run(&request.encode_to_vec());
        let error = response.error.expect("an error");
        assert!(error.starts_with("input::field_name_conflict\n"), "{error}");
        assert!(
            error.contains("p.proto:3:20: The fields `aB` and `ab` of the message `p.v1.M`"),
            "{error}"
        );
        assert!(error.contains("p.proto:3:35: and field `ab`"), "{error}");
        assert!(error.contains("`rename` cannot help"), "{error}");
        assert!(response.file.is_empty());
        assert_eq!(warnings, "");
    }

    #[test]
    fn problems_name_their_sites_by_file_line_and_column() {
        let dir = std::env::temp_dir().join("protoc-gen-elm-connect-located");
        let source =
            "syntax = \"proto3\";\n\npackage library.v1;\n\nmessage Book {}\nmessage book {}\n";
        std::fs::create_dir_all(dir.join("library/v1")).expect("create");
        std::fs::write(dir.join("library/v1/library.proto"), source).expect("write");
        let mut compiler = protox::Compiler::new([dir]).expect("an include path");
        // protoc sends `source_code_info` for the files to generate.
        compiler.include_source_info(true).include_imports(true);
        compiler
            .open_file("library/v1/library.proto")
            .expect("compiles");
        let request = CodeGeneratorRequest {
            file_to_generate: vec!["library/v1/library.proto".into()],
            proto_file: compiler.file_descriptor_set().file,
            ..CodeGeneratorRequest::default()
        };
        let error = round_trip(request).error.expect("an error");
        assert_eq!(
            error,
            "naming::type_collision

  × library/v1/library.proto:5:9: The package `library.v1` has two messages
  │ that both become the Elm type and record constructor `Book`.
  │ library/v1/library.proto:5:9: message `library.v1.Book` becomes `Book`
  │ library/v1/library.proto:6:9: and so does message `library.v1.book`
  help: Every message, enum and oneof of a package becomes a type in one Elm
        module, nested names joined (`Outer.Inner` becomes `OuterInner`), and
        a module cannot define two types with one name. A message's record
        constructor takes its type's name, so the two collide as constructors
        too, and one rename parts both. Rename one of them in the proto, or
        rename one with `rename=library.v1.book:<Elm name>`.
"
        );
    }

    #[test]
    fn the_command_line_is_answered_before_stdin() {
        let args = |args: &[&str]| args.iter().map(|&a| a.to_owned()).collect::<Vec<_>>();
        assert_eq!(
            command_line(&args(&["--version"]), false),
            Some(ExitCode::SUCCESS)
        );
        assert_eq!(
            command_line(&args(&["--help"]), true),
            Some(ExitCode::SUCCESS)
        );
        assert_eq!(
            command_line(&args(&["--out"]), false),
            Some(ExitCode::from(2))
        );
        assert_eq!(command_line(&args(&[]), true), Some(ExitCode::from(2)));
        assert_eq!(command_line(&args(&[]), false), None);
        assert!(usage().starts_with(&format!("protoc-gen-elm-connect {VERSION}:")));
    }
}
