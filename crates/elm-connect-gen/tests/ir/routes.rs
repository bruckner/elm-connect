//! Routes resolved against their messages: path variables, bodies and
//! query parameters, and the problems reported instead.

use elm_connect_gen::ir::{HttpVerb, Method, ModuleName, Package};
use elm_connect_gen::route::{Body, FieldPath, FieldRef, PathSegment, QueryParam, Route, Segment};

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

/// `Messages.V1.Type.name`, a field as generated code names its
/// descriptor.
fn field_ref(dotted: &str) -> FieldRef {
    let (module, name) = dotted.rsplit_once('.').expect("a module and a name");
    FieldRef {
        module: ModuleName::parse(module).expect("a module name"),
        name: name.to_owned(),
    }
}

/// Each parameter's dotted proto path, with its fields as generated code
/// names their descriptors.
fn params(route: &Route) -> Vec<(String, Vec<String>)> {
    route
        .query
        .iter()
        .map(|QueryParam { field, fields }| {
            let refs = fields
                .iter()
                .map(|field| format!("{}.{}", field.module, field.name))
                .collect();
            (field.dotted(), refs)
        })
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
  rpc Typed(GetMessageRequest) returns (Message) {
    option (google.api.http) = { get: "/v1/{revision}/{sub.kind}/{pinned}/{message_id}" };
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
                fields: vec![field_ref("Messages.V1.GetMessageRequest.messageId")],
            },
        ]
    );
    assert_eq!(route.body, Body::None);
    assert_eq!(route.custom_verb, None);
    let request = |name: &str| format!("Messages.V1.GetMessageRequest.{name}");
    let sub = |name: &str| format!("Messages.V1.GetMessageRequestSubMessage.{name}");
    assert_eq!(
        params(route),
        [
            ("revision".into(), vec![request("revision")]),
            ("sub.subfield".into(), vec![request("sub"), sub("subfield")]),
            ("sub.kind".into(), vec![request("sub"), sub("kind")]),
            ("tags".into(), vec![request("tags")]),
            ("pinned".into(), vec![request("pinned")]),
            ("since".into(), vec![request("since")]),
            ("limit".into(), vec![request("limit")]),
            ("author".into(), vec![request("author")]),
            ("only".into(), vec![request("only")]),
        ]
    );

    let nested = &get.routes[1];
    assert_eq!(
        nested.segments[3],
        PathSegment::Variable {
            field: path("sub.subfield", "sub.subfield"),
            template: Vec::new(),
            fields: vec![
                field_ref("Messages.V1.GetMessageRequest.sub"),
                field_ref("Messages.V1.GetMessageRequestSubMessage.subfield"),
            ],
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
fn a_path_variable_names_each_field_of_its_path() {
    // The runtime reads the text of a field's default from the last one
    // (`Proto.Http.variable`).
    let package = package(MESSAGES);
    let typed = &method(&package, "Typed").routes[0];
    let leaves: Vec<&str> = typed
        .segments
        .iter()
        .filter_map(|segment| match segment {
            PathSegment::Variable { fields, .. } => fields.last().map(|f| f.name.as_str()),
            PathSegment::Literal(_) => None,
        })
        .collect();
    assert_eq!(leaves, ["revision", "kind", "pinned", "messageId"]);
}

#[test]
fn bodies_and_response_bodies() {
    let package = package(MESSAGES);
    let update = &method(&package, "UpdateMessage").routes[0];
    assert_eq!(update.verb, HttpVerb::Patch);
    assert_eq!(update.body, Body::Field(path("message", "message")));
    assert_eq!(update.response_body, Some(path("lines", "lines")));
    let PathSegment::Variable {
        field, template, ..
    } = &update.segments[1]
    else {
        panic!("{update:?}")
    };
    assert_eq!(*field, path("message.message_id", "message.messageId"));
    assert_eq!(
        *template,
        [Segment::Literal("messages".into()), Segment::Wildcard]
    );
    assert!(!update.segments[1].is_single());
    assert_eq!(
        params(update),
        [(
            "message_id".into(),
            vec!["Messages.V1.UpdateMessageRequest.messageId".to_owned()]
        )]
    );

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
fn a_path_variable_of_a_well_known_request_is_refused() {
    // Its JSON is not an object of its fields, so no field reads a value.
    let rendered = route_problems(
        r#"  rpc Get(google.protobuf.Struct) returns (Thing) { option (google.api.http) = { get: "/v1/{fields}" }; }"#,
    );
    assert!(rendered.starts_with("route::path_field"), "{rendered}");
    assert!(
        rendered
            .contains("the request is `google.protobuf.Struct`, whose fields have no JSON form"),
        "{rendered}"
    );
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
fn a_cycle_is_refused_where_it_is_held() {
    // A ring of messages, each holding the next and a map, with a GET
    // rule on every fourth. Each rule is refused twice: its own map, and
    // `next`, whose message holds itself. Expanding `next` instead walked
    // the ring and refused every map along it at every depth, once per
    // rule, which on a long ring exhausted memory.
    let n = 400;
    let mut source = String::from(
        "syntax = \"proto3\";\npackage t.v1;\nimport \"google/api/annotations.proto\";\n",
    );
    for i in 0..n {
        let next = (i + 1) % n;
        source += &format!(
            "message M{i} {{ string name = 1; map<string, int32> m = 2; M{next} next = 3; }}\n"
        );
    }
    source += "service S {\n";
    for i in (0..n).step_by(4) {
        source += &format!(
            "  rpc Get{i}(M{i}) returns (M{i}) {{ option (google.api.http) = {{ get: \"/v1/m{i}\" }}; }}\n"
        );
    }
    source += "}\n";
    let files = [("t.proto", source.as_str())];
    let diagnostics = problems(&files, &["t.proto"]);
    let messages: Vec<String> = diagnostics
        .iter()
        .map(|problem| format!("{}: {}", problem.code(), problem.message()))
        .collect();
    assert_eq!(messages.len(), n / 2, "{}", messages.join("\n"));
    assert!(
        messages.contains(
            &"route::query_field: The HTTP rule of `t.v1.S.Get0` sends `next` as a query \
              parameter, but `t.v1.M1` contains itself, which has no query form."
                .to_owned()
        ),
        "{}",
        messages.join("\n")
    );
    assert!(
        messages.iter().all(|message| !message.contains("next.")),
        "{}",
        messages.join("\n")
    );
}

#[test]
fn a_cycle_through_a_side_branch_is_found() {
    // `A` holds `B`, which holds `A`, closing a cycle before `A`'s second
    // field `c` is looked at; `C` holds `B`, so it lies on a cycle too, one
    // a walk that only looks for a message on its own path would miss once
    // `B` is finished. Every field holding a message on a cycle is refused.
    let source = r#"syntax = "proto3";
package t.v1;
import "google/api/annotations.proto";
message A { B b = 1; C c = 2; string name = 3; }
message B { A a = 1; }
message C { B b = 1; string name = 2; }
message Side { C c = 1; }
service S {
  rpc GetA(A) returns (A) { option (google.api.http) = { get: "/v1/a" }; }
  rpc GetSide(Side) returns (Side) { option (google.api.http) = { get: "/v1/side" }; }
}
"#;
    let files = [("t.proto", source)];
    let diagnostics = problems(&files, &["t.proto"]);
    let messages: Vec<String> = diagnostics
        .iter()
        .map(|problem| format!("{}: {}", problem.code(), problem.message()))
        .collect();
    assert_eq!(
        messages,
        [
            "route::query_field: The HTTP rule of `t.v1.S.GetA` sends `b` as a query parameter, \
             but `t.v1.B` contains itself, which has no query form.",
            "route::query_field: The HTTP rule of `t.v1.S.GetA` sends `c` as a query parameter, \
             but `t.v1.C` contains itself, which has no query form.",
            "route::query_field: The HTTP rule of `t.v1.S.GetSide` sends `c` as a query \
             parameter, but `t.v1.C` contains itself, which has no query form.",
        ]
    );
}

/// A chain of `n` messages, each holding the next in `next`, the last a
/// leaf, and the service `S` with a GET rule for each request in `gets`.
fn chain(n: usize, gets: &[(usize, &str)]) -> String {
    let mut source = String::from(
        "syntax = \"proto3\";\npackage t.v1;\nimport \"google/api/annotations.proto\";\n",
    );
    for i in 0..n {
        source += &format!("message M{i} {{ string v = 1;");
        if i + 1 < n {
            source += &format!(" M{} next = 2;", i + 1);
        }
        source += " }\n";
    }
    source += "service S {\n";
    for (i, template) in gets {
        source += &format!(
            "  rpc Get{i}(M{i}) returns (M{i}) {{ option (google.api.http) = {{ get: \"{template}\" }}; }}\n"
        );
    }
    source + "}\n"
}

#[test]
fn a_query_reaches_the_nesting_limit() {
    // M0 holds M1 through M100: 100 messages below the request, which a
    // protobuf parser reads, so every leaf is a parameter.
    let built = package(&chain(101, &[(0, "/v1/m")]));
    let route = &method(&built, "Get0").routes[0];
    assert_eq!(route.query.len(), 101);
    assert_eq!(params(route)[0].0, "v");
    assert_eq!(params(route)[100].0, format!("{}v", "next.".repeat(100)));
}

#[test]
fn a_query_stops_at_the_nesting_limit() {
    // M0 holds M1 through M149; the field holding M101 is 101 messages
    // deep, past protobuf's limit, and is refused rather than expanded.
    // The same from M1 (M102 is its 101st); M49 holds exactly 100 and is
    // fine. Expanding without a limit made each rule's parameters every
    // leaf below it, quadratic in the chain.
    let source = chain(150, &[(0, "/v1/m0"), (1, "/v1/m1"), (49, "/v1/m49")]);
    let files = [("t.proto", source.as_str())];
    let diagnostics = problems(&files, &["t.proto"]);
    let messages: Vec<String> = diagnostics
        .iter()
        .map(|problem| format!("{}: {}", problem.code(), problem.message()))
        .collect();
    assert_eq!(messages.len(), 2, "{}", messages.join("\n"));
    let deep = vec!["next"; 101].join(".");
    assert_eq!(
        messages[0],
        format!(
            "route::query_field: The HTTP rule of `t.v1.S.Get0` sends `{deep}` as a query \
             parameter, but it is nested 101 messages deep, past protobuf's limit of 100, \
             which has no query form."
        )
    );
    assert!(messages[1].contains("`t.v1.S.Get1`"), "{}", messages[1]);
}

#[test]
fn a_path_variable_stops_at_the_nesting_limit() {
    // The same limit on a path variable: through 100 messages is read,
    // through 101 is not. The query is refused through the same field.
    let within = format!("/v1/{{{}v}}", "next.".repeat(100));
    let built = package(&chain(101, &[(0, within.as_str())]));
    let route = &method(&built, "Get0").routes[0];
    assert_eq!(route.segments.len(), 2);
    assert_eq!(route.query.len(), 100);
    assert_eq!(params(route)[99].0, format!("{}v", "next.".repeat(99)));

    let past = format!("/v1/{{{}v}}", "next.".repeat(101));
    let source = chain(102, &[(0, past.as_str())]);
    let files = [("t.proto", source.as_str())];
    let diagnostics = problems(&files, &["t.proto"]);
    let messages: Vec<String> = diagnostics
        .iter()
        .map(|problem| format!("{}: {}", problem.code(), problem.message()))
        .collect();
    assert_eq!(messages.len(), 2, "{}", messages.join("\n"));
    let deep = vec!["next"; 101].join(".");
    assert!(
        messages[1].starts_with("route::query_field:"),
        "{}",
        messages[1]
    );
    assert_eq!(
        messages[0],
        format!(
            "route::path_field: The HTTP rule of `t.v1.S.Get0` binds `{{{deep}.v}}` in its \
             path, but `{deep}` is nested 101 messages deep, past protobuf's limit of 100."
        )
    );
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
