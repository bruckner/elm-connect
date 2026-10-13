//! Services and methods in the IR: names, types, idempotency, the
//! `google.api.http` rule as written, and the problems reported instead.

use elm_connect_gen::diagnostics::{Code, Diagnostics};
use elm_connect_gen::ir::{HttpRule, HttpVerb, Method, Package, TypeName, TypeRef, WellKnown};

use crate::common::{package, problems, render};

fn method<'a>(package: &'a Package, proto_name: &str) -> &'a Method {
    package
        .services
        .iter()
        .flat_map(|service| &service.methods)
        .find(|method| method.proto_name == proto_name)
        .unwrap_or_else(|| panic!("no method {proto_name} in {package:#?}"))
}

fn codes(diagnostics: &Diagnostics) -> Vec<Code> {
    diagnostics.iter().map(|problem| problem.code()).collect()
}

const NOTES: &str = r#"
syntax = "proto3";
package notes.v1;
import "google/api/annotations.proto";
import "google/protobuf/empty.proto";

message Note { string name = 1; }
message GetNoteRequest { string name = 1; }

service Notes {
  rpc GetNote(GetNoteRequest) returns (Note) {
    option idempotency_level = NO_SIDE_EFFECTS;
    option (google.api.http) = {
      get: "/v1/{name=notes/*}"
      additional_bindings { get: "/v1/{name=users/*/notes/*}" }
      additional_bindings {
        custom: { kind: "HEAD" path: "/v1/{name=notes/*}" }
        response_body: "name"
      }
    };
  }
  rpc UpdateNote(Note) returns (Note) {
    option (google.api.http) = { patch: "/v1/{name=notes/*}" body: "*" };
  }
  rpc Purge(google.protobuf.Empty) returns (google.protobuf.Empty);
}
"#;

#[test]
fn methods_are_named_and_typed() {
    let package = package(NOTES);
    assert_eq!(package.services.len(), 1);
    assert_eq!(package.services[0].proto_full_name, "notes.v1.Notes");
    assert_eq!(package.services[0].module.to_string(), "Notes.V1.Notes");
    let names: Vec<_> = package.services[0]
        .methods
        .iter()
        .map(|method| (method.proto_name.as_str(), method.elm_name.as_str()))
        .collect();
    assert_eq!(
        names,
        [
            ("GetNote", "getNote"),
            ("UpdateNote", "updateNote"),
            ("Purge", "purge")
        ]
    );

    let get = method(&package, "GetNote");
    let note = |name: &str| {
        TypeRef::Message(TypeName {
            module: package.module.clone(),
            name: name.into(),
        })
    };
    assert_eq!(get.input, note("GetNoteRequest"));
    assert_eq!(get.output, note("Note"));
    assert!(get.idempotent);
    assert!(!method(&package, "UpdateNote").idempotent);

    let purge = method(&package, "Purge");
    assert_eq!(purge.input, TypeRef::WellKnown(WellKnown::Empty));
    assert_eq!(purge.output, TypeRef::WellKnown(WellKnown::Empty));
    assert_eq!(purge.http, None);
}

#[test]
fn the_http_rule_is_read_as_written() {
    let package = package(NOTES);
    let get = method(&package, "GetNote");
    let rule = |verb, template: &str, body: &str, response_body: &str| HttpRule {
        verb,
        template: template.into(),
        body: body.into(),
        response_body: response_body.into(),
        additional_bindings: Vec::new(),
    };
    let mut expected = rule(HttpVerb::Get, "/v1/{name=notes/*}", "", "");
    expected.additional_bindings = vec![
        rule(HttpVerb::Get, "/v1/{name=users/*/notes/*}", "", ""),
        rule(
            HttpVerb::Custom("HEAD".into()),
            "/v1/{name=notes/*}",
            "",
            "name",
        ),
    ];
    assert_eq!(get.http.as_ref(), Some(&expected));
    assert_eq!(
        method(&package, "UpdateNote").http,
        Some(rule(HttpVerb::Patch, "/v1/{name=notes/*}", "*", ""))
    );
}

const STREAMING: &str = r#"syntax = "proto3";
package chat.v1;
message Line { string text = 1; }
service Chat {
  rpc Listen(Line) returns (stream Line);
  rpc Say(stream Line) returns (Line);
  rpc Talk(stream Line) returns (stream Line);
}
"#;

#[test]
fn streaming_methods_are_errors() {
    let files = [("chat.proto", STREAMING)];
    let diagnostics = problems(&files, &["chat.proto"]);
    assert_eq!(codes(&diagnostics), [Code::Streaming; 3]);
    let rendered = render(&diagnostics, &files);
    assert!(
        rendered.contains("`chat.v1.Chat.Listen` is server streaming"),
        "{rendered}"
    );
    assert!(
        rendered.contains("`chat.v1.Chat.Say` is client streaming"),
        "{rendered}"
    );
    assert!(
        rendered.contains("`chat.v1.Chat.Talk` is bidirectional streaming"),
        "{rendered}"
    );
    assert!(rendered.contains("streams here"), "{rendered}");
}

#[test]
fn method_types_must_be_generated() {
    let other = "syntax = \"proto3\"; package other.v1; message Thing {}";
    let notes = r#"syntax = "proto3";
package notes.v1;
import "other.proto";
import "google/protobuf/any.proto";
service Notes {
  rpc Get(other.v1.Thing) returns (google.protobuf.Any);
}
"#;
    let files = [("other.proto", other), ("notes.proto", notes)];
    let diagnostics = problems(&files, &["notes.proto"]);
    assert_eq!(codes(&diagnostics), [Code::NotGenerated, Code::Any]);
    let rendered = render(&diagnostics, &files);
    assert!(
        rendered.contains("The request of `notes.v1.Notes.Get` refers to `other.v1.Thing`"),
        "{rendered}"
    );
    assert!(
        rendered.contains("The response of `notes.v1.Notes.Get` has type `google.protobuf.Any`"),
        "{rendered}"
    );
}

#[test]
fn method_values_share_only_their_service_namespace() {
    let source = r#"syntax = "proto3";
package t.v1;
message Settings {}
message Value {}
service A {
  rpc DefaultSettings(Settings) returns (Settings);
  rpc EncodeSettings(Settings) returns (Settings);
  rpc Value(Settings) returns (Value);
  rpc Identity(Settings) returns (Settings);
  rpc Get(Settings) returns (Settings);
}
service B {
  rpc Get(Settings) returns (Settings);
}
"#;
    let package = package(source);
    let modules: Vec<String> = package
        .services
        .iter()
        .map(|service| service.module.to_string())
        .collect();
    assert_eq!(modules, ["T.V1.A", "T.V1.B"]);
    assert_eq!(package.services[0].methods.len(), 5);
    assert_eq!(package.services[1].methods[0].elm_name, "get");
}

#[test]
fn methods_of_one_service_collide() {
    let source = r#"syntax = "proto3";
package t.v1;
message Note {}
service Notes {
  rpc GetNote(Note) returns (Note);
  rpc Get_Note(Note) returns (Note);
}
"#;
    let files = [("t.proto", source)];
    let diagnostics = problems(&files, &["t.proto"]);
    assert_eq!(codes(&diagnostics), [Code::ValueCollision]);
    assert_eq!(
        diagnostics.iter().next().map(|problem| problem.message()),
        Some("The service `t.v1.Notes` has two methods that both become the Elm value `getNote`.")
    );
    let rendered = render(&diagnostics, &files);
    for expected in [
        "method `t.v1.Notes.GetNote` becomes `getNote`",
        "and so does method `t.v1.Notes.Get_Note`",
    ] {
        assert!(rendered.contains(expected), "{expected}\n{rendered}");
    }
}

#[test]
fn a_service_may_share_a_type_name() {
    // Proto forbids a message and a service of one name in a package, but
    // not two whose Elm names coincide; a module and a type do not clash.
    let source = r#"syntax = "proto3";
package t.v1;
message notes {}
service Notes {
  rpc Notes(notes) returns (notes);
}
"#;
    let package = package(source);
    assert_eq!(package.services[0].module.to_string(), "T.V1.Notes");
    assert_eq!(package.services[0].methods[0].elm_name, "notes");
}

#[test]
fn services_of_one_package_collide_by_module() {
    let source = r#"syntax = "proto3";
package t.v1;
message Note {}
service Notes {
  rpc Get(Note) returns (Note);
}
service notes {
  rpc Get(Note) returns (Note);
}
"#;
    let files = [("t.proto", source)];
    let diagnostics = problems(&files, &["t.proto"]);
    assert_eq!(codes(&diagnostics), [Code::ModuleCollision]);
    let rendered = render(&diagnostics, &files);
    for expected in [
        "Two generated modules both become the Elm module `T.V1.Notes`",
        "service `t.v1.Notes` becomes `T.V1.Notes`",
        "and so does service `t.v1.notes`",
    ] {
        assert!(rendered.contains(expected), "{expected}\n{rendered}");
    }
}

#[test]
fn a_service_collides_with_a_package_module() {
    let outer = r#"syntax = "proto3";
package notes.v1;
message Note {}
service NotesService {
  rpc Get(Note) returns (Note);
}
"#;
    let inner = "syntax = \"proto3\"; package notes.v1.notes_service; message Other {}";
    let files = [("outer.proto", outer), ("inner.proto", inner)];
    let diagnostics = problems(&files, &["outer.proto", "inner.proto"]);
    assert_eq!(codes(&diagnostics), [Code::ModuleCollision]);
    let rendered = render(&diagnostics, &files);
    for expected in [
        "`Notes.V1.NotesService`",
        "package `notes.v1.notes_service` becomes `Notes.V1.NotesService`",
        "and so does service `notes.v1.NotesService`",
    ] {
        assert!(rendered.contains(expected), "{expected}\n{rendered}");
    }
}

#[test]
fn packages_collide_by_module() {
    let lower = "syntax = \"proto3\"; package notes.v1; message A {}";
    let upper = "syntax = \"proto3\"; package notes.V1; message B {}";
    let files = [("lower.proto", lower), ("upper.proto", upper)];
    let diagnostics = problems(&files, &["lower.proto", "upper.proto"]);
    assert_eq!(codes(&diagnostics), [Code::ModuleCollision]);
    let rendered = render(&diagnostics, &files);
    assert!(
        rendered.contains("package `notes.V1` becomes `Notes.V1`"),
        "{rendered}"
    );
}

#[test]
fn a_service_needs_a_module_name() {
    let source = r#"syntax = "proto3";
package t.v1;
message Note {}
service _1Notes {
  rpc Get(Note) returns (Note);
}
"#;
    let files = [("t.proto", source)];
    let diagnostics = problems(&files, &["t.proto"]);
    assert_eq!(codes(&diagnostics), [Code::InvalidService]);
    let rendered = render(&diagnostics, &files);
    assert!(
        rendered.contains("The service `t.v1._1Notes` cannot become an Elm module name"),
        "{rendered}"
    );
}
