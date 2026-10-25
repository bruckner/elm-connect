//! `compare-descriptors <corpus> <googleapis> <name=set.binpb>...`
//!
//! Compiles the corpus files with the vendored protox and compares, for every reference set
//! (a `FileDescriptorSet` built by buf or protoc from the same files), each corpus file's
//! descriptor field for field (as canonical JSON, source info removed), then the features and
//! derived properties the vendored prost-reflect resolves for every element from the reference
//! set and from protox's own parse. Prints every difference; exits 1 if there are any.

use std::{collections::BTreeMap, path::PathBuf};

use prost_reflect::{DescriptorPool, DynamicMessage, MessageDescriptor};
use serde_json::Value;

const FILES: &[&str] = &[
    "test_messages_edition2023.proto",
    "test_messages_proto3_editions.proto",
    "notes/v1/notes.proto",
    "matrix/v1/matrix.proto",
];

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let corpus = PathBuf::from(&args[0]);
    let googleapis = PathBuf::from(&args[1]);
    let references: Vec<(String, Vec<u8>)> = args[2..]
        .iter()
        .map(|arg| {
            let (name, path) = arg.split_once('=').expect("name=path");
            (name.to_owned(), std::fs::read(path).expect("read the set"))
        })
        .collect();

    let mut compiler = protox::Compiler::new([corpus, googleapis]).expect("include paths");
    compiler.include_imports(true).include_source_info(false);
    if let Err(err) = compiler.open_files(FILES) {
        eprintln!("protox: {err:?}");
        std::process::exit(2);
    }
    let fork = files_by_name(&compiler.encode_file_descriptor_set());
    let fork_pool = compiler.descriptor_pool();

    // COMPARE_DUMP=<file> prints protox's descriptor and resolved features for that file.
    if let Ok(file) = std::env::var("COMPARE_DUMP") {
        println!("{}", serde_json::to_string_pretty(&fork[&file]).unwrap());
        for (element, line) in feature_lines(&fork_pool, &file) {
            println!("{element}: {line}");
        }
        return;
    }

    let mut differences = 0;
    for (name, bytes) in &references {
        let reference = files_by_name(bytes);
        println!("== descriptors: {name} vs protox");
        for file in FILES {
            let mut diffs = Vec::new();
            diff("", &reference[*file], &fork[*file], &mut diffs);
            println!("{file}: {} difference(s)", diffs.len());
            for d in &diffs {
                println!("  {d}");
            }
            differences += diffs.len();
        }

        println!("== features: pool from {name}'s set vs pool from protox");
        let reference_pool = match DescriptorPool::decode(bytes.as_slice()) {
            Ok(pool) => pool,
            Err(err) => {
                println!("  prost-reflect refuses {name}'s set: {err:?}");
                differences += 1;
                continue;
            }
        };
        for file in FILES {
            let expected = feature_lines(&reference_pool, file);
            let actual = feature_lines(&fork_pool, file);
            let mut count = 0;
            for (element, line) in &expected {
                match actual.get(element) {
                    Some(other) if other == line => (),
                    other => {
                        count += 1;
                        println!("  {element}\n    {name}: {line}\n    protox: {other:?}");
                    }
                }
            }
            for element in actual.keys().filter(|e| !expected.contains_key(*e)) {
                count += 1;
                println!("  {element}: only in protox's pool");
            }
            println!("{file}: {} element(s), {count} difference(s)", expected.len());
            differences += count;
        }
    }

    if differences > 0 {
        std::process::exit(1);
    }
}

/// The files of an encoded `FileDescriptorSet`, by name, as canonical JSON without source info.
fn files_by_name(bytes: &[u8]) -> BTreeMap<String, Value> {
    let set_desc = DescriptorPool::global()
        .get_message_by_name("google.protobuf.FileDescriptorSet")
        .unwrap();
    let set = DynamicMessage::decode(set_desc, bytes).expect("a FileDescriptorSet");
    set.get_field_by_name("file")
        .unwrap()
        .as_list()
        .unwrap()
        .iter()
        .map(|file| {
            let mut file = file.as_message().unwrap().clone();
            file.clear_field_by_name("source_code_info");
            let name = file.get_field_by_name("name").unwrap().as_str().unwrap().to_owned();
            (name, serde_json::to_value(&file).unwrap())
        })
        .collect()
}

fn diff(path: &str, expected: &Value, actual: &Value, out: &mut Vec<String>) {
    match (expected, actual) {
        (Value::Object(e), Value::Object(a)) => {
            for (key, ev) in e {
                match a.get(key) {
                    Some(av) => diff(&format!("{path}/{key}"), ev, av, out),
                    None => out.push(format!("{path}/{key}: reference {ev}, protox absent")),
                }
            }
            for (key, av) in a {
                if !e.contains_key(key) {
                    out.push(format!("{path}/{key}: reference absent, protox {av}"));
                }
            }
        }
        (Value::Array(e), Value::Array(a)) if e.len() == a.len() => {
            for (i, (ev, av)) in e.iter().zip(a).enumerate() {
                diff(&format!("{path}/{i}"), ev, av, out);
            }
        }
        _ if expected == actual => (),
        _ => out.push(format!("{path}: reference {expected}, protox {actual}")),
    }
}

/// Every element of `file` with its resolved features and the properties derived from them.
fn feature_lines(pool: &DescriptorPool, file: &str) -> BTreeMap<String, String> {
    let mut lines = BTreeMap::new();
    let file = pool.get_file_by_name(file).expect("the file in the pool");
    lines.insert(
        format!("file {}", file.name()),
        format!("{:?} {:?} {:?}", file.syntax(), file.edition(), file.features()),
    );
    fn message(lines: &mut BTreeMap<String, String>, m: MessageDescriptor) {
        lines.insert(format!("message {}", m.full_name()), format!("{:?}", m.features()));
        for f in m.fields() {
            lines.insert(
                format!("field {}", f.full_name()),
                format!(
                    "{:?} presence={} packed={} group={} cardinality={:?} default={:?}",
                    f.features(),
                    f.supports_presence(),
                    f.is_packed(),
                    f.is_group(),
                    f.cardinality(),
                    // A message's default would print its descriptor, recursively.
                    match f.kind() {
                        prost_reflect::Kind::Message(_) => None,
                        _ => Some(f.default_value()),
                    }
                ),
            );
        }
        for o in m.oneofs() {
            lines.insert(format!("oneof {}", o.full_name()), format!("{:?}", o.features()));
        }
        for e in m.child_extensions() {
            extension(lines, e);
        }
        for e in m.child_enums() {
            enum_(lines, e);
        }
        for c in m.child_messages() {
            message(lines, c);
        }
    }
    fn extension(lines: &mut BTreeMap<String, String>, e: prost_reflect::ExtensionDescriptor) {
        lines.insert(
            format!("extension {}", e.full_name()),
            format!(
                "{:?} packed={} group={} cardinality={:?}",
                e.features(),
                e.is_packed(),
                e.is_group(),
                e.cardinality()
            ),
        );
    }
    fn enum_(lines: &mut BTreeMap<String, String>, e: prost_reflect::EnumDescriptor) {
        lines.insert(
            format!("enum {}", e.full_name()),
            format!("{:?} closed={}", e.features(), e.is_closed()),
        );
        for v in e.values() {
            lines.insert(format!("value {}", v.full_name()), format!("{:?}", v.features()));
        }
    }
    for m in file.messages() {
        message(&mut lines, m);
    }
    for e in file.enums() {
        enum_(&mut lines, e);
    }
    for e in file.extensions() {
        extension(&mut lines, e);
    }
    for s in file.services() {
        lines.insert(format!("service {}", s.full_name()), format!("{:?}", s.features()));
        for m in s.methods() {
            lines.insert(format!("method {}", m.full_name()), format!("{:?}", m.features()));
        }
    }
    lines
}
