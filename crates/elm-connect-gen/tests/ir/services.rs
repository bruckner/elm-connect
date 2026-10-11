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
    assert!(purge.http_call_names().is_empty());
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
        get.http_call_names(),
        ["getNoteHttp", "getNoteHttp2", "getNoteHttp3"]
    );
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
fn method_values_share_the_module_namespace() {
    let source = r#"syntax = "proto3";
package t.v1;
import "google/api/annotations.proto";
message Settings {}
service A {
  rpc DefaultSettings(Settings) returns (Settings);
  rpc Get(Settings) returns (Settings) {
    option (google.api.http) = { get: "/a" };
  }
  rpc GetHttp(Settings) returns (Settings);
  rpc Value(Settings) returns (Settings);
}
service B {
  rpc Get(Settings) returns (Settings);
}
"#;
    let files = [("t.proto", source)];
    let diagnostics = problems(&files, &["t.proto"]);
    assert_eq!(
        codes(&diagnostics),
        [Code::ValueCollision; 4],
        "{}",
        render(&diagnostics, &files)
    );
    let messages: Vec<&str> = diagnostics
        .iter()
        .map(|problem| problem.message())
        .collect();
    for (message, name) in messages
        .iter()
        .zip(["defaultSettings", "getHttp", "value", "get"])
    {
        assert!(
            message.contains(&format!("Elm value `{name}`")),
            "{message}"
        );
    }
    let rendered = render(&diagnostics, &files);
    for expected in [
        "the default of message `t.v1.Settings` becomes `defaultSettings`",
        "and so does method `t.v1.A.DefaultSettings`",
        "the HTTP rule of `t.v1.A.Get` becomes `getHttp`",
    ] {
        assert!(rendered.contains(expected), "{expected}\n{rendered}");
    }
}
