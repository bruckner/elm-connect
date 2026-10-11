//! `google.api.http` rules as routes: the path template parsed, and every
//! field of the rule resolved against the request and response messages
//! (design §4, §5.3).
//!
//! [`parse_template`] reads the template grammar of `google/api/http.proto`:
//!
//! ```text
//! Template = "/" Segments [ Verb ] ;
//! Segments = Segment { "/" Segment } ;
//! Segment  = "*" | "**" | LITERAL | Variable ;
//! Variable = "{" FieldPath [ "=" Segments ] "}" ;
//! FieldPath = IDENT { "." IDENT } ;
//! Verb     = ":" LITERAL ;
//! ```
//!
//! [`resolve`] then checks a parsed rule against the request and response
//! messages and computes what the runtime needs to turn a request into an
//! HTTP request without knowing its type: the JSON path of every path
//! variable, the body, and every query parameter with its JSON path and
//! the text of the value it is left out at. A [`Route`] is data the emitter
//! writes out as Elm; the runtime never parses a template.
//!
//! The rules:
//!
//! - A path variable names a non-repeated scalar or enum field, possibly
//!   through singular fields of generated messages (`{sub.subfield}`). A
//!   bare `*` or `**` outside a variable cannot be filled by a client and
//!   is refused. `**` may only be the last segment of the template.
//! - `body` is empty (no body), `*` (every field not in the path), or the
//!   name of a top-level singular message field of the request.
//! - `response_body` is empty or the name of a top-level field of the
//!   response.
//! - Unless `body` is `*`, every request field that is not bound by the
//!   path and is not the body field is a query parameter, named by its
//!   dotted proto field path, nested messages expanded field by field.
//!   A parameter holds a scalar, an enum, or a well-known type with a
//!   string or scalar JSON form (timestamps, durations, field masks,
//!   wrappers); a repeated one is repeated in the query. Maps, repeated
//!   messages, `Struct`, `Value` and `ListValue`, and a message that
//!   recurses into itself have no query form and are refused. `Empty`
//!   carries nothing and has no parameter.
//! - Additional bindings take the same rules, and may not nest.

use std::fmt;

use prost_reflect::{FieldDescriptor, Kind, MessageDescriptor};

use crate::ir::{HttpRule, HttpVerb, WellKnown};

/// A path template as written, parsed but not yet checked against a
/// request.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Template {
    /// The segments after the leading `/`.
    pub segments: Vec<Segment>,
    /// The custom verb after the last segment (`cancel` for `:cancel`).
    pub verb: Option<String>,
}

/// One segment of a path template.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Segment {
    /// Literal text, such as `v1`.
    Literal(String),
    /// `*`: one path segment.
    Wildcard,
    /// `**`: any number of path segments, the last segment only.
    DoubleWildcard,
    /// `{field.path=segments}`; `{field}` is `{field=*}`.
    Variable {
        /// The proto field names from the request message.
        field: Vec<String>,
        /// The variable's own template, which holds no variables. Empty
        /// when the variable has none written (`{name}`), which means `*`.
        segments: Vec<Segment>,
    },
}

impl Segment {
    /// Whether the segment matches exactly one path segment: a literal
    /// or `*`. A variable matching one segment has its value
    /// percent-encoded with `/` escaped; any other keeps its `/`s.
    fn is_single(&self) -> bool {
        matches!(self, Segment::Literal(_) | Segment::Wildcard)
    }
}

/// Why a template does not parse.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SyntaxError {
    /// What is wrong, as a phrase ("a segment is empty").
    pub reason: String,
}

impl fmt::Display for SyntaxError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.reason)
    }
}

fn syntax(reason: impl Into<String>) -> SyntaxError {
    SyntaxError {
        reason: reason.into(),
    }
}

/// Parses a path template under the grammar of `google/api/http.proto`.
///
/// Beyond the grammar: a literal may not hold `{`, `}`, `*`, `=` or `:`,
/// nor be empty; a variable may not nest another; `**` must be the last
/// segment, inside a variable or not; the custom verb is the text after
/// the last `:` that follows the last `/` and lies outside braces.
pub fn parse_template(template: &str) -> Result<Template, SyntaxError> {
    let Some(rest) = template.strip_prefix('/') else {
        return Err(syntax("a template starts with `/`"));
    };
    let (path, verb) = split_verb(rest);
    if let Some(verb) = &verb
        && (verb.is_empty() || !verb.chars().all(literal_char))
    {
        return Err(syntax(format!(
            "the custom verb `:{verb}` is not a literal"
        )));
    }
    let mut parser = Parser {
        chars: path.chars().collect(),
        at: 0,
    };
    let segments = parser.segments(false)?;
    if parser.at != parser.chars.len() {
        return Err(syntax(format!(
            "unexpected `{}`",
            parser.chars[parser.at..].iter().collect::<String>()
        )));
    }
    let flat: Vec<&Segment> = segments
        .iter()
        .flat_map(|segment| match segment {
            Segment::Variable { segments, .. } if !segments.is_empty() => segments.iter().collect(),
            other => vec![other],
        })
        .collect();
    if let Some(position) = flat.iter().position(|s| **s == Segment::DoubleWildcard)
        && position + 1 != flat.len()
    {
        return Err(syntax("`**` may only be the last segment"));
    }
    Ok(Template { segments, verb })
}

/// The template after the leading `/`, split into the path and the custom
/// verb.
fn split_verb(rest: &str) -> (&str, Option<String>) {
    let mut depth = 0usize;
    let mut colon = None;
    for (index, c) in rest.char_indices() {
        match c {
            '{' => depth += 1,
            '}' => depth = depth.saturating_sub(1),
            '/' if depth == 0 => colon = None,
            ':' if depth == 0 => colon = Some(index),
            _ => {}
        }
    }
    match colon {
        Some(index) => (&rest[..index], Some(rest[index + 1..].to_owned())),
        None => (rest, None),
    }
}

/// Characters a literal segment or verb may hold: anything but the
/// template's own syntax and `/`.
fn literal_char(c: char) -> bool {
    !matches!(c, '/' | '{' | '}' | '*' | '=' | ':') && !c.is_whitespace()
}

struct Parser {
    chars: Vec<char>,
    at: usize,
}

impl Parser {
    fn peek(&self) -> Option<char> {
        self.chars.get(self.at).copied()
    }

    /// `Segment { "/" Segment }`, stopping before a `}` or the end.
    fn segments(&mut self, in_variable: bool) -> Result<Vec<Segment>, SyntaxError> {
        let mut segments = vec![self.segment(in_variable)?];
        while self.peek() == Some('/') {
            self.at += 1;
            segments.push(self.segment(in_variable)?);
        }
        Ok(segments)
    }

    fn segment(&mut self, in_variable: bool) -> Result<Segment, SyntaxError> {
        match self.peek() {
            None | Some('/') | Some('}') => Err(syntax("a segment is empty")),
            Some('*') => {
                self.at += 1;
                if self.peek() == Some('*') {
                    self.at += 1;
                    Ok(Segment::DoubleWildcard)
                } else {
                    Ok(Segment::Wildcard)
                }
            }
            Some('{') if in_variable => Err(syntax("a variable may not hold another variable")),
            Some('{') => {
                self.at += 1;
                let field = self.field_path()?;
                let segments = if self.peek() == Some('=') {
                    self.at += 1;
                    self.segments(true)?
                } else {
                    Vec::new()
                };
                if self.peek() != Some('}') {
                    return Err(syntax(format!(
                        "the variable `{}` is not closed with `}}`",
                        field.join(".")
                    )));
                }
                self.at += 1;
                Ok(Segment::Variable { field, segments })
            }
            Some(_) => {
                let start = self.at;
                while self.peek().is_some_and(literal_char) {
                    self.at += 1;
                }
                if self.at == start {
                    let c = self.peek().unwrap_or_default();
                    return Err(syntax(format!("unexpected `{c}`")));
                }
                Ok(Segment::Literal(
                    self.chars[start..self.at].iter().collect(),
                ))
            }
        }
    }

    /// `IDENT { "." IDENT }`.
    fn field_path(&mut self) -> Result<Vec<String>, SyntaxError> {
        let mut path = Vec::new();
        loop {
            let start = self.at;
            while self
                .peek()
                .is_some_and(|c| c.is_ascii_alphanumeric() || c == '_')
            {
                self.at += 1;
            }
            let ident: String = self.chars[start..self.at].iter().collect();
            if ident.is_empty() || ident.starts_with(|c: char| c.is_ascii_digit()) {
                return Err(syntax(
                    "a variable names a field path, like `{name}` or `{book.name}`",
                ));
            }
            path.push(ident);
            if self.peek() == Some('.') {
                self.at += 1;
            } else {
                return Ok(path);
            }
        }
    }
}

/// A rule checked against its request and response: everything the
/// runtime needs, as data.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Route {
    /// The HTTP method.
    pub verb: HttpVerb,
    /// The path segments; a bare wildcard never appears outside a
    /// variable.
    pub segments: Vec<PathSegment>,
    /// The custom verb, appended to the path as `:verb`.
    pub custom_verb: Option<String>,
    /// What the request body holds.
    pub body: Body,
    /// The response field the body holds, if the body is not the whole
    /// response.
    pub response_body: Option<FieldPath>,
    /// The query parameters, in field declaration order, depth first. Empty
    /// when the body holds every field not in the path.
    pub query: Vec<QueryParam>,
}

/// One path segment of a [`Route`].
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PathSegment {
    /// Literal text.
    Literal(String),
    /// A request field's value.
    Variable {
        /// The field.
        field: FieldPath,
        /// The variable's template as written (`messages/*`), without
        /// variables; empty for `{name}`.
        template: Vec<Segment>,
    },
}

impl PathSegment {
    /// Whether a variable matches one path segment (`{name}`,
    /// `{name=*}`, `{name=v1}`), so its value is encoded with `/`
    /// escaped. A literal is always one segment.
    pub fn is_single(&self) -> bool {
        match self {
            PathSegment::Literal(_) => true,
            PathSegment::Variable { template, .. } => match template.as_slice() {
                [] => true,
                [only] => only.is_single(),
                _ => false,
            },
        }
    }
}

/// A path through the fields of a message, by proto name and by JSON name.
#[derive(Clone, Debug, Default, PartialEq, Eq, Hash)]
pub struct FieldPath {
    /// The proto field names, outermost first (`sub`, `subfield`).
    pub proto: Vec<String>,
    /// The JSON names of the same fields (`sub`, `subfield`), the keys
    /// generated encoders write.
    pub json: Vec<String>,
}

impl FieldPath {
    /// The dotted proto path, such as `sub.subfield`.
    pub fn dotted(&self) -> String {
        self.proto.join(".")
    }
}

/// What a request body holds.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Body {
    /// No body; every field not in the path is in the query.
    None,
    /// `*`: the request, without the fields bound by the path.
    All,
    /// One top-level message field of the request.
    Field(FieldPath),
}

/// One query parameter: a leaf field of the request.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct QueryParam {
    /// The field, whose dotted proto path names the parameter.
    pub field: FieldPath,
    /// The text of the field's value when it is at its proto3 default
    /// and so left out of the query: `""`, `0`, `false`, or the zero
    /// value's name for an enum. `None` for a field with presence, which
    /// is left out only when unset, and for a repeated field, whose
    /// elements are each sent.
    pub zero: Option<String>,
}

/// Why a rule does not resolve against its messages.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RouteError {
    /// The rule has no `get`, `put`, `post`, `delete`, `patch` or
    /// `custom` pattern, or a `custom` without a kind.
    NoPattern,
    /// The template does not parse.
    Syntax {
        /// The template.
        template: String,
        /// Why.
        error: SyntaxError,
    },
    /// A `*` or `**` outside a variable: no request field fills it.
    UnboundWildcard {
        /// The template.
        template: String,
    },
    /// A path variable's field is not in the request, or not one a path
    /// can hold.
    PathField {
        /// The variable's dotted field path.
        field: String,
        /// Why, as a phrase.
        reason: String,
    },
    /// Two path variables name one field.
    PathFieldTwice {
        /// The dotted field path.
        field: String,
    },
    /// `body` names no message field of the request.
    BodyField {
        /// The `body` value.
        field: String,
        /// Why, as a phrase.
        reason: String,
    },
    /// `response_body` names no field of the response.
    ResponseBodyField {
        /// The `response_body` value.
        field: String,
    },
    /// A field that would be a query parameter has no query form.
    QueryField {
        /// The dotted field path.
        field: String,
        /// Why, as a phrase.
        reason: String,
    },
    /// An additional binding has additional bindings of its own.
    NestedBindings,
}

/// Checks `rule` (one binding; its own additional bindings are reported,
/// not followed) against the method's `request` and `response`, giving
/// the route or every problem found.
pub fn resolve(
    rule: &HttpRule,
    request: &MessageDescriptor,
    response: &MessageDescriptor,
    nested: bool,
) -> Result<Route, Vec<RouteError>> {
    let mut errors = Vec::new();
    if nested && !rule.additional_bindings.is_empty() {
        errors.push(RouteError::NestedBindings);
    }
    if rule.template.is_empty() || matches!(&rule.verb, HttpVerb::Custom(kind) if kind.is_empty()) {
        errors.push(RouteError::NoPattern);
        return Err(errors);
    }
    let template = match parse_template(&rule.template) {
        Ok(template) => template,
        Err(error) => {
            errors.push(RouteError::Syntax {
                template: rule.template.clone(),
                error,
            });
            return Err(errors);
        }
    };

    let mut segments = Vec::new();
    let mut bound: Vec<FieldPath> = Vec::new();
    for segment in template.segments {
        match segment {
            Segment::Literal(text) => segments.push(PathSegment::Literal(text)),
            Segment::Wildcard | Segment::DoubleWildcard => {
                errors.push(RouteError::UnboundWildcard {
                    template: rule.template.clone(),
                });
            }
            Segment::Variable {
                field,
                segments: template,
            } => match path_field(request, &field) {
                Ok(path) => {
                    if bound.contains(&path) {
                        errors.push(RouteError::PathFieldTwice {
                            field: path.dotted(),
                        });
                    }
                    bound.push(path.clone());
                    segments.push(PathSegment::Variable {
                        field: path,
                        template,
                    });
                }
                Err(reason) => errors.push(RouteError::PathField {
                    field: field.join("."),
                    reason,
                }),
            },
        }
    }

    // A body that does not resolve leaves the query unknown, so it is not
    // checked: its problems would only follow from the body's.
    let body = match rule.body.as_str() {
        "" => Some(Body::None),
        "*" => Some(Body::All),
        name => match body_field(request, name) {
            Ok(path) => Some(Body::Field(path)),
            Err(reason) => {
                errors.push(RouteError::BodyField {
                    field: name.to_owned(),
                    reason,
                });
                None
            }
        },
    };

    let response_body = match rule.response_body.as_str() {
        "" => None,
        name => match response.get_field_by_name(name) {
            Some(field) => Some(FieldPath {
                proto: vec![field.name().to_owned()],
                json: vec![field.json_name().to_owned()],
            }),
            None => {
                errors.push(RouteError::ResponseBodyField {
                    field: name.to_owned(),
                });
                None
            }
        },
    };

    let mut query = Vec::new();
    if let Some(body) = body.as_ref().filter(|body| **body != Body::All) {
        let skip = match body {
            Body::Field(path) => Some(path.proto[0].clone()),
            _ => None,
        };
        let mut walk = QueryWalk {
            bound: &bound,
            params: &mut query,
            errors: &mut errors,
            stack: vec![request.full_name().to_owned()],
        };
        walk.message(request, &FieldPath::default(), skip.as_deref());
    }

    if errors.is_empty() {
        Ok(Route {
            verb: rule.verb.clone(),
            segments,
            custom_verb: template.verb,
            body: body.unwrap_or(Body::None),
            response_body,
            query,
        })
    } else {
        Err(errors)
    }
}

impl FieldPath {
    fn child(&self, field: &FieldDescriptor) -> FieldPath {
        let mut path = self.clone();
        path.proto.push(field.name().to_owned());
        path.json.push(field.json_name().to_owned());
        path
    }
}

/// The well-known type `message` is, if it is one of `google.protobuf`.
fn well_known(message: &MessageDescriptor) -> Option<Option<WellKnown>> {
    message
        .full_name()
        .strip_prefix("google.protobuf.")
        .map(WellKnown::from_name)
}

/// The field a path variable names, through singular fields of generated
/// messages to a non-repeated scalar or enum.
fn path_field(request: &MessageDescriptor, names: &[String]) -> Result<FieldPath, String> {
    let mut message = request.clone();
    let mut path = FieldPath::default();
    for (index, name) in names.iter().enumerate() {
        let Some(field) = message.get_field_by_name(name) else {
            return Err(format!("`{}` has no field `{name}`", message.full_name()));
        };
        path = path.child(&field);
        let last = index + 1 == names.len();
        if field.is_list() || field.is_map() {
            return Err(format!(
                "`{}` is repeated, and a path holds one value",
                path.dotted()
            ));
        }
        match field.kind() {
            Kind::Message(inner) if last => {
                return Err(format!(
                    "`{}` is the message `{}`, and a path holds a scalar or an enum",
                    path.dotted(),
                    inner.full_name()
                ));
            }
            Kind::Message(inner) => {
                if well_known(&inner).is_some() {
                    return Err(format!(
                        "`{}` is `{}`, whose fields have no JSON form of their own",
                        path.dotted(),
                        inner.full_name()
                    ));
                }
                message = inner;
            }
            _ if last => {}
            _ => {
                return Err(format!(
                    "`{}` is not a message, so it has no field `{}`",
                    path.dotted(),
                    names[index + 1]
                ));
            }
        }
    }
    Ok(path)
}

/// The top-level singular message field `name` of the request.
fn body_field(request: &MessageDescriptor, name: &str) -> Result<FieldPath, String> {
    let Some(field) = request.get_field_by_name(name) else {
        return Err(format!("`{}` has no field `{name}`", request.full_name()));
    };
    if field.is_list() || field.is_map() {
        return Err(format!("`{name}` is repeated"));
    }
    match field.kind() {
        Kind::Message(_) => Ok(FieldPath::default().child(&field)),
        _ => Err(format!("`{name}` is not a message")),
    }
}

/// The query parameters of a message, collected depth first.
struct QueryWalk<'a> {
    bound: &'a [FieldPath],
    params: &'a mut Vec<QueryParam>,
    errors: &'a mut Vec<RouteError>,
    /// The messages being expanded, outermost first, to refuse recursion.
    stack: Vec<String>,
}

impl QueryWalk<'_> {
    fn message(&mut self, message: &MessageDescriptor, prefix: &FieldPath, skip: Option<&str>) {
        for field in message.fields() {
            if prefix.proto.is_empty() && skip == Some(field.name()) {
                continue;
            }
            let path = prefix.child(&field);
            if self.bound.contains(&path) {
                continue;
            }
            self.field(&field, path);
        }
    }

    fn refuse(&mut self, path: &FieldPath, reason: impl Into<String>) {
        self.errors.push(RouteError::QueryField {
            field: path.dotted(),
            reason: reason.into(),
        });
    }

    fn field(&mut self, field: &FieldDescriptor, path: FieldPath) {
        if field.is_map() {
            return self.refuse(&path, "it is a map");
        }
        let repeated = field.is_list();
        let presence = field.supports_presence();
        let zero = |text: String| (!repeated && !presence).then_some(text);
        let param = |zero| QueryParam {
            field: path.clone(),
            zero,
        };
        match field.kind() {
            Kind::Message(inner) => match well_known(&inner) {
                Some(Some(WellKnown::Empty)) => {}
                Some(Some(WellKnown::Struct | WellKnown::Value | WellKnown::ListValue)) => {
                    self.refuse(&path, format!("`{}` is free-form JSON", inner.full_name()))
                }
                Some(Some(_)) => self.params.push(param(None)),
                // Unsupported well-known types are reported by the IR.
                Some(None) => {}
                None if repeated => self.refuse(&path, "it is a repeated message"),
                None if self.stack.iter().any(|name| name == inner.full_name()) => {
                    self.refuse(&path, format!("`{}` contains itself", inner.full_name()))
                }
                None => {
                    self.stack.push(inner.full_name().to_owned());
                    self.message(&inner, &path, None);
                    self.stack.pop();
                }
            },
            Kind::Enum(enumeration) => {
                let first = enumeration
                    .enum_descriptor_proto()
                    .value
                    .first()
                    .map(|value| value.name().to_owned())
                    .unwrap_or_default();
                self.params.push(param(zero(first)));
            }
            Kind::String | Kind::Bytes => self.params.push(param(zero(String::new()))),
            Kind::Bool => self.params.push(param(zero("false".into()))),
            _ => self.params.push(param(zero("0".into()))),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn lit(text: &str) -> Segment {
        Segment::Literal(text.into())
    }

    fn var(field: &str, segments: Vec<Segment>) -> Segment {
        Segment::Variable {
            field: field.split('.').map(str::to_owned).collect(),
            segments,
        }
    }

    fn parsed(template: &str) -> Template {
        parse_template(template).unwrap_or_else(|e| panic!("{template}: {e}"))
    }

    #[test]
    fn parses_the_http_proto_examples() {
        assert_eq!(
            parsed("/v1/{name=messages/*}").segments,
            [
                lit("v1"),
                var("name", vec![lit("messages"), Segment::Wildcard])
            ]
        );
        assert_eq!(
            parsed("/v1/messages/{message_id}/{sub.subfield}").segments,
            [
                lit("v1"),
                lit("messages"),
                var("message_id", vec![]),
                var("sub.subfield", vec![])
            ]
        );
        assert_eq!(
            parsed("/v1/users/{user_id}/messages/{message_id}")
                .segments
                .len(),
            5
        );
    }

    #[test]
    fn parses_wildcards_and_verbs() {
        let t = parsed("/v1/{name=projects/*/locations/*}:cancel");
        assert_eq!(t.verb.as_deref(), Some("cancel"));
        assert_eq!(
            t.segments[1],
            var(
                "name",
                vec![
                    lit("projects"),
                    Segment::Wildcard,
                    lit("locations"),
                    Segment::Wildcard
                ]
            )
        );
        let t = parsed("/v1/{name=files/**}");
        assert_eq!(
            t.segments[1],
            var("name", vec![lit("files"), Segment::DoubleWildcard])
        );
        assert_eq!(parsed("/v1/*/x").segments[1], Segment::Wildcard);
        assert_eq!(parsed("/v1/**").segments[1], Segment::DoubleWildcard);
        assert_eq!(parsed("/v1:batchGet").verb.as_deref(), Some("batchGet"));
        assert_eq!(
            parsed("/v1/{name}:undelete").verb.as_deref(),
            Some("undelete")
        );
        assert_eq!(
            parsed("/v1.2/a-b_c~d").segments,
            [lit("v1.2"), lit("a-b_c~d")]
        );
    }

    #[test]
    fn refuses_what_the_grammar_does_not_allow() {
        for (template, reason) in [
            ("v1/x", "starts with `/`"),
            ("/", "empty"),
            ("/v1//x", "empty"),
            ("/v1/", "empty"),
            ("/v1/{name", "not closed"),
            ("/v1/{name=a/{b}}", "may not hold another variable"),
            ("/v1/{}", "field path"),
            ("/v1/{1x}", "field path"),
            ("/v1/**/x", "last segment"),
            ("/v1/{name=**}/x", "last segment"),
            ("/v1/{name=**/x}", "last segment"),
            ("/v1/x:", "custom verb"),
            ("/v1/a=b", "unexpected `=b`"),
        ] {
            let error = parse_template(template).expect_err(template);
            assert!(error.reason.contains(reason), "{template}: {error}");
        }
    }

    #[test]
    fn single_segment_variables() {
        let single = |segment: Segment| {
            let Segment::Variable { field, segments } = segment else {
                panic!()
            };
            PathSegment::Variable {
                field: FieldPath {
                    proto: field.clone(),
                    json: field,
                },
                template: segments,
            }
            .is_single()
        };
        assert!(single(var("a", vec![])));
        assert!(single(var("a", vec![Segment::Wildcard])));
        assert!(!single(var("a", vec![Segment::DoubleWildcard])));
        assert!(!single(var("a", vec![lit("x"), Segment::Wildcard])));
    }
}
