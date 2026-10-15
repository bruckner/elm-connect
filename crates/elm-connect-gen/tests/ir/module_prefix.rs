//! `module_prefix` in the IR: every generated module goes inside it,
//! renamed or derived, and the problems that name a module name the
//! prefixed one.

use elm_connect_gen::Options;
use elm_connect_gen::diagnostics::{Code, Diagnostics};
use elm_connect_gen::ir::{self, Package};

use crate::common::pool;

const NOTES: &str = r#"syntax = "proto3";
package notes.v1;
import "users.proto";
message Note { users.v1.User author = 1; }
service NotesService {
  rpc GetNote(Note) returns (Note);
}
"#;

const USERS: &str = r#"syntax = "proto3";
package users.v1;
message User {}
"#;

fn build(parameter: &str) -> Result<Vec<Package>, Diagnostics> {
    let options = Options::from_parameter(parameter).expect("options");
    let files = [("notes.proto", NOTES), ("users.proto", USERS)];
    ir::build_with(&pool(&files), &["notes.proto", "users.proto"], &options)
        .map(|built| built.packages)
}

/// Each package's module, and its services', in order.
fn modules(packages: &[Package]) -> Vec<String> {
    packages
        .iter()
        .flat_map(|package| {
            let services = package.services.iter().map(|s| s.module.to_string());
            std::iter::once(package.module.to_string()).chain(services)
        })
        .collect()
}

#[test]
fn every_generated_module_goes_inside_the_prefix() {
    let packages = build("module_prefix=Api.Example").expect("builds");
    assert_eq!(
        modules(&packages),
        [
            "Api.Example.Notes.V1",
            "Api.Example.Notes.V1.NotesService",
            "Api.Example.Users.V1",
        ]
    );
}

#[test]
fn a_renamed_module_goes_inside_the_prefix_too() {
    let packages =
        build("module_prefix=Api,rename=notes.v1:Memos,rename=notes.v1.NotesService:Service")
            .expect("builds");
    assert_eq!(
        modules(&packages),
        ["Api.Memos", "Api.Memos.Service", "Api.Users.V1"]
    );
}

#[test]
fn a_module_collision_names_the_prefixed_module() {
    let diagnostics =
        build("module_prefix=Api,rename=notes.v1:Users.V1").expect_err("two `Api.Users.V1`");
    let problems: Vec<_> = diagnostics.iter().collect();
    assert_eq!(problems.len(), 1);
    assert_eq!(problems[0].code(), Code::ModuleCollision);
    assert!(
        problems[0].message().contains("`Api.Users.V1`"),
        "{}",
        problems[0].message()
    );
}
