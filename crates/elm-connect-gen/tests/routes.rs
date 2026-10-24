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
//!   the conformance corpus, the modules' header version as its
//!   placeholder (`ELM_CONNECT_BLESS=1` rewrites them), and
//!   `tests/RouteFixturesTest.elm` replays them through `Rpc.request`
//!   with the Transcode transport, choosing the binding with
//!   `Rpc.Call.viaBinding`; a fixture naming a binding the generated method
//!   lacks fails there.
//!
//! Bodies compare as JSON after dropping `null`s and default values
//! (`""`, `0`, `false`, `"0"`, `[]`, `{}`), which a writer may omit or
//! include, and with numbers compared by value.

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

use elm_connect_gen::diagnostics::Code;
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

mod common;
use common::placeholder_header;
#[path = "common/sample.rs"]
mod sample;
use sample::{Profile, Rng, sample_message};
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

/// `message` as proto3 JSON, as the generated encoders write it: fields at
/// their defaults left out.
fn to_json(message: &DynamicMessage) -> Json {
    message
        .serialize_with_options(
            serde_json::value::Serializer,
            &SerializeOptions::new().skip_default_fields(true),
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
        Value::F32(x) => number(f64::from(*x)),
        Value::F64(x) => number(*x),
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

/// A float as text: proto3 JSON's `NaN`, `Infinity` and `-Infinity`, and a
/// finite value as ECMAScript's Number-to-String writes it (`1e+21`,
/// `1e-7`, `0.000001`, `-0` as `0`), which is what `JSON.stringify` and so
/// a browser client sends. proto3 JSON fixes no form for a number and a
/// server parses any; the expectation needs one.
fn number(x: f64) -> String {
    if x.is_nan() {
        return "NaN".into();
    }
    if x.is_infinite() {
        return if x > 0.0 { "Infinity" } else { "-Infinity" }.into();
    }
    if x == 0.0 {
        return "0".into();
    }
    // Rust's `{:e}` writes the shortest digits that read back as `x`, as
    // ECMAScript does, but when two such are equally close to `x` it rounds
    // up, where ECMAScript takes the even one. A tie shows in `x`'s exact
    // expansion (`{:.800e}` holds every digit of any double) as a 5
    // followed by nothing past the shortest digits.
    let shortest = format!("{:e}", x.abs());
    let (mantissa, exponent) = shortest.split_once('e').expect("an exponent");
    let mut digits = mantissa.replace('.', "");
    let exact = format!("{:.800e}", x.abs());
    let (exact_mantissa, exact_exponent) = exact.split_once('e').expect("an exponent");
    let exact_digits = exact_mantissa.replace('.', "");
    let (kept, rest) = exact_digits.split_at(digits.len());
    let tie = rest.starts_with('5') && rest[1..].bytes().all(|b| b == b'0');
    let odd = digits.ends_with(['1', '3', '5', '7', '9']);
    if tie && odd && exact_exponent == exponent && kept != digits {
        digits = kept.to_owned();
    }
    let k = digits.len() as i32;
    let n = exponent.parse::<i32>().expect("an exponent") + 1;
    let zeros = |count: i32| "0".repeat(count as usize);
    let text = if k <= n && n <= 21 {
        format!("{digits}{}", zeros(n - k))
    } else if 0 < n && n <= 21 {
        format!("{}.{}", &digits[..n as usize], &digits[n as usize..])
    } else if -6 < n && n <= 0 {
        format!("0.{}{digits}", zeros(-n))
    } else {
        let mantissa = if k == 1 {
            digits.clone()
        } else {
            format!("{}.{}", &digits[..1], &digits[1..])
        };
        let sign = if n > 0 { '+' } else { '-' };
        format!("{mantissa}e{sign}{}", (n - 1).abs())
    };
    if x < 0.0 { format!("-{text}") } else { text }
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

/// The kind of the field at proto path `path` of messages of `descriptor`.
fn leaf_kind(descriptor: &MessageDescriptor, path: &[String]) -> Kind {
    let kind = descriptor
        .get_field_by_name(&path[0])
        .expect("a field the route names")
        .kind();
    match (&kind, path.len()) {
        (_, 1) => kind,
        (Kind::Message(inner), _) => leaf_kind(inner, &path[1..]),
        _ => panic!("{} is not a message", path[0]),
    }
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
                // Unset (a message on the way, or the field with presence),
                // the field reads as its proto3 default.
                let value = match field_at(request, &field.proto) {
                    Some((value, kind)) => text(&value, &kind),
                    None => {
                        let kind = leaf_kind(&request.descriptor(), &field.proto);
                        text(&Value::default_value(&kind), &kind)
                    }
                };
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
        Body::Field(top) => Some(match field_at(request, &top.field.proto) {
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
/// Envoy (`auto_mapping`) and a Connect handler serve.
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

/// One request to replay in Elm: a fixture, or a sampled request.
struct Case {
    name: String,
    method: String,
    /// `None` for a method without a rule.
    binding: Option<usize>,
    /// The request as proto3 JSON.
    request: String,
    expect: Http,
}

impl Case {
    fn of_fixture(fixture: &Fixture) -> Case {
        Case {
            name: format!("{}: {}", fixture.file, fixture.name),
            method: fixture.method.clone(),
            binding: fixture.binding,
            request: fixture.request.to_string(),
            expect: expected(fixture),
        }
    }
}

/// `cases` as an Elm module `name` of `Replay.fixture` calls, each with the
/// generated decoder of its request, the generated function of its method
/// and the number of its binding (`Nothing` for a method without a rule).
fn replay_module(
    name: &str,
    header: &str,
    cases: &[Case],
    methods: &HashMap<String, Known>,
) -> Module {
    let module = ModuleName::new("Routes.V1");
    let mut services = std::collections::BTreeSet::new();
    let items: Vec<Expr> = cases
        .iter()
        .map(|case| {
            let known = &methods[&case.method];
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
            let want = &case.expect;
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
            let verb = match case.binding {
                Some(index) => binding(known.method.http.as_ref().expect("a rule"), index)
                    .verb
                    .as_str(),
                None => "POST",
            };
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
                    string(case.name.clone()),
                    qualified(module.clone(), format!("decode{request}")),
                    call,
                    match case.binding {
                        None => var("Nothing"),
                        Some(index) => apply(var("Just"), [int(index as i64)]),
                    },
                    string(case.request.clone()),
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
        header: Some(header.into()),
        name: ModuleName::new(name),
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
    // The fixtures hold two pairs of bindings no router serves together,
    // to pin what the client sends for each: those two warnings, and no
    // other.
    let warnings: Vec<(Code, &str)> = generated
        .warnings
        .iter()
        .map(|problem| (problem.code(), problem.message()))
        .collect();
    let expected = [
        "Additional binding 2 of `routes.v1.Routes.GetMessage`",
        "The HTTP rule of `routes.v1.Routes.UpdateMessageWhole`",
    ];
    assert!(
        warnings.len() == expected.len()
            && warnings
                .iter()
                .zip(expected)
                .all(|((code, message), start)| {
                    *code == Code::AmbiguousBinding && message.starts_with(start)
                }),
        "routes.proto warns of other than its two ambiguous pairs:\n{}",
        elm_connect_gen::diagnostics::render_narrow(&generated.warnings)
    );
    let cases: Vec<Case> = fixtures().iter().map(Case::of_fixture).collect();
    let fixtures = elm_connect_gen::elm::print::print_module(&replay_module(
        "RouteFixtures",
        "Generated by the route fixtures test (crates/elm-connect-gen/tests/routes.rs) from \
         conformance/routes. Do not edit; bless instead.",
        &cases,
        &methods,
    ));
    let failures: Vec<String> = generated
        .files
        .iter()
        .map(|module| {
            pinned(
                &format!("tests/{}", module.path),
                &placeholder_header(&module.content),
            )
        })
        .chain([pinned("tests/RouteFixtures.elm", &fixtures)])
        .filter_map(Result::err)
        .collect();
    assert!(
        failures.is_empty(),
        "the Elm replay of the route fixtures is stale; run `just bless`:\n{}",
        failures.join("\n")
    );
}

// The route properties: requests sampled at random for every route of
// `routes.proto`, each turned into its HTTP request by the reference and
// replayed in Elm (`tests/RouteProperties.elm`, `RoutePropertiesTest.elm`)
// as the fixtures are.

/// The seed of the sampling and the number of requests sampled per route
/// (each binding of each method, and the implicit route of a method
/// without a rule). Changing either re-samples every request, which
/// rewrites `tests/RouteProperties.elm`.
const SEED: u64 = 0x2026_1015;
const PER_ROUTE: usize = 16;

/// What the route samples draw from: strings of what a URL must escape,
/// what JSON and an Elm literal must escape, and multi-byte UTF-8;
/// 64-bit integers over their whole range.
const ROUTES: Profile = Profile {
    chars: "azAZ09-_.~/?#&=% +:@!$'()*,;[]\"\\\n\t\u{1}\u{7F}éßΩ中✓😀\u{10348}",
    wide: true,
    depth: 3,
    items: 4,
};

/// The request as proto3 JSON, written in one of the forms a parser must
/// accept: usually as the generated encoders write it, sometimes with every
/// default spelled out or with proto field names.
fn sample_json(rng: &mut Rng, message: &DynamicMessage) -> Json {
    let options = SerializeOptions::new()
        .skip_default_fields(!rng.one_in(4))
        .use_proto_field_name(rng.one_in(4));
    message
        .serialize_with_options(serde_json::value::Serializer, &options)
        .expect("serialize")
}

/// The sampled requests, `PER_ROUTE` for each route of every method, in
/// method and binding order, each with the message it was written from.
fn samples(methods: &HashMap<String, Known>) -> Vec<(Case, DynamicMessage)> {
    let mut rng = Rng(SEED);
    let mut names: Vec<&String> = methods.keys().collect();
    names.sort();
    let mut cases = Vec::new();
    for name in names {
        let known = &methods[name];
        let bindings: Vec<Option<usize>> = if known.method.http.is_some() {
            (0..known.method.routes.len()).map(Some).collect()
        } else {
            vec![None]
        };
        for binding in bindings {
            for n in 0..PER_ROUTE {
                let message = sample_message(&mut rng, &ROUTES, &known.input, 0);
                let json = sample_json(&mut rng, &message);
                let expect = match binding {
                    Some(index) => reference(&known.method.routes[index], &message),
                    None => implicit(name, &message),
                };
                let short = name.trim_start_matches("routes.v1.Routes.");
                let case = Case {
                    name: match binding {
                        Some(index) => format!("{short} {index} #{n}"),
                        None => format!("{short} #{n}"),
                    },
                    method: name.clone(),
                    binding,
                    request: json.to_string(),
                    expect,
                };
                cases.push((case, message));
            }
        }
    }
    cases
}

/// Each sample's JSON is proto3 JSON that prost-reflect reads back as the
/// message it was written from.
#[test]
fn the_samples_are_proto3_json_that_reads_back() {
    let pool = pool();
    let methods = methods(&pool);
    let mut failures = Vec::new();
    for (case, message) in samples(&methods) {
        let input = &methods[&case.method].input;
        let json: Json = serde_json::from_str(&case.request).expect("JSON");
        match DynamicMessage::deserialize(input.clone(), json) {
            Ok(read) => {
                if to_json(&read) != to_json(&message) {
                    failures.push(format!(
                        "{}: {} reads back as {}, not {}",
                        case.name,
                        case.request,
                        to_json(&read),
                        to_json(&message)
                    ));
                }
            }
            Err(e) => failures.push(format!("{}: {}: {e}", case.name, case.request)),
        }
    }
    assert!(failures.is_empty(), "\n{}", failures.join("\n"));
}

#[test]
fn the_route_properties_are_current() {
    let pool = pool();
    let methods = methods(&pool);
    let module = replay_module(
        "RouteProperties",
        "Generated by the route properties test (crates/elm-connect-gen/tests/routes.rs): \
         requests sampled from conformance/routes/routes.proto, and what the reference makes \
         of them. Do not edit; bless instead.",
        &samples(&methods)
            .into_iter()
            .map(|(case, _)| case)
            .collect::<Vec<_>>(),
        &methods,
    );
    let content = elm_connect_gen::elm::print::print_module(&module);
    if let Err(diff) = pinned("tests/RouteProperties.elm", &content) {
        panic!("the route properties are stale; run `just bless`:\n{diff}");
    }
}
