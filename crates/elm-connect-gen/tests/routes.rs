//! The route fixtures (design §7, `conformance/routes/`): each fixture
//! names a method of `routes.proto` and one of its HTTP bindings, or none
//! for a method without a rule, a request as proto3 JSON, and the HTTP
//! request it becomes.
//!
//! Two ends are held to them:
//!
//! - **The generator's routes**, here: the fixture's rule is the binding
//!   the generator read, and a reference implementation, written against
//!   protobuf's own model of the request (prost-reflect's proto3 JSON
//!   parser, field presence from the descriptors) rather than the JSON the
//!   runtime walks, turns the generated route and the request into the
//!   expected path, query and body. A method without a rule takes the
//!   implicit route: `POST /<package>.<Service>/<Method>`, the request as
//!   its body, with `Connect-Protocol-Version: 1`.
//! - **The runtime's request builder**, in Elm: this test writes the
//!   modules generated from `routes.proto` under `tests/Routes/` and the
//!   fixtures as Elm data to `tests/RouteFixtures.elm`, all pinned like
//!   the conformance corpus (`ELM_CONNECT_BLESS=1` rewrites them), and
//!   `tests/RouteFixturesTest.elm` replays them through `Rpc.request`
//!   with the Transcode transport, choosing the binding with
//!   `Rpc.viaBinding`; a fixture naming a binding the generated method
//!   lacks fails there.
//!
//! Bodies compare as JSON after dropping `null`s and default values
//! (`""`, `0`, `false`, `"0"`, `[]`, `{}`), which a writer may omit or
//! include, and with numbers compared by value.

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

use elm_connect_gen::elm::ast::{Decl, Exposing, Expr, Import, Module, ModuleName};
use elm_connect_gen::elm::build::{
    apply, int, list, qualified, record, string, tuple2, ty_qualified, var,
};
use elm_connect_gen::ir::{self, HttpRule, Method};
use elm_connect_gen::route::{Body, PathSegment, Route};
use elm_connect_gen::{Options, generate};
use prost_reflect::{
    DynamicMessage, Kind, MessageDescriptor, ReflectMessage, SerializeOptions, Value,
};
use serde_json::Value as Json;
use similar::TextDiff;

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn routes_dir() -> PathBuf {
    repo_root().join("conformance/routes")
}

/// One fixture, with the file it came from.
struct Fixture {
    file: String,
    name: String,
    method: String,
    /// `None` for a method without a rule.
    binding: Option<usize>,
    rule: Json,
    request: Json,
    expect: Json,
}

fn fixtures() -> Vec<Fixture> {
    let mut files: Vec<PathBuf> = fs::read_dir(routes_dir())
        .expect("read conformance/routes")
        .map(|entry| entry.expect("an entry").path())
        .filter(|path| path.extension().is_some_and(|ext| ext == "json"))
        .collect();
    files.sort();
    let mut fixtures = Vec::new();
    for path in files {
        let file = path
            .file_stem()
            .expect("a name")
            .to_string_lossy()
            .into_owned();
        let text = fs::read_to_string(&path).expect("read a fixture file");
        let json: Json =
            serde_json::from_str(&text).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
        for fixture in json["fixtures"].as_array().expect("a fixtures array") {
            let field = |key: &str| fixture[key].clone();
            fixtures.push(Fixture {
                file: file.clone(),
                name: field("name").as_str().expect("a name").to_owned(),
                method: field("method").as_str().expect("a method").to_owned(),
                binding: field("binding").as_u64().map(|n| n as usize),
                rule: field("rule"),
                request: field("request"),
                expect: field("expect"),
            });
        }
    }
    assert!(!fixtures.is_empty(), "no route fixtures");
    fixtures
}

/// The compiled `routes.proto`.
fn pool() -> prost_reflect::DescriptorPool {
    let mut compiler =
        protox::Compiler::with_file_resolver(elm_connect_gen::googleapis::resolver([routes_dir()]));
    compiler.include_imports(true).include_source_info(true);
    compiler
        .open_file("routes.proto")
        .unwrap_or_else(|e| panic!("routes.proto does not compile: {e:?}"));
    compiler.descriptor_pool()
}

/// A method of `routes.proto`: as the IR holds it, its request type, and
/// its service's Elm module.
struct Known {
    method: Method,
    input: MessageDescriptor,
    module: String,
}

/// Every method of `routes.proto` by full name.
fn methods(pool: &prost_reflect::DescriptorPool) -> HashMap<String, Known> {
    let packages = ir::build(pool, &["routes.proto"])
        .unwrap_or_else(|d| panic!("{}", elm_connect_gen::diagnostics::render_narrow(&d)));
    let mut methods = HashMap::new();
    for service in &packages[0].services {
        let descriptor = pool
            .get_service_by_name(&service.proto_full_name)
            .expect("the service");
        for method in &service.methods {
            let input = descriptor
                .methods()
                .find(|m| m.name() == method.proto_name)
                .expect("the method")
                .input();
            methods.insert(
                format!("{}.{}", service.proto_full_name, method.proto_name),
                Known {
                    method: method.clone(),
                    input,
                    module: service.module.to_string(),
                },
            );
        }
    }
    methods
}

/// The binding `index` of a rule: its own, then its additional bindings.
fn binding(rule: &HttpRule, index: usize) -> &HttpRule {
    match index {
        0 => rule,
        n => &rule.additional_bindings[n - 1],
    }
}

// The reference implementation.

/// What a request becomes: the path (custom verb included), the query
/// pairs, both percent-encoded, the headers the route itself adds, and the
/// body.
#[derive(Debug, PartialEq)]
struct Http {
    path: String,
    query: Vec<(String, String)>,
    headers: Vec<(String, String)>,
    body: Option<Json>,
}

/// Percent-encodes `text` as UTF-8, keeping RFC 3986's unreserved
/// characters and, if `slash`, `/`.
fn encode(text: &str, slash: bool) -> String {
    let mut out = String::new();
    for byte in text.bytes() {
        let c = byte as char;
        if c.is_ascii_alphanumeric() || "-_.~".contains(c) || (slash && c == '/') {
            out.push(c);
        } else {
            out.push_str(&format!("%{byte:02X}"));
        }
    }
    out
}

fn base64(bytes: &[u8]) -> String {
    const ALPHABET: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::new();
    for chunk in bytes.chunks(3) {
        let n = chunk.iter().fold(0u32, |n, &b| (n << 8) | u32::from(b)) << (8 * (3 - chunk.len()));
        for i in 0..4 {
            if i <= chunk.len() {
                out.push(ALPHABET[(n >> (18 - 6 * i)) as usize & 63] as char);
            } else {
                out.push('=');
            }
        }
    }
    out
}

fn to_json(message: &DynamicMessage) -> Json {
    message
        .serialize_with_options(
            serde_json::value::Serializer,
            &SerializeOptions::new().skip_default_fields(false),
        )
        .expect("serialize")
}

/// The text of one value of a field of kind `kind`, as proto3 JSON writes
/// it, unquoted.
fn text(value: &Value, kind: &Kind) -> String {
    match value {
        Value::String(s) => s.clone(),
        Value::Bool(b) => b.to_string(),
        Value::I32(n) => n.to_string(),
        Value::I64(n) => n.to_string(),
        Value::U32(n) => n.to_string(),
        Value::U64(n) => n.to_string(),
        Value::F32(x) => x.to_string(),
        Value::F64(x) => x.to_string(),
        Value::Bytes(b) => base64(b),
        Value::EnumNumber(n) => match kind {
            Kind::Enum(e) => e.get_value(*n).expect("a known value").name().to_owned(),
            _ => unreachable!(),
        },
        Value::Message(m) => match to_json(m) {
            Json::String(s) => s,
            Json::Bool(b) => b.to_string(),
            Json::Number(n) => n.to_string(),
            other => panic!("no query text for {other}"),
        },
        other => panic!("no query text for {other:?}"),
    }
}

/// The field at proto path `path` of `message`: `None` when a message on
/// the way is unset, or the field has presence and is unset.
fn field_at(message: &DynamicMessage, path: &[String]) -> Option<(Value, Kind)> {
    let field = message
        .descriptor()
        .get_field_by_name(&path[0])
        .expect("a field the route names");
    if path.len() > 1 {
        if !message.has_field(&field) {
            return None;
        }
        let Value::Message(inner) = message.get_field(&field).into_owned() else {
            panic!("{} is not a message", path[0])
        };
        return field_at(&inner, &path[1..]);
    }
    if field.supports_presence() && !message.has_field(&field) {
        return None;
    }
    Some((message.get_field(&field).into_owned(), field.kind()))
}

/// `message` without the field at `path`.
fn clear(message: &mut DynamicMessage, path: &[String]) {
    let field = message
        .descriptor()
        .get_field_by_name(&path[0])
        .expect("a field the route names");
    if path.len() == 1 {
        message.clear_field(&field);
    } else if message.has_field(&field)
        && let Value::Message(inner) = message.get_field_mut(&field)
    {
        clear(inner, &path[1..]);
    }
}

fn reference(route: &Route, request: &DynamicMessage) -> Http {
    let mut segments = Vec::new();
    let mut bound = Vec::new();
    for segment in &route.segments {
        match segment {
            PathSegment::Literal(text) => segments.push(text.clone()),
            PathSegment::Variable { field, .. } => {
                let value = field_at(request, &field.proto)
                    .map(|(value, kind)| text(&value, &kind))
                    .unwrap_or_default();
                segments.push(encode(&value, !segment.is_single()));
                bound.push(field.proto.clone());
            }
        }
    }
    let mut path = format!("/{}", segments.join("/"));
    if let Some(verb) = &route.custom_verb {
        path.push(':');
        path.push_str(verb);
    }

    let mut query = Vec::new();
    for param in &route.query {
        let Some((value, kind)) = field_at(request, &param.field.proto) else {
            continue;
        };
        let name = encode(&param.field.dotted(), false);
        match value {
            Value::List(values) => {
                for value in values {
                    query.push((name.clone(), encode(&text(&value, &kind), false)));
                }
            }
            value => {
                // Presence: an implicit field is set when it is not its
                // default, a field with presence when it was set.
                let descriptor = request.descriptor();
                let set = match param.field.proto.as_slice() {
                    [_] => {
                        let field = descriptor
                            .get_field_by_name(&param.field.proto[0])
                            .expect("a field");
                        request.has_field(&field)
                    }
                    _ => {
                        let (parent, last) =
                            param.field.proto.split_at(param.field.proto.len() - 1);
                        let Some((Value::Message(inner), _)) = field_at(request, parent) else {
                            continue;
                        };
                        let field = inner
                            .descriptor()
                            .get_field_by_name(&last[0])
                            .expect("a field");
                        inner.has_field(&field)
                    }
                };
                if set {
                    query.push((name, encode(&text(&value, &kind), false)));
                }
            }
        }
    }

    let body = match &route.body {
        Body::None => None,
        Body::All => {
            let mut whole = request.clone();
            for path in &bound {
                clear(&mut whole, path);
            }
            Some(to_json(&whole))
        }
        Body::Field(field) => Some(match field_at(request, &field.proto) {
            Some((Value::Message(inner), _)) => to_json(&inner),
            _ => Json::Object(Default::default()),
        }),
    };
    Http {
        path,
        query,
        headers: Vec::new(),
        body,
    }
}

/// The implicit route of the method `full_name`, which has no rule: the
/// request Connect POSTs, which grpc-gateway (`generate_unbound_methods`),
/// Envoy (`auto_mapping`) and Vanguard serve.
fn implicit(full_name: &str, request: &DynamicMessage) -> Http {
    let (service, method) = full_name.rsplit_once('.').expect("a method's full name");
    Http {
        path: format!("/{service}/{method}"),
        query: Vec::new(),
        headers: vec![("Connect-Protocol-Version".into(), "1".into())],
        body: Some(to_json(request)),
    }
}

/// `json` without `null`s and default values, with every number a float,
/// for comparing bodies that may or may not spell out defaults.
fn normalize(json: &Json) -> Json {
    match json {
        Json::Object(map) => Json::Object(
            map.iter()
                .map(|(key, value)| (key.clone(), normalize(value)))
                .filter(|(_, value)| !is_default(value))
                .collect(),
        ),
        Json::Array(items) => Json::Array(items.iter().map(normalize).collect()),
        Json::Number(n) => serde_json::json!(n.as_f64().expect("a number")),
        other => other.clone(),
    }
}

fn is_default(json: &Json) -> bool {
    match json {
        Json::Null => true,
        Json::Bool(b) => !b,
        Json::Number(n) => n.as_f64() == Some(0.0),
        Json::String(s) => s.is_empty() || s == "0",
        Json::Array(items) => items.is_empty(),
        Json::Object(map) => map.is_empty(),
    }
}

fn expected(fixture: &Fixture) -> Http {
    let expect = &fixture.expect;
    let pairs = |key: &str| -> Vec<(String, String)> {
        expect[key]
            .as_array()
            .map(Vec::as_slice)
            .unwrap_or_default()
            .iter()
            .map(|pair| {
                (
                    pair[0].as_str().expect("a name").to_owned(),
                    pair[1].as_str().expect("a value").to_owned(),
                )
            })
            .collect()
    };
    assert!(expect["query"].is_array(), "{}: a query", fixture.name);
    Http {
        path: expect["path"].as_str().expect("a path").to_owned(),
        query: pairs("query"),
        headers: pairs("headers"),
        body: match &expect["body"] {
            Json::Null => None,
            body => Some(body.clone()),
        },
    }
}

#[test]
fn the_fixtures_name_the_rules_the_generator_reads() {
    let pool = pool();
    let methods = methods(&pool);
    let mut failures = Vec::new();
    for fixture in fixtures() {
        let method = &methods[&fixture.method].method;
        let Some(index) = fixture.binding else {
            if method.http.is_some() || !fixture.rule.is_null() {
                failures.push(format!(
                    "{}: {}: a fixture without a binding is for a method without a rule, \
                     and has `\"rule\": null`",
                    fixture.file, fixture.name
                ));
            }
            continue;
        };
        let rule = binding(method.http.as_ref().expect("a rule"), index);
        let actual = serde_json::json!({
            "verb": rule.verb.as_str(),
            "template": rule.template,
            "body": rule.body,
        });
        if actual != fixture.rule {
            failures.push(format!(
                "{}: {}: the rule is {actual}, not {}",
                fixture.file, fixture.name, fixture.rule
            ));
        }
    }
    assert!(failures.is_empty(), "\n{}", failures.join("\n"));
}

#[test]
fn the_reference_turns_each_request_into_its_expectation() {
    let pool = pool();
    let methods = methods(&pool);
    let mut failures = Vec::new();
    for fixture in fixtures() {
        let known = &methods[&fixture.method];
        let request = DynamicMessage::deserialize(known.input.clone(), fixture.request.clone())
            .unwrap_or_else(|e| panic!("{}: {}: the request: {e}", fixture.file, fixture.name));
        let mut actual = match fixture.binding {
            Some(index) => reference(&known.method.routes[index], &request),
            None => implicit(&fixture.method, &request),
        };
        let mut want = expected(&fixture);
        actual.body = actual.body.as_ref().map(normalize);
        want.body = want.body.as_ref().map(normalize);
        if actual != want {
            failures.push(format!(
                "{}: {}:\n  expected {want:?}\n  got      {actual:?}",
                fixture.file, fixture.name
            ));
        }
    }
    assert!(failures.is_empty(), "\n{}", failures.join("\n"));
}

// The Elm replay.

fn blessing() -> bool {
    std::env::var_os("ELM_CONNECT_BLESS").is_some_and(|v| v == "1")
}

/// `content` is the file at `path` under the repository, or becomes it
/// when blessing; `Err` is the diff.
fn pinned(path: &str, content: &str) -> Result<(), String> {
    let file = repo_root().join(path);
    if blessing() {
        fs::create_dir_all(file.parent().expect("a parent")).expect("create");
        fs::write(&file, content).expect("write");
        return Ok(());
    }
    let want = fs::read_to_string(&file).unwrap_or_default();
    if want == content {
        Ok(())
    } else {
        Err(TextDiff::from_lines(want.as_str(), content)
            .unified_diff()
            .header(&format!("pinned/{path}"), &format!("generated/{path}"))
            .to_string())
    }
}

/// The fixtures as an Elm module of `Replay.fixture` calls, each with the
/// generated decoder of its request, the generated function of its method
/// and the number of its binding (`Nothing` for a method without a rule).
fn fixtures_module(methods: &HashMap<String, Known>) -> Module {
    let module = ModuleName::new("Routes.V1");
    let mut services = std::collections::BTreeSet::new();
    let items: Vec<Expr> = fixtures()
        .iter()
        .map(|fixture| {
            let known = &methods[&fixture.method];
            let request = known
                .input
                .full_name()
                .trim_start_matches("routes.v1.")
                .replace('.', "");
            services.insert(known.module.clone());
            let call = qualified(
                ModuleName::new(known.module.clone()),
                known.method.elm_name.clone(),
            );
            let want = expected(fixture);
            let query: Vec<String> = want
                .query
                .iter()
                .map(|(name, value)| format!("{name}={value}"))
                .collect();
            let url = if query.is_empty() {
                want.path.clone()
            } else {
                format!("{}?{}", want.path, query.join("&"))
            };
            // A method without a rule is POSTed on the implicit route.
            let verb = fixture.rule["verb"].as_str().unwrap_or("POST");
            let headers = want
                .headers
                .iter()
                .map(|(name, value)| tuple2(string(name.clone()), string(value.clone())));
            let body = match &want.body {
                None => var("Nothing"),
                Some(body) => apply(var("Just"), [string(body.to_string())]),
            };
            apply(
                qualified("Replay", "fixture"),
                [
                    string(format!("{}: {}", fixture.file, fixture.name)),
                    qualified(module.clone(), format!("decode{request}")),
                    call,
                    match fixture.binding {
                        None => var("Nothing"),
                        Some(index) => apply(var("Just"), [int(index as i64)]),
                    },
                    string(fixture.request.to_string()),
                    record([
                        ("method", string(verb)),
                        ("url", string(url)),
                        ("headers", list(headers)),
                        ("body", body),
                    ]),
                ],
            )
        })
        .collect();
    let imports = ["Replay".to_owned(), module.to_string()]
        .into_iter()
        .chain(services)
        .map(|name| Import {
            module: ModuleName::new(name),
            alias: None,
            exposing: None,
        })
        .collect();
    Module {
        header: Some(
            "Generated by the route fixtures test (crates/elm-connect-gen/tests/routes.rs) from \
             conformance/routes. Do not edit; bless instead."
                .into(),
        ),
        name: ModuleName::new("RouteFixtures"),
        doc: None,
        exposing: Exposing::All,
        imports,
        decls: vec![Decl::Value {
            doc: None,
            name: "fixtures".into(),
            annotation: elm_connect_gen::elm::build::ty(
                "List",
                [ty_qualified("Replay", "Fixture", [])],
            ),
            params: Vec::new(),
            body: Expr::List(items),
        }],
    }
}

#[test]
fn the_elm_replay_is_current() {
    let pool = pool();
    let methods = methods(&pool);
    let generated = generate(&pool, &["routes.proto"], &Options::default())
        .unwrap_or_else(|d| panic!("{}", elm_connect_gen::diagnostics::render_narrow(&d)));
    let fixtures = elm_connect_gen::elm::print::print_module(&fixtures_module(&methods));
    let failures: Vec<String> = generated
        .iter()
        .map(|module| pinned(&format!("tests/{}", module.path), &module.content))
        .chain([pinned("tests/RouteFixtures.elm", &fixtures)])
        .filter_map(Result::err)
        .collect();
    assert!(
        failures.is_empty(),
        "the Elm replay of the route fixtures is stale; run `just bless`:\n{}",
        failures.join("\n")
    );
}
