use std::{env, fs, io, path::PathBuf};

use insta::assert_yaml_snapshot;
use miette::{Diagnostic, JSONReportHandler};
use prost::Message;
use prost_reflect::{DescriptorPool, Value};
use prost_types::{
    source_code_info::Location, FileDescriptorProto, FileDescriptorSet, SourceCodeInfo,
};
use protox::{
    compile,
    file::{ChainFileResolver, DescriptorSetFileResolver, File, FileResolver, GoogleFileResolver},
    Compiler, Error,
};
use tempfile::TempDir;

struct TestFileResolver {
    files: &'static [(&'static str, &'static str)],
}

impl FileResolver for TestFileResolver {
    fn open_file(&self, name: &str) -> Result<File, Error> {
        if name == "customerror.proto" {
            return Err(Error::new(io::Error::new(
                io::ErrorKind::Other,
                "failed to load file!",
            )));
        }

        for file in self.files {
            if file.0 == name {
                return File::from_source(name, file.1);
            }
        }

        Err(Error::file_not_found(name))
    }
}

fn check(files: &'static [(&'static str, &'static str)]) -> Result<Compiler, Error> {
    let tempdir = tempfile::tempdir().unwrap();
    for (file, source) in files {
        fs::write(tempdir.path().join(file), source).unwrap();
    }

    let mut compiler = Compiler::with_file_resolver(TestFileResolver { files });

    // Only compile last file.
    // Imports may have errors that must be correctly listed by compilation of root.
    compiler.open_file(files[files.len() - 1].0)?;
    Ok(compiler)
}

fn check_err(files: &'static [(&'static str, &'static str)]) -> serde_json::Value {
    error_to_json(&check(files).unwrap_err())
}

fn error_to_json(err: &dyn Diagnostic) -> serde_json::Value {
    let mut json = String::new();
    JSONReportHandler::new()
        .render_report(&mut json, err)
        .unwrap();
    serde_json::from_str(&json).unwrap()
}

#[test]
fn import_not_found() {
    assert_yaml_snapshot!(check_err(&[("root.proto", "import 'notfound.proto';")]));
}

#[test]
fn import_error() {
    assert_yaml_snapshot!(check_err(&[("root.proto", "import 'customerror.proto';")]));
}

#[test]
fn double_import_error() {
    assert_yaml_snapshot!(check_err(&[
        ("existing.proto", ""),
        (
            "root.proto",
            "import 'existing.proto';
        import 'existing.proto';
        "
        ),
    ]));
}

#[test]
fn double_import_branch_error() {
    assert_yaml_snapshot!(check_err(&[
        ("existing.proto", ""),
        (
            "branch.proto",
            "import 'existing.proto';
        import 'existing.proto';
        "
        ),
        (
            "root.proto",
            "import 'branch.proto';
        "
        ),
    ]));
}

#[test]
fn type_not_found() {
    assert_yaml_snapshot!(check_err(&[(
        "root.proto",
        "
        message Foo {
            optional NotFound foo = 1;
        }
    "
    )]));
}

#[test]
fn default_options() {
    let mut compiler = Compiler::with_file_resolver(TestFileResolver {
        files: &[("dep.proto", ""), ("root.proto", "import 'dep.proto';")],
    });

    compiler.open_file("root.proto").unwrap();

    let files = compiler.file_descriptor_set();
    assert_eq!(
        files,
        FileDescriptorSet {
            file: vec![FileDescriptorProto {
                name: Some("root.proto".to_owned()),
                dependency: vec!["dep.proto".to_owned()],
                ..Default::default()
            },],
        }
    );

    let encoded = compiler.encode_file_descriptor_set();
    assert_eq!(
        FileDescriptorSet::decode(encoded.as_slice()).unwrap(),
        files
    );
}

#[test]
fn include_imports() {
    let mut compiler = Compiler::with_file_resolver(TestFileResolver {
        files: &[("dep.proto", ""), ("root.proto", "import 'dep.proto';")],
    });

    compiler.include_imports(true);
    compiler.open_file("root.proto").unwrap();

    let files = compiler.file_descriptor_set();
    assert_eq!(
        files,
        FileDescriptorSet {
            file: vec![
                FileDescriptorProto {
                    name: Some("dep.proto".to_owned()),
                    ..Default::default()
                },
                FileDescriptorProto {
                    name: Some("root.proto".to_owned()),
                    dependency: vec!["dep.proto".to_owned()],
                    ..Default::default()
                },
            ],
        }
    );

    let encoded = compiler.encode_file_descriptor_set();
    assert_eq!(
        FileDescriptorSet::decode(encoded.as_slice()).unwrap(),
        files
    );
}

#[test]
fn include_source_info() {
    let mut compiler = Compiler::with_file_resolver(TestFileResolver {
        files: &[("dep.proto", ""), ("root.proto", "import 'dep.proto';")],
    });

    compiler.include_source_info(true);
    compiler.open_file("root.proto").unwrap();

    let files = compiler.file_descriptor_set();
    assert_eq!(
        files,
        FileDescriptorSet {
            file: vec![FileDescriptorProto {
                name: Some("root.proto".to_owned()),
                dependency: vec!["dep.proto".to_owned()],
                source_code_info: Some(SourceCodeInfo {
                    location: vec![
                        Location {
                            path: vec![],
                            span: vec![0, 0, 19],
                            ..Default::default()
                        },
                        Location {
                            path: vec![3, 0],
                            span: vec![0, 0, 19],
                            ..Default::default()
                        }
                    ]
                }),
                ..Default::default()
            },],
        }
    );

    let encoded = compiler.encode_file_descriptor_set();
    assert_eq!(
        FileDescriptorSet::decode(encoded.as_slice()).unwrap(),
        files
    );
}

#[test]
fn include_source_info_and_imports() {
    let mut compiler = Compiler::with_file_resolver(TestFileResolver {
        files: &[("dep.proto", ""), ("root.proto", "import 'dep.proto';")],
    });

    compiler.include_imports(true);
    compiler.include_source_info(true);
    compiler.open_file("root.proto").unwrap();

    let files = compiler.file_descriptor_set();
    assert_eq!(
        files,
        FileDescriptorSet {
            file: vec![
                FileDescriptorProto {
                    name: Some("dep.proto".to_owned()),
                    source_code_info: Some(SourceCodeInfo {
                        location: vec![Location {
                            path: vec![],
                            span: vec![0, 0, 0],
                            ..Default::default()
                        },]
                    }),
                    ..Default::default()
                },
                FileDescriptorProto {
                    name: Some("root.proto".to_owned()),
                    dependency: vec!["dep.proto".to_owned()],
                    source_code_info: Some(SourceCodeInfo {
                        location: vec![
                            Location {
                                path: vec![],
                                span: vec![0, 0, 19],
                                ..Default::default()
                            },
                            Location {
                                path: vec![3, 0],
                                span: vec![0, 0, 19],
                                ..Default::default()
                            }
                        ]
                    }),
                    ..Default::default()
                },
            ],
        }
    );

    let encoded = compiler.encode_file_descriptor_set();
    assert_eq!(
        FileDescriptorSet::decode(encoded.as_slice()).unwrap(),
        files
    );
}

#[test]
fn pass_through_extension_options() {
    let mut resolver = ChainFileResolver::new();
    resolver.add(TestFileResolver {
        files: &[(
            "root.proto",
            "
            import 'google/protobuf/descriptor.proto';

            extend google.protobuf.FileOptions {
                optional int32 ext = 1001;
            }

            option (ext) = 1;
        ",
        )],
    });
    resolver.add(GoogleFileResolver::new());

    let mut compiler = Compiler::with_file_resolver(resolver);
    compiler.include_imports(true);
    compiler.open_file("root.proto").unwrap();

    let dyn_set = DescriptorPool::decode(compiler.encode_file_descriptor_set().as_slice()).unwrap();
    let ext = dyn_set.get_extension_by_name("ext").unwrap();
    assert_eq!(
        dyn_set
            .get_file_by_name("root.proto")
            .unwrap()
            .options()
            .get_extension(&ext)
            .as_ref(),
        &Value::I32(1)
    );

    let roundtripped_resolver =
        DescriptorSetFileResolver::decode(compiler.encode_file_descriptor_set().as_slice())
            .unwrap();
    let mut roundtripped_compiler = Compiler::with_file_resolver(roundtripped_resolver);
    roundtripped_compiler.include_imports(true);

    roundtripped_compiler.open_file("root.proto").unwrap();
    let roundtripped_dyn_set = DescriptorPool::decode(
        roundtripped_compiler
            .encode_file_descriptor_set()
            .as_slice(),
    )
    .unwrap();
    let roundtripped_ext = roundtripped_dyn_set.get_extension_by_name("ext").unwrap();
    assert_eq!(
        roundtripped_dyn_set
            .get_file_by_name("root.proto")
            .unwrap()
            .options()
            .get_extension(&roundtripped_ext)
            .as_ref(),
        &Value::I32(1)
    );
}

#[test]
fn error_fmt_debug() {
    let parse_err = check(&[("root.proto", "message {")]).unwrap_err();
    let check_err = check(&[("root.proto", "message Foo {} service Foo {}")]).unwrap_err();
    let import_err = check(&[("root.proto", "// comment \nimport 'notfound.proto';")]).unwrap_err();
    let open_err = check(&[("root.proto", "import 'customerror.proto';")]).unwrap_err();

    assert!(parse_err.is_parse());
    assert_eq!(parse_err.file(), Some("root.proto"));
    assert_eq!(
        parse_err.to_string(),
        "expected an identifier, but found '{'"
    );
    assert_eq!(
        format!("{:?}", parse_err),
        "root.proto:1:9: expected an identifier, but found '{'"
    );

    assert!(!check_err.is_io() && !check_err.is_parse());
    assert_eq!(check_err.file(), Some("root.proto"));
    assert_eq!(check_err.to_string(), "name 'Foo' is defined twice");
    assert_eq!(
        format!("{:?}", check_err),
        "root.proto:1:24: name 'Foo' is defined twice"
    );

    assert!(import_err.is_file_not_found());
    assert_eq!(import_err.file(), Some("root.proto"));
    assert_eq!(import_err.to_string(), "import 'notfound.proto' not found");
    assert_eq!(
        format!("{:?}", import_err),
        "root.proto:2:1: import 'notfound.proto' not found"
    );

    assert!(open_err.is_io());
    assert!(open_err.file().is_none());
    assert_eq!(open_err.to_string(), "failed to load file!");
    assert_eq!(
        format!("{:?}", open_err),
        "Custom { kind: Other, error: \"failed to load file!\" }"
    );
}

#[test]
fn error_invalid_utf8() {
    let dir = TempDir::new().unwrap();

    fs::write(dir.path().join("foo.proto"), b"message \xF0\x90\x80Foo {}").unwrap();

    let err = compile([dir.path().join("foo.proto")], [dir.path()]).unwrap_err();

    assert!(err.is_parse());
    assert_eq!(err.file(), Some("foo.proto"));
    assert_eq!(err.to_string(), "file 'foo.proto' is not valid utf-8");
    assert_eq!(format!("{:?}", err), "file 'foo.proto' is not valid utf-8");
}

#[test]
fn name_resolution_incorrect() {
    let test_data_dir =
        PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").unwrap()).join("tests/data");
    let error = protox::Compiler::new([test_data_dir])
        .unwrap()
        .include_imports(true)
        .include_source_info(true)
        .open_files(["name_resolution_incorrect.proto"])
        .unwrap_err();
    assert_eq!(
        error.to_string(),
        "'foo.Foo' resolves to 'com.foo.Foo', which is not defined"
    );
    assert_eq!(
        format!("{:?}", error),
        "name_resolution_incorrect.proto:10:5: 'foo.Foo' resolves to 'com.foo.Foo', which is not defined"
    );
    assert_eq!(format!("{}", error.help().unwrap()), "The innermost scope is searched first in name resolution. Consider using a leading '.' (i.e., '.foo.Foo') to start from the outermost scope.");
}

const EDITIONS_SOURCE: &str = r#"
edition = "2023";

package editions;

option features.field_presence = IMPLICIT;

message Message {
    int32 implicit = 1;
    int32 explicit = 2 [features.field_presence = EXPLICIT];
    repeated int32 expanded = 3 [features.repeated_field_encoding = EXPANDED];
    Message delimited = 4 [features.message_encoding = DELIMITED];
    map<string, string> map = 5 [features.utf8_validation = NONE];
}

enum Closed {
    option features.enum_type = CLOSED;
    ONE = 1;
}
"#;

#[test]
fn editions_file() {
    let compiler = check(&[("editions.proto", EDITIONS_SOURCE)]).unwrap();

    let pool = compiler.descriptor_pool();
    let file = pool.get_file_by_name("editions.proto").unwrap();
    assert_eq!(file.edition(), prost_reflect::Edition::Edition2023);
    let message = pool.get_message_by_name("editions.Message").unwrap();
    assert!(!message
        .get_field_by_name("implicit")
        .unwrap()
        .supports_presence());
    assert!(message
        .get_field_by_name("explicit")
        .unwrap()
        .supports_presence());
    assert!(!message.get_field_by_name("expanded").unwrap().is_packed());
    assert!(message.get_field_by_name("delimited").unwrap().is_group());
    let entry = message.get_field_by_name("map").unwrap().kind();
    let entry = entry.as_message().unwrap();
    assert_eq!(
        entry.map_entry_value_field().features().utf8_validation(),
        prost_reflect::Utf8Validation::None
    );
    assert!(pool
        .get_enum_by_name("editions.Closed")
        .unwrap()
        .is_closed());

    // The encoded set and the prost_types set both keep the edition.
    let encoded = compiler.encode_file_descriptor_set();
    let decoded = DescriptorPool::decode(encoded.as_slice()).unwrap();
    assert_eq!(
        decoded
            .get_file_by_name("editions.proto")
            .unwrap()
            .edition(),
        prost_reflect::Edition::Edition2023
    );
    let set = compiler.file_descriptor_set();
    assert_eq!(set.file[0].syntax(), "editions");
    assert_eq!(set.file[0].edition(), prost_types::Edition::Edition2023);
    let mut from_prost = DescriptorPool::new();
    from_prost.add_file_descriptor_set(set).unwrap();
    assert_eq!(
        from_prost
            .get_file_by_name("editions.proto")
            .unwrap()
            .edition(),
        prost_reflect::Edition::Edition2023
    );
}

#[test]
fn editions_file_error() {
    assert_yaml_snapshot!(check_err(&[(
        "editions.proto",
        r#"edition = "2023";

message Message {
    int32 foo = 1 [features.field_presence = IMPLICIT, default = 1];
}
"#
    )]));
}

const OPTIONS_SOURCE: &str = r#"edition = "2024";

package options;

import "google/protobuf/descriptor.proto";

message Tag {}

extend google.protobuf.FieldOptions {
    string label = 50001;
}
"#;

/// Compiles the last of `files`, which may import the well-known types.
fn check_with_google(files: &'static [(&'static str, &'static str)]) -> Result<Compiler, Error> {
    let mut resolver = ChainFileResolver::new();
    resolver.add(TestFileResolver { files });
    resolver.add(GoogleFileResolver::new());
    let mut compiler = Compiler::with_file_resolver(resolver);
    compiler.open_file(files[files.len() - 1].0)?;
    Ok(compiler)
}

#[test]
fn edition_2024_file() {
    let compiler = check_with_google(&[
        ("options.proto", OPTIONS_SOURCE),
        (
            "test.proto",
            r#"edition = "2024";

package test;

import option "options.proto";

export message Message {
    local message Nested {}
    string text = 1 [(options.label) = "hi"];
    Nested nested = 2;
}
"#,
        ),
    ])
    .unwrap();

    let pool = compiler.descriptor_pool();
    let file = pool.get_file_by_name("test.proto").unwrap();
    assert_eq!(file.edition(), prost_reflect::Edition::Edition2024);
    assert_eq!(file.option_dependencies().count(), 1);
    // The option-imported file is loaded, and the option resolves through it.
    let text = pool
        .get_message_by_name("test.Message")
        .unwrap()
        .get_field_by_name("text")
        .unwrap();
    let label = pool.get_extension_by_name("options.label").unwrap();
    assert_eq!(text.options().get_extension(&label).as_str(), Some("hi"));
    let nested = pool.get_message_by_name("test.Message.Nested").unwrap();
    assert_eq!(
        nested.visibility_keyword(),
        Some(prost_reflect::SymbolVisibility::Local)
    );

    let set = FileDescriptorSet::decode(compiler.encode_file_descriptor_set().as_slice()).unwrap();
    let test = set.file.iter().find(|f| f.name() == "test.proto").unwrap();
    assert_eq!(test.option_dependency, ["options.proto"]);
    assert_eq!(test.dependency, Vec::<String>::new());
    assert_eq!(
        test.message_type[0].visibility(),
        prost_types::SymbolVisibility::VisibilityExport
    );
}

#[test]
fn edition_2024_option_import_not_found() {
    assert_yaml_snapshot!(check_err(&[(
        "test.proto",
        r#"edition = "2024";

import option "missing.proto";
"#
    )]));
}

#[test]
fn edition_2024_type_through_option_import() {
    assert_yaml_snapshot!(error_to_json(
        &check_with_google(&[
            ("options.proto", OPTIONS_SOURCE),
            (
                "test.proto",
                r#"edition = "2024";

package test;

import option "options.proto";

message Message {
    options.Tag tag = 1;
}
"#,
            ),
        ])
        .unwrap_err()
    ));
}

#[test]
fn edition_2024_naming_style() {
    assert_yaml_snapshot!(check_err(&[(
        "test.proto",
        r#"edition = "2024";

package test;

message bad_name {
    int32 BadField = 1;
}
"#
    )]));
    check(&[(
        "test.proto",
        r#"edition = "2024";

package test;

option features.enforce_naming_style = STYLE_LEGACY;

message bad_name {}
"#,
    )])
    .unwrap();
}
