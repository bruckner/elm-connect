//! Writes google.protobuf.rs and google.protobuf.compiler.rs into OUT from
//! the protos under INCLUDE: the files prost-types' src/protobuf.rs and
//! src/compiler.rs hold.

use std::path::PathBuf;

/// The google.protobuf files prost-types generates types for, in the order
/// its src/protobuf.rs holds them. The wrappers and Empty map to Rust types
/// of their own (`Option<T>`, `()`), so prost-types has none.
const WELL_KNOWN: &[&str] = &[
    "google/protobuf/descriptor.proto",
    "google/protobuf/any.proto",
    "google/protobuf/source_context.proto",
    "google/protobuf/type.proto",
    "google/protobuf/api.proto",
    "google/protobuf/duration.proto",
    "google/protobuf/field_mask.proto",
    "google/protobuf/struct.proto",
    "google/protobuf/timestamp.proto",
];

fn main() {
    let mut args = std::env::args().skip(1);
    let include = PathBuf::from(args.next().expect("INCLUDE"));
    let out = PathBuf::from(args.next().expect("OUT"));
    std::fs::create_dir_all(&out).expect("create OUT");
    let mut files: Vec<PathBuf> = WELL_KNOWN.iter().map(|f| include.join(f)).collect();
    files.push(include.join("google/protobuf/compiler/plugin.proto"));
    prost_build::Config::new()
        .compile_well_known_types()
        // BTreeMap, as prost-types builds without std (its default feature).
        .btree_map(["."])
        .type_attribute(".", "#[cfg_attr(feature = \"arbitrary\", derive(arbitrary::Arbitrary))]")
        .out_dir(&out)
        .compile_protos(&files, &[include])
        .expect("generate");
}
