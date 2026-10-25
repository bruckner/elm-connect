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
//! HTTP request without knowing its type: every path variable and every
//! query parameter as the path of fields from the request down to it,
//! each field named as generated code names its descriptor
//! ([`FieldRef`]), and the body. A [`Route`] is data the emitter writes
//! out as Elm; the runtime never parses a template, and derives from the
//! field descriptors what follows from the fields (JSON names, the text
//! of a default, whether a parameter is left out at it).
//!
//! The rules:
//!
//! - A path variable names a non-repeated field of a generated request,
//!   possibly through singular fields of generated messages
//!   (`{sub.subfield}`): a scalar, an enum, or a well-known type with a
//!   string or scalar JSON form (timestamps, durations, field masks,
//!   wrappers), the same well-known types a query parameter holds. A path
//!   does not run through a well-known type (`{at.seconds}`): its fields
//!   have no JSON form of their own. A
//!   bare `*` or `**` outside a variable cannot be filled by a client and
//!   is refused. `**` may only be the last segment of the template.
//! - A message held deeper than [`NESTING_LIMIT`] messages below the
//!   request is past what a protobuf parser reads, and a path variable or
//!   query parameter through it is refused.
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
//!   messages, `Struct`, `Value` and `ListValue`, a message that
//!   recurses into itself, and a message past the nesting limit have no
//!   query form and are refused. `Empty` carries nothing and has no
//!   parameter.
//! - Additional bindings take the same rules, and may not nest.

use std::collections::HashMap;
use std::fmt;

use prost_reflect::{FieldDescriptor, Kind, MessageDescriptor};

use crate::ir::{HttpRule, HttpVerb, ModuleName, WellKnown, declared_fields};

/// How deep a message may hold other messages: protobuf's nesting limit
/// for parsing, counted in messages below the top-level one
/// (<https://protobuf.dev/programming-guides/proto-limits/>). A message
/// held deeper is one a parser refuses, so a field through it has no
/// form a server reads, and refusing it bounds the walk of a deep chain.
pub const NESTING_LIMIT: usize = 100;

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
///
/// The runtime writes literals and the verb into the URL as they are, so
/// each must already be URL text that stays in its place: RFC 3986
/// `pchar`s alone (see [`url_text`]), and a literal not a dot segment,
/// which a URL resolves against the segment before it, so `/../admin`
/// would leave the base URL's path.
pub fn parse_template(template: &str) -> Result<Template, SyntaxError> {
    let Some(rest) = template.strip_prefix('/') else {
        return Err(syntax("a template starts with `/`"));
    };
    let (path, verb) = split_verb(rest);
    if let Some(verb) = &verb {
        if verb.is_empty() || !verb.chars().all(literal_char) {
            return Err(syntax(format!(
                "the custom verb `:{verb}` is not a literal"
            )));
        }
        url_text(verb).map_err(|reason| {
            syntax(format!(
                "the custom verb `:{}` {reason}",
                verb.escape_debug()
            ))
        })?;
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
    for segment in flat {
        if let Segment::Literal(text) = segment {
            let shown = text.escape_debug();
            url_text(text).map_err(|reason| syntax(format!("the literal `{shown}` {reason}")))?;
            if is_dot_segment(text) {
                return Err(syntax(format!(
                    "the literal `{shown}` is a dot segment, which a URL resolves away"
                )));
            }
        }
    }
    Ok(Template { segments, verb })
}

/// Checks that `text` is URL path text the runtime can write as it is:
/// RFC 3986 `pchar`s (letters, digits, `-._~`, the sub-delimiters
/// `!$&'()*+,;=`, `:` and `@`), with `%` only opening an escape of two hex
/// digits. Anything else, such as `?`, `#`, a space, a control character
/// or a non-ASCII letter, would change the URL's meaning or need encoding.
/// Err is the reason, as a phrase.
fn url_text(text: &str) -> Result<(), String> {
    let bytes = text.as_bytes();
    let mut at = 0;
    while at < bytes.len() {
        let b = bytes[at];
        if b == b'%' {
            let escape = bytes.get(at + 1..at + 3);
            if !escape.is_some_and(|hex| hex.iter().all(u8::is_ascii_hexdigit)) {
                return Err("holds a `%` that opens no escape like `%2F`".into());
            }
            at += 3;
            continue;
        }
        if !(b.is_ascii_alphanumeric() || b"-._~!$&'()*+,;=:@".contains(&b)) {
            let c = text[at..].chars().next().unwrap_or_default();
            return Err(format!(
                "holds `{}`, which a URL path cannot hold as it is; write it \
                 percent-encoded",
                c.escape_debug()
            ));
        }
        at += 1;
    }
    Ok(())
}

/// Whether `text` is `.` or `..`, with any dot written `%2e`, as URL
/// parsers read them.
fn is_dot_segment(text: &str) -> bool {
    let dots = text.to_ascii_lowercase().replace("%2e", ".");
    dots == "." || dots == ".."
}

/// Why `kind`, a custom rule's HTTP method, cannot be sent: not an RFC 9110
/// token, or a method browsers forbid (`CONNECT`, `TRACE`, `TRACK`). None
/// when it can.
fn custom_kind_problem(kind: &str) -> Option<&'static str> {
    let token = !kind.is_empty()
        && kind
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"!#$%&'*+-.^_`|~".contains(&b));
    if !token {
        return Some("is not an HTTP method name");
    }
    let forbidden = ["CONNECT", "TRACE", "TRACK"]
        .iter()
        .any(|method| method.eq_ignore_ascii_case(kind));
    forbidden.then_some("is a method browsers refuse to send")
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
    pub response_body: Option<TopField>,
    /// The query parameters, in field declaration order, depth first. Empty
    /// when the body holds every field not in the path.
    pub query: Vec<QueryParam>,
}

impl Route {
    /// The route's path shape: its path with each variable written as
    /// what it matches, `*` for one segment (`{x}`, `{x=*}`), `**` for
    /// any number (`{x=**}`), and its own template's shape for a variable
    /// with one (`{name=messages/*}` is `messages/*`), and the custom verb
    /// kept. Two routes of one HTTP method and one shape match the same
    /// requests, so `/v1/{name=messages/*}` and `/v1/messages/{id}` are
    /// both `/v1/messages/*`.
    pub fn shape(&self) -> String {
        let mut shape = String::new();
        for segment in &self.segments {
            match segment {
                PathSegment::Literal(text) => {
                    shape.push('/');
                    shape.push_str(text);
                }
                PathSegment::Variable { template, .. } if template.is_empty() => {
                    shape.push_str("/*");
                }
                PathSegment::Variable { template, .. } => {
                    for segment in template {
                        shape.push('/');
                        shape.push_str(match segment {
                            Segment::Literal(text) => text,
                            Segment::DoubleWildcard => "**",
                            // A variable's template holds no variables
                            // (`parse_template`).
                            Segment::Wildcard | Segment::Variable { .. } => "*",
                        });
                    }
                }
            }
        }
        if let Some(verb) = &self.custom_verb {
            shape.push(':');
            shape.push_str(verb);
        }
        shape
    }
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
        /// Each field of the path, outermost first, as generated code
        /// names its descriptor.
        fields: Vec<FieldRef>,
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

/// A field as generated code names its descriptor: the value `name` of
/// its message's descriptor module, `Notes.V1.Note.title`.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct FieldRef {
    /// The message's descriptor module, such as `Notes.V1.Note`.
    pub module: ModuleName,
    /// The field's value in it, such as `title`.
    pub name: String,
}

/// Names a field of a generated message as generated code names its
/// descriptor, or `None` for a field without an Elm name, or of a message
/// without one, which is reported where the message is built.
pub type Namer<'a> = &'a dyn Fn(&FieldDescriptor) -> Option<FieldRef>;

/// What a request body holds.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Body {
    /// No body; every field not in the path is in the query.
    None,
    /// `*`: the request, without the fields bound by the path.
    All,
    /// One top-level message field of the request.
    Field(TopField),
}

/// A top-level field of a request or response: a body field or a
/// response body.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TopField {
    /// The field, by proto and JSON name.
    pub field: FieldPath,
    /// The field as generated code names its descriptor.
    pub descriptor: FieldRef,
}

/// One query parameter: a leaf field of the request.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct QueryParam {
    /// The field, whose dotted proto path names the parameter.
    pub field: FieldPath,
    /// Each field of the path, outermost first, as generated code names
    /// its descriptor. The runtime reads from the last whether the
    /// parameter is left out at the field's default.
    pub fields: Vec<FieldRef>,
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
        /// The field path most likely meant, when a field on the way does
        /// not exist and one of its message's is close to it.
        suggestion: Option<String>,
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
        /// The request field most likely meant, when the named one does
        /// not exist and one is close to it.
        suggestion: Option<String>,
    },
    /// `response_body` names no field of the response it can read.
    ResponseBodyField {
        /// The `response_body` value.
        field: String,
        /// Why, as a phrase.
        reason: String,
        /// The response field most likely meant, when the named one does
        /// not exist and one is close to it.
        suggestion: Option<String>,
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
    /// A `custom` rule's kind is not a method a client can send.
    CustomKind {
        /// The kind.
        kind: String,
        /// Why, as a phrase.
        reason: String,
    },
}

/// Checks `rule` (one binding; its own additional bindings are reported,
/// not followed) against the method's `request` and `response`, giving
/// the route or every problem found. `name` names the fields of path
/// variables and query parameters, all of generated messages; a field it
/// has no name for fails the route with no problem of its own, which may
/// leave the problems empty.
pub fn resolve(
    rule: &HttpRule,
    request: &MessageDescriptor,
    response: &MessageDescriptor,
    nested: bool,
    name: Namer,
) -> Result<Route, Vec<RouteError>> {
    let mut errors = Vec::new();
    if nested && !rule.additional_bindings.is_empty() {
        errors.push(RouteError::NestedBindings);
    }
    if rule.template.is_empty() || matches!(&rule.verb, HttpVerb::Custom(kind) if kind.is_empty()) {
        errors.push(RouteError::NoPattern);
        return Err(errors);
    }
    if let HttpVerb::Custom(kind) = &rule.verb
        && let Some(reason) = custom_kind_problem(kind)
    {
        errors.push(RouteError::CustomKind {
            kind: kind.clone(),
            reason: reason.to_owned(),
        });
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

    // Set when `name` has no name for a field the route holds: the route
    // fails without a problem of its own, since the field's was reported
    // where its message is built.
    let mut unnamed = false;
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
            } => match path_field(request, &field, name) {
                Ok((_, None)) => unnamed = true,
                Ok((path, Some(fields))) => {
                    if bound.contains(&path) {
                        errors.push(RouteError::PathFieldTwice {
                            field: path.dotted(),
                        });
                    }
                    bound.push(path.clone());
                    segments.push(PathSegment::Variable {
                        field: path,
                        template,
                        fields,
                    });
                }
                Err(reason) => errors.push(RouteError::PathField {
                    field: field.join("."),
                    reason,
                    suggestion: closest_path(request, &field),
                }),
            },
        }
    }

    // A body that does not resolve leaves the query unknown, so it is not
    // checked: its problems would only follow from the body's.
    let body = match rule.body.as_str() {
        "" => Some(Body::None),
        "*" => Some(Body::All),
        body => match body_field(request, body) {
            Ok(field) => match top_field(&field, name) {
                Some(field) => Some(Body::Field(field)),
                None => {
                    unnamed = true;
                    None
                }
            },
            Err(reason) => {
                errors.push(RouteError::BodyField {
                    field: body.to_owned(),
                    reason,
                    suggestion: closest_path(request, &[body.to_owned()]),
                });
                None
            }
        },
    };

    let response_body = match rule.response_body.as_str() {
        "" => None,
        body => match response_body(response, body) {
            Ok(field) => {
                let field = top_field(&field, name);
                unnamed |= field.is_none();
                field
            }
            Err(reason) => {
                errors.push(RouteError::ResponseBodyField {
                    field: body.to_owned(),
                    reason,
                    suggestion: closest_path(response, &[body.to_owned()]),
                });
                None
            }
        },
    };

    let mut query = Vec::new();
    let request_well_known = well_known(request);
    if let Some(Some(known)) = request_well_known
        && known != WellKnown::Empty
        && body.as_ref().is_some_and(|body| *body != Body::All)
    {
        // Its JSON is not an object of its fields, so they cannot be
        // parameters; `Empty` has none to send.
        errors.push(RouteError::QueryField {
            field: request.full_name().to_owned(),
            reason: "the request is a well-known type, whose JSON has no fields".into(),
        });
    } else if let Some(body) = body
        .as_ref()
        .filter(|body| **body != Body::All && request_well_known.is_none())
    {
        let skip = match body {
            Body::Field(top) => Some(top.field.proto[0].clone()),
            _ => None,
        };
        let mut walk = QueryWalk {
            bound: &bound,
            params: &mut query,
            errors: &mut errors,
            recursion: HashMap::new(),
            name,
            unnamed: false,
        };
        walk.message(request, &FieldPath::default(), &[], skip.as_deref());
        unnamed |= walk.unnamed;
    }

    if errors.is_empty() && !unnamed {
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
        .map(|name| WellKnown::from_name(name).filter(|known| !known.is_enum()))
}

/// Whether a well-known type's JSON is one string or scalar, which a path
/// variable or a query parameter can hold: a timestamp, duration or field
/// mask is a string, a wrapper its wrapped value. `Empty` is an object
/// with nothing in it; `Any`, `Struct`, `Value` and `ListValue` are
/// objects or free-form JSON.
fn has_scalar_json(known: WellKnown) -> bool {
    match known {
        WellKnown::Timestamp
        | WellKnown::Duration
        | WellKnown::FieldMask
        | WellKnown::DoubleValue
        | WellKnown::FloatValue
        | WellKnown::Int64Value
        | WellKnown::UInt64Value
        | WellKnown::Int32Value
        | WellKnown::UInt32Value
        | WellKnown::BoolValue
        | WellKnown::StringValue
        | WellKnown::BytesValue => true,
        WellKnown::Empty
        | WellKnown::Any
        | WellKnown::Struct
        | WellKnown::Value
        | WellKnown::ListValue
        | WellKnown::NullValue => false,
    }
}

/// The field a path variable names, through singular fields of generated
/// messages to a non-repeated scalar, enum or well-known type with a
/// scalar JSON form ([`has_scalar_json`]), with each field of the way
/// named by `name`, or `None` for the names if `name` has none for one.
fn path_field(
    request: &MessageDescriptor,
    names: &[String],
    name: Namer,
) -> Result<(FieldPath, Option<Vec<FieldRef>>), String> {
    if well_known(request).is_some() {
        return Err(format!(
            "the request is `{}`, whose fields have no JSON form of their own",
            request.full_name()
        ));
    }
    let mut message = request.clone();
    let mut path = FieldPath::default();
    let mut fields = Some(Vec::new());
    for (index, field_name) in names.iter().enumerate() {
        let Some(field) = message.get_field_by_name(field_name) else {
            return Err(format!(
                "`{}` has no field `{field_name}`",
                message.full_name()
            ));
        };
        path = path.child(&field);
        fields = fields.zip(name(&field)).map(|(mut fields, named)| {
            fields.push(named);
            fields
        });
        let last = index + 1 == names.len();
        if field.is_list() || field.is_map() {
            return Err(format!(
                "`{}` is repeated, and a path holds one value",
                path.dotted()
            ));
        }
        match field.kind() {
            Kind::Message(inner) if last => {
                if let Some(Some(known)) = well_known(&inner)
                    && has_scalar_json(known)
                {
                    return Ok((path, fields));
                }
                return Err(format!(
                    "`{}` is the message `{}`, and a path holds a scalar, an enum or a \
                     well-known type with a string or scalar JSON form",
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
                if path.proto.len() > NESTING_LIMIT {
                    return Err(format!(
                        "`{}` is nested {} messages deep, past protobuf's limit of {NESTING_LIMIT}",
                        path.dotted(),
                        path.proto.len()
                    ));
                }
                message = inner;
            }
            _ if last => return Ok((path, fields)),
            _ => {
                return Err(format!(
                    "`{}` is not a message, so it has no field `{}`",
                    path.dotted(),
                    names[index + 1]
                ));
            }
        }
    }
    unreachable!("a path variable names at least one field")
}

/// The dotted field path `names` was most likely meant to be, when a
/// field along it does not exist in its message: the path with that
/// field replaced by the message's closest
/// ([`crate::diagnostics::closest`]). `None` when every field exists, or
/// none is close.
fn closest_path(message: &MessageDescriptor, names: &[String]) -> Option<String> {
    let mut message = message.clone();
    for (index, name) in names.iter().enumerate() {
        match message.get_field_by_name(name) {
            Some(field) => match field.kind() {
                Kind::Message(inner) => message = inner,
                _ => return None,
            },
            None => {
                let fields: Vec<String> = message.fields().map(|f| f.name().to_owned()).collect();
                let closest = crate::diagnostics::closest(name, fields.iter().map(String::as_str))?;
                let mut path = names.to_vec();
                path[index] = closest;
                return Some(path.join("."));
            }
        }
    }
    None
}

/// The top-level singular message field `name` of the request, of a
/// generated message.
fn body_field(request: &MessageDescriptor, name: &str) -> Result<FieldDescriptor, String> {
    if well_known(request).is_some() {
        return Err(format!(
            "the request is `{}`, whose fields have no JSON form of their own",
            request.full_name()
        ));
    }
    let Some(field) = request.get_field_by_name(name) else {
        return Err(format!("`{}` has no field `{name}`", request.full_name()));
    };
    if field.is_list() || field.is_map() {
        return Err(format!("`{name}` is repeated"));
    }
    match field.kind() {
        Kind::Message(_) => Ok(field),
        _ => Err(format!("`{name}` is not a message")),
    }
}

/// The top-level field `name` of the response, of a generated message.
fn response_body(response: &MessageDescriptor, name: &str) -> Result<FieldDescriptor, String> {
    if well_known(response).is_some() {
        return Err(format!(
            "the response is `{}`, whose fields have no JSON form of their own",
            response.full_name()
        ));
    }
    response
        .get_field_by_name(name)
        .ok_or_else(|| "the response has no such field".to_owned())
}

/// `field`, a top-level field, with its descriptor as `name` names it, or
/// `None` if it has no name.
fn top_field(field: &FieldDescriptor, name: Namer) -> Option<TopField> {
    Some(TopField {
        field: FieldPath::default().child(field),
        descriptor: name(field)?,
    })
}

/// The message a query walk would expand `field` into: a singular,
/// non-map field of a generated (not well-known) message. The arms of
/// [`QueryWalk::field`] that expand mirror this.
fn expanded(field: &FieldDescriptor) -> Option<MessageDescriptor> {
    if field.is_map() || field.is_list() {
        return None;
    }
    match field.kind() {
        Kind::Message(inner) if well_known(&inner).is_none() => Some(inner),
        _ => None,
    }
}

/// The query parameters of a message, collected depth first.
struct QueryWalk<'a> {
    bound: &'a [FieldPath],
    params: &'a mut Vec<QueryParam>,
    errors: &'a mut Vec<RouteError>,
    /// Whether a message holds itself, by full name, once asked
    /// ([`QueryWalk::recursive`]).
    recursion: HashMap<String, bool>,
    name: Namer<'a>,
    /// Whether `name` had no name for a field the walk reached, as
    /// [`resolve`] keeps it.
    unnamed: bool,
}

impl QueryWalk<'_> {
    /// The parameters of `message`, the message at `prefix`, whose fields
    /// along the way are `refs`.
    fn message(
        &mut self,
        message: &MessageDescriptor,
        prefix: &FieldPath,
        refs: &[FieldRef],
        skip: Option<&str>,
    ) {
        for field in declared_fields(message) {
            if prefix.proto.is_empty() && skip == Some(field.name()) {
                continue;
            }
            let path = prefix.child(&field);
            if self.bound.contains(&path) {
                continue;
            }
            let Some(named) = (self.name)(&field) else {
                self.unnamed = true;
                continue;
            };
            let mut fields = refs.to_vec();
            fields.push(named);
            self.field(&field, path, fields);
        }
    }

    fn refuse(&mut self, path: &FieldPath, reason: impl Into<String>) {
        self.errors.push(RouteError::QueryField {
            field: path.dotted(),
            reason: reason.into(),
        });
    }

    fn field(&mut self, field: &FieldDescriptor, path: FieldPath, fields: Vec<FieldRef>) {
        if field.is_map() {
            return self.refuse(&path, "it is a map");
        }
        let repeated = field.is_list();
        let param = |fields| QueryParam {
            field: path.clone(),
            fields,
        };
        match field.kind() {
            Kind::Message(_) if path.proto.len() > NESTING_LIMIT => self.refuse(
                &path,
                format!(
                    "it is nested {} messages deep, past protobuf's limit of {NESTING_LIMIT}",
                    path.proto.len()
                ),
            ),
            Kind::Message(inner) => match well_known(&inner) {
                Some(Some(known)) if has_scalar_json(known) => self.params.push(param(fields)),
                Some(Some(WellKnown::Empty)) => {}
                Some(Some(WellKnown::Any)) => self.refuse(
                    &path,
                    "`google.protobuf.Any` holds a message whose fields are not known",
                ),
                Some(Some(_)) => {
                    self.refuse(&path, format!("`{}` is free-form JSON", inner.full_name()))
                }
                // Unsupported well-known types are reported by the IR.
                Some(None) => {}
                None if repeated => self.refuse(&path, "it is a repeated message"),
                None if self.recursive(&inner) => {
                    self.refuse(&path, format!("`{}` contains itself", inner.full_name()))
                }
                None => self.message(&inner, &path, &fields, None),
            },
            _ => self.params.push(param(fields)),
        }
    }

    /// Whether `message` holds itself through fields the walk would
    /// expand ([`expanded`]), directly or through other messages.
    ///
    /// Such a message is refused where it is first held and never
    /// expanded. Expanding it and refusing the field that closes the
    /// cycle walks the whole cycle first and reports every field along
    /// it at every depth, which on a cycle of thousands of messages
    /// exhausted memory.
    fn recursive(&mut self, message: &MessageDescriptor) -> bool {
        if let Some(&known) = self.recursion.get(message.full_name()) {
            return known;
        }
        self.settle(message);
        self.recursion[message.full_name()]
    }

    /// Settles [`QueryWalk::recursion`] for `root` and every message it
    /// reaches that is not settled yet: Tarjan's strongly connected
    /// components, a message recursive when its component has another
    /// message or it holds itself directly. One pass from the first
    /// message asked settles a whole chain, where a search per message
    /// asked walked the chain below it again for each.
    ///
    /// A settled message is left out of the graph: its component is
    /// complete, since anything that reaches it and that it reaches was
    /// visited by the pass that settled it.
    fn settle(&mut self, root: &MessageDescriptor) {
        struct Node {
            message: MessageDescriptor,
            fields: Vec<FieldDescriptor>,
            next: usize,
            low: usize,
            holds_itself: bool,
            on_stack: bool,
        }
        let node = |message: &MessageDescriptor, index: usize| Node {
            message: message.clone(),
            fields: declared_fields(message),
            next: 0,
            low: index,
            holds_itself: false,
            on_stack: true,
        };
        // A node's index is its position in `nodes`, assigned when visited.
        let mut nodes: Vec<Node> = vec![node(root, 0)];
        let mut visited: HashMap<String, usize> = HashMap::from([(root.full_name().to_owned(), 0)]);
        let mut stack: Vec<usize> = vec![0];
        let mut path: Vec<usize> = vec![0];
        while let Some(&v) = path.last() {
            let current = &mut nodes[v];
            let Some(field) = current.fields.get(current.next) else {
                path.pop();
                let low = nodes[v].low;
                if let Some(&parent) = path.last() {
                    nodes[parent].low = nodes[parent].low.min(low);
                }
                if low == v {
                    let mut component = vec![];
                    loop {
                        let w = stack.pop().expect("a finished node is on the stack");
                        nodes[w].on_stack = false;
                        component.push(w);
                        if w == v {
                            break;
                        }
                    }
                    let recursive = component.len() > 1 || nodes[v].holds_itself;
                    for w in component {
                        self.recursion
                            .insert(nodes[w].message.full_name().to_owned(), recursive);
                    }
                }
                continue;
            };
            current.next += 1;
            let Some(inner) = expanded(field) else {
                continue;
            };
            let name = inner.full_name();
            if name == current.message.full_name() {
                current.holds_itself = true;
            } else if let Some(&w) = visited.get(name) {
                if nodes[w].on_stack {
                    nodes[v].low = nodes[v].low.min(w);
                }
            } else if !self.recursion.contains_key(name) {
                let w = nodes.len();
                nodes.push(node(&inner, w));
                visited.insert(name.to_owned(), w);
                stack.push(w);
                path.push(w);
            }
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
    fn literals_and_verbs_are_url_text() {
        for template in [
            "/v1/a-b_c~d.e/{name}",
            "/v1/!$&'()+,;@/{name}",
            "/v1/%2F%e2%82%ac/{name}:do-it.now",
            "/v1/{name=shelves/*}/...:x",
        ] {
            parse_template(template).unwrap_or_else(|e| panic!("{template}: {e}"));
        }
        for (template, reason) in [
            ("/../admin/{a}", "the literal `..` is a dot segment"),
            ("/v1/./{a}", "the literal `.` is a dot segment"),
            ("/v1/%2e%2E/{a}", "the literal `%2e%2E` is a dot segment"),
            ("/v1/.%2e/{a}", "dot segment"),
            ("/v1/{a=x/../*}", "the literal `..` is a dot segment"),
            ("/v1/x#y/{a}", "the literal `x#y` holds `#`"),
            ("/v1/x?y/{a}", "holds `?`"),
            ("/v1/\u{1}/{a}", "the literal `\\u{1}` holds `\\u{1}`"),
            ("/v1/caf\u{e9}/{a}", "holds `\u{e9}`"),
            ("/v1/100%/{a}", "a `%` that opens no escape"),
            ("/v1/%zz/{a}", "a `%` that opens no escape"),
            ("/v1/{a}:run?x", "the custom verb `:run?x` holds `?`"),
            ("/v1/{a}:a\"b", "holds `\\\"`"),
        ] {
            let error = parse_template(template).expect_err(template);
            assert!(error.reason.contains(reason), "{template}: {error}");
        }
    }

    #[test]
    fn custom_kinds_are_methods_a_browser_sends() {
        for kind in ["GET", "LIST", "PROPFIND", "x-y.z"] {
            assert_eq!(custom_kind_problem(kind), None, "{kind}");
        }
        for (kind, reason) in [
            ("", "not an HTTP method"),
            ("GET\r\nX-Evil: 1", "not an HTTP method"),
            ("SPACE KIND", "not an HTTP method"),
            ("TRACE", "browsers refuse"),
            ("connect", "browsers refuse"),
            ("Track", "browsers refuse"),
        ] {
            let problem = custom_kind_problem(kind).expect(kind);
            assert!(problem.contains(reason), "{kind}: {problem}");
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
                fields: Vec::new(),
            }
            .is_single()
        };
        assert!(single(var("a", vec![])));
        assert!(single(var("a", vec![Segment::Wildcard])));
        assert!(!single(var("a", vec![Segment::DoubleWildcard])));
        assert!(!single(var("a", vec![lit("x"), Segment::Wildcard])));
    }
}
