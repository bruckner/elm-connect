//! Routes resolved against their messages: path variables, bodies and
//! query parameters, and the problems reported instead.

use elm_connect_gen::ir::{HttpVerb, Method, Package};
use elm_connect_gen::route::{Body, FieldPath, PathSegment, QueryParam, Route, Segment};

use crate::common::{package, problems, render};

fn method<'a>(package: &'a Package, proto_name: &str) -> &'a Method {
    package
        .services
        .iter()
        .flat_map(|service| &service.methods)
        .find(|method| method.proto_name == proto_name)
        .unwrap_or_else(|| panic!("no method {proto_name}"))
}

fn path(proto: &str, json: &str) -> FieldPath {
    FieldPath {
        proto: proto.split('.').map(str::to_owned).collect(),
        json: json.split('.').map(str::to_owned).collect(),
    }
}

fn params(route: &Route) -> Vec<(String, Option<&str>)> {
    route
        .query
        .iter()
        .map(|QueryParam { field, zero }| (field.dotted(), zero.as_deref()))
        .collect()
}

const MESSAGES: &str = r#"
syntax = "proto3";
package messages.v1;
import "google/api/annotations.proto";
import "google/protobuf/timestamp.proto";
import "google/protobuf/wrappers.proto";
import "google/protobuf/empty.proto";

enum Kind { KIND_UNSPECIFIED = 0; KIND_TEXT = 1; }

message GetMessageRequest {
  message SubMessage { string subfield = 1; Kind kind = 2; }
  string message_id = 1;
  int64 revision = 2;
  SubMessage sub = 3;
  repeated string tags = 4;
  optional bool pinned = 5;
  google.protobuf.Timestamp since = 6;
  google.protobuf.Int32Value limit = 7;
  google.protobuf.Empty nothing = 8;
  oneof filter { string author = 9; Kind only = 10; }
}

message Message { string message_id = 1; string text = 2; repeated string lines = 3; }
message UpdateMessageRequest { string message_id = 1; Message message = 2; }

service Messaging {
  rpc GetMessage(GetMessageRequest) returns (Message) {
    option (google.api.http) = {
      get: "/v1/messages/{message_id}"
      additional_bindings { get: "/v1/messages/{message_id}/{sub.subfield}" }
    };
  }
  rpc UpdateMessage(UpdateMessageRequest) returns (Message) {
    option (google.api.http) = {
      patch: "/v1/{message.message_id=messages/*}"
      body: "message"
      response_body: "lines"
    };
  }
  rpc PutMessage(Message) returns (Message) {
    option (google.api.http) = {
      custom: { kind: "PUT" path: "/v1/messages/{message_id}:put" }
      body: "*"
    };
  }
  rpc Files(GetMessageRequest) returns (Message) {
    option (google.api.http) = { get: "/v1/{message_id=files/**}" };
  }
}
"#;

#[test]
fn query_parameters_are_every_leaf_outside_the_path() {
    let package = package(MESSAGES);
    let get = method(&package, "GetMessage");
    assert_eq!(get.routes.len(), 2);
    let route = &get.routes[0];
    assert_eq!(route.verb, HttpVerb::Get);
    assert_eq!(
        route.segments,
        [
            PathSegment::Literal("v1".into()),
            PathSegment::Literal("messages".into()),
            PathSegment::Variable {
                field: path("message_id", "messageId"),
                template: Vec::new(),
            },
        ]
    );
    assert_eq!(route.body, Body::None);
    assert_eq!(route.custom_verb, None);
    assert_eq!(
        params(route),
        [
            ("revision".into(), Some("0")),
            ("sub.subfield".into(), Some("")),
            ("sub.kind".into(), Some("KIND_UNSPECIFIED")),
            ("tags".into(), None),
            ("pinned".into(), None),
            ("since".into(), None),
            ("limit".into(), None),
            ("author".into(), None),
            ("only".into(), None),
        ]
    );

    let nested = &get.routes[1];
    assert_eq!(
        nested.segments[3],
        PathSegment::Variable {
            field: path("sub.subfield", "sub.subfield"),
            template: Vec::new(),
        }
    );
    assert!(
        params(nested)
            .iter()
            .all(|(name, _)| name != "sub.subfield")
    );
    assert!(params(nested).iter().any(|(name, _)| name == "sub.kind"));
}

#[test]
fn bodies_and_response_bodies() {
    let package = package(MESSAGES);
    let update = &method(&package, "UpdateMessage").routes[0];
    assert_eq!(update.verb, HttpVerb::Patch);
    assert_eq!(update.body, Body::Field(path("message", "message")));
    assert_eq!(update.response_body, Some(path("lines", "lines")));
    let PathSegment::Variable { field, template } = &update.segments[1] else {
        panic!("{update:?}")
    };
    assert_eq!(*field, path("message.message_id", "message.messageId"));
    assert_eq!(
        *template,
        [Segment::Literal("messages".into()), Segment::Wildcard]
    );
    assert!(!update.segments[1].is_single());
    assert_eq!(params(update), [("message_id".into(), Some(""))]);

    let put = &method(&package, "PutMessage").routes[0];
    assert_eq!(put.verb, HttpVerb::Custom("PUT".into()));
    assert_eq!(put.body, Body::All);
    assert_eq!(put.custom_verb.as_deref(), Some("put"));
    assert!(put.query.is_empty());

    let files = &method(&package, "Files").routes[0];
    assert!(!files.segments[1].is_single());
}

/// The problems the methods `rules` of a service on `Thing` report: each
/// as `code: message` on a line, then the rendering.
fn route_problems(rules: &str) -> String {
    let source = format!(
        r#"syntax = "proto3";
package t.v1;
import "google/api/annotations.proto";
import "google/protobuf/struct.proto";
import "google/protobuf/any.proto";
message Inner {{ string name = 1; repeated string tags = 2; }}
message Node {{ string id = 1; Node next = 2; }}
message Thing {{
  string name = 1;
  repeated string tags = 2;
  Inner inner = 3;
  map<string, string> labels = 4;
  repeated Inner inners = 5;
  google.protobuf.Struct extra = 6;
  Node node = 7;
  google.protobuf.Any packed = 8;
}}
service S {{
{rules}
}}
"#
    );
    let files = [("t.proto", source.as_str())];
    let diagnostics = problems(&files, &["t.proto"]);
    let lines: Vec<String> = diagnostics
        .iter()
        .map(|problem| format!("{}: {}", problem.code(), problem.message()))
        .collect();
    format!("{}\n\n{}", lines.join("\n"), render(&diagnostics, &files))
}

#[test]
fn each_route_problem_is_reported() {
    let cases = [
        (
            r#"get: "v1/{name}" body: "*""#,
            "route::template",
            "starts with `/`",
        ),
        (
            r#"get: "/v1/*" body: "*""#,
            "route::template",
            "wildcard outside a variable",
        ),
        (
            r#"get: "/v1/{missing}" body: "*""#,
            "route::path_field",
            "`t.v1.Thing` has no field `missing`",
        ),
        (
            r#"get: "/v1/{tags}" body: "*""#,
            "route::path_field",
            "`tags` is repeated",
        ),
        (
            r#"get: "/v1/{inner}" body: "*""#,
            "route::path_field",
            "is the message `t.v1.Inner`",
        ),
        (
            r#"get: "/v1/{name}/{name}" body: "*""#,
            "route::path_field",
            "twice",
        ),
        (
            r#"post: "/v1" body: "name""#,
            "route::body_field",
            "`name` is not a message",
        ),
        (
            r#"post: "/v1" body: "inners""#,
            "route::body_field",
            "`inners` is repeated",
        ),
        (
            r#"post: "/v1" body: "*" response_body: "nope""#,
            "route::response_body",
            "no such",
        ),
        (r#"get: "/v1""#, "route::query_field", "`labels`"),
        (
            r#"post: "/v1" body: "*" additional_bindings { get: "/v2" body: "*" additional_bindings { get: "/v3" } }"#,
            "route::rule",
            "additional bindings of its own",
        ),
        (r#"body: "*""#, "route::rule", "has no path"),
    ];
    for (index, (rule, code, text)) in cases.into_iter().enumerate() {
        let rules = format!(
            "  rpc M{index}(Thing) returns (Thing) {{ option (google.api.http) = {{ {rule} }}; }}"
        );
        let rendered = route_problems(&rules);
        assert!(rendered.starts_with(code), "{rule}\n{rendered}");
        assert!(rendered.contains(text), "{rule}: {text}\n{rendered}");
    }
}

#[test]
fn query_fields_without_a_query_form_are_named() {
    let rendered = route_problems(
        r#"  rpc Get(Thing) returns (Thing) { option (google.api.http) = { get: "/v1/{name}" }; }"#,
    );
    let problems: Vec<&str> = rendered
        .lines()
        .take_while(|line| !line.is_empty())
        .collect();
    assert_eq!(problems.len(), 5, "{rendered}");
    assert!(
        problems
            .iter()
            .all(|line| line.starts_with("route::query_field: ")),
        "{rendered}"
    );
    for expected in [
        "sends `labels` as a query parameter, but it is a map",
        "sends `inners` as a query parameter, but it is a repeated message",
        "`google.protobuf.Struct` is free-form JSON",
        "`t.v1.Node` contains itself",
        "sends `packed` as a query parameter, but `google.protobuf.Any` holds a message",
    ] {
        assert!(rendered.contains(expected), "{expected}\n{rendered}");
    }
}

#[test]
fn a_well_known_request_leaves_nothing_to_the_query() {
    let header = r#"syntax = "proto3";
package t.v1;
import "google/api/annotations.proto";
import "google/protobuf/empty.proto";
import "google/protobuf/timestamp.proto";
message Thing { string name = 1; }
"#;
    let built = package(&format!(
        r#"{header}service S {{
  rpc Ping(google.protobuf.Empty) returns (Thing) {{ option (google.api.http) = {{ get: "/v1/ping" }}; }}
  rpc At(google.protobuf.Timestamp) returns (Thing) {{ option (google.api.http) = {{ post: "/v1/at" body: "*" }}; }}
}}
"#
    ));
    assert!(params(&method(&built, "Ping").routes[0]).is_empty());
    assert!(params(&method(&built, "At").routes[0]).is_empty());

    let source = format!(
        r#"{header}service S {{
  rpc At(google.protobuf.Timestamp) returns (Thing) {{ option (google.api.http) = {{ get: "/v1/at" }}; }}
}}
"#
    );
    let files = [("t.proto", source.as_str())];
    let rendered = render(&problems(&files, &["t.proto"]), &files);
    assert!(rendered.starts_with("route::query_field"), "{rendered}");
    assert!(rendered.contains("well-known type"), "{rendered}");
}

#[test]
fn a_route_problem_points_at_the_rule() {
    let rendered = route_problems(
        r#"  rpc Get(Thing) returns (Thing) { option (google.api.http) = { get: "/v1/{missing}" body: "*" }; }"#,
    );
    assert!(rendered.contains("╭─[t.proto:19:36]"), "{rendered}");
    assert!(rendered.contains("in this rule"), "{rendered}");
    assert!(
        rendered.contains("The HTTP rule of `t.v1.S.Get` binds `{missing}`"),
        "{rendered}"
    );
}
