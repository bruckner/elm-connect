//! A method's route functions in its service's module: one per binding of
//! its HTTP rule, `routeGetNote0 : GetNoteRequest -> ( Rpc.Route.Route,
//! Maybe Rpc.Route.PathError )`, which builds the binding's path, query and
//! body from the typed request, and checks each path value against its
//! variable's template. A binding the emitter cannot type (a
//! field of a message outside the generated packages, a recursive message,
//! `bytes` held as `Bytes`) is interpreted
//! instead: its route function is `Proto.Http.interpret` of its binding
//! over the request's JSON.

use std::collections::HashMap;

use super::field::{self, FieldShape, Present, ValueShape, Zeroed};
use super::scalar::Repr;
use super::{Emitter, JSON_ENCODE, PROTO_HTTP};
use crate::elm::ast::{BinOp, Expr, LetBinding, ModuleName, Pattern};
use crate::elm::build::{apply, binop, lambda, list, qualified, record, string, var};
use crate::ir::{Field, Message, ModuleName as IrModule, Oneof, OneofVariant, TypeRef};
use crate::route::{Body, FieldPath, PathSegment, Route, Segment};

/// The runtime's routes, home of the helpers route functions call.
pub(super) const RPC_ROUTE: &str = "Rpc.Route";

/// The name route functions call their request; the call's own names never
/// end in `_` but for Elm's reserved words.
pub(super) const REQUEST: &str = "request_";

/// Every generated message by full proto name, with its package's module.
pub(crate) type Messages<'p> = HashMap<&'p str, (&'p Message, &'p IrModule)>;

/// Each request message's query parameters over every binding of every
/// generated method taking it, in field declaration order, depth first:
/// what the message's query encoder (`queryOfEverything`) writes. A
/// binding's own query is this less the fields its path and body hold.
pub type Queries = HashMap<String, Vec<FieldPath>>;

/// The [`Queries`] of `packages`, ordered by `pool`'s declarations.
pub fn queries(pool: &prost_reflect::DescriptorPool, packages: &[crate::ir::Package]) -> Queries {
    let mut queries: Queries = HashMap::new();
    for package in packages {
        for service in &package.services {
            for method in &service.methods {
                let TypeRef::Message(name) = &method.input else {
                    continue;
                };
                for route in &method.routes {
                    let params = queries.entry(name.proto_full_name.clone()).or_default();
                    for param in &route.query {
                        if !params.contains(&param.field) {
                            params.push(param.field.clone());
                        }
                    }
                }
            }
        }
    }
    queries.retain(|_, params| !params.is_empty());
    for (name, params) in queries.iter_mut() {
        if let Some(message) = pool.get_message_by_name(name) {
            params.sort_by_cached_key(|param| declaration_key(&message, &param.proto));
        }
    }
    queries
}

/// The position of each field of `path` among its message's fields, as
/// declared.
fn declaration_key(message: &prost_reflect::MessageDescriptor, path: &[String]) -> Vec<usize> {
    let mut key = Vec::new();
    let mut message = Some(message.clone());
    for name in path {
        let Some(current) = message.take() else {
            break;
        };
        let Some(index) = current.fields().position(|f| f.name() == name) else {
            break;
        };
        key.push(index);
        let field = current.fields().nth(index).expect("the field found");
        if let prost_reflect::Kind::Message(next) = field.kind() {
            message = Some(next);
        }
    }
    key
}

/// The name of a message's query encoder in its package's module.
pub(super) fn query_encoder_name(message: &Message) -> String {
    format!("queryOf{}", message.elm_name)
}

/// One step of a field path through the typed request.
enum Step<'p> {
    Field(&'p Field),
    Member(&'p Oneof, &'p OneofVariant, &'p IrModule),
}

/// A value read from the request: its expression, and whether it is a
/// `Maybe` (a field with presence on the way, or a oneof member).
struct Read {
    expr: Expr,
    maybe: bool,
}

/// A leaf field read from the request: the read, the shape of its values,
/// whether it is repeated, and whether it has presence (proto3 `optional`, a
/// message, a oneof member), so that it is left out only when unset.
struct Leaf<'p> {
    read: Read,
    value: ValueShape<'p>,
    repeated: bool,
    presence: bool,
}

/// How a leaf becomes text.
enum Text {
    Same,
    Fn(Expr),
}

impl Text {
    fn apply(&self, value: Expr) -> Expr {
        match self {
            Text::Same => value,
            Text::Fn(f) => super::call(f.clone(), [value]),
        }
    }

    fn function(&self) -> Expr {
        match self {
            Text::Same => qualified("Basics", "identity"),
            Text::Fn(f) => f.clone(),
        }
    }
}

/// What a route function counts: typed, or interpreted.
pub(crate) struct Typed {
    pub(crate) body: Expr,
    pub(crate) interpreted: bool,
}

impl Emitter {
    /// The body of a route function for `route`, of a method whose request
    /// type is `input`: typed when every field it reads can be, else the
    /// interpreter over `binding`, the route as data.
    pub(super) fn route_body(
        &mut self,
        messages: &Messages,
        queries: &Queries,
        input: &TypeRef,
        route: &Route,
        binding: Expr,
        encode_request: Expr,
    ) -> Typed {
        match self.typed_route(messages, queries, input, route, encode_request.clone()) {
            Some(body) => Typed {
                body,
                interpreted: false,
            },
            None => Typed {
                body: apply(
                    self.reference((PROTO_HTTP, "interpret")),
                    [binding, apply(encode_request, [var(REQUEST)])],
                ),
                interpreted: true,
            },
        }
    }

    fn typed_route(
        &mut self,
        messages: &Messages,
        queries: &Queries,
        input: &TypeRef,
        route: &Route,
        encode_request: Expr,
    ) -> Option<Expr> {
        // A well-known request type has no record fields: its routes read
        // none, so only a route without variables and query is typed.
        let request = match input {
            TypeRef::Message(name) => Some(messages.get(name.proto_full_name.as_str())?.0),
            _ => None,
        };
        // The path: literals and one variable per `segmentN_`.
        let mut checks = Vec::new();
        let mut values = Vec::new();
        let mut parts: Vec<Expr> = Vec::new();
        let mut text = String::new();
        for (index, segment) in route.segments.iter().enumerate() {
            if index > 0 {
                text.push('/');
            }
            match segment {
                PathSegment::Literal(literal) => text.push_str(literal),
                PathSegment::Variable {
                    field, template, ..
                } => {
                    let read = self.read(messages, request?, &field.proto)?;
                    let value = self.path_text(read)?;
                    let name = string(field.json.join("."));
                    let bound = format!("value{}_", checks.len());
                    let (encode, check) = if segment.is_single() {
                        let tmpl = match template.as_slice() {
                            [Segment::Literal(literal)] => literal.clone(),
                            _ => "*".to_owned(),
                        };
                        (
                            "segment",
                            apply(
                                self.reference((RPC_ROUTE, "checkSegment")),
                                [name, string(tmpl), var(bound.clone())],
                            ),
                        )
                    } else {
                        let tmpl: Vec<Expr> = template
                            .iter()
                            .map(|segment| {
                                string(match segment {
                                    Segment::Literal(literal) => literal.as_str(),
                                    Segment::DoubleWildcard => "**",
                                    _ => "*",
                                })
                            })
                            .collect();
                        (
                            "segments",
                            apply(
                                self.reference((RPC_ROUTE, "checkSegments")),
                                [
                                    name,
                                    crate::elm::build::inline_list(tmpl),
                                    var(bound.clone()),
                                ],
                            ),
                        )
                    };
                    if !text.is_empty() {
                        parts.push(string(std::mem::take(&mut text)));
                    }
                    parts.push(apply(
                        self.reference((RPC_ROUTE, encode)),
                        [var(bound.clone())],
                    ));
                    values.push(LetBinding {
                        name: bound,
                        annotation: None,
                        params: Vec::new(),
                        body: value,
                    });
                    checks.push(check);
                }
            }
        }
        if let Some(verb) = &route.custom_verb {
            text.push(':');
            text.push_str(verb);
        }
        if !text.is_empty() {
            parts.push(string(text));
        }
        let path = parts
            .into_iter()
            .rev()
            .reduce(|right, left| binop(BinOp::Append, left, right))
            .unwrap_or_else(|| string(""));
        // The query: the request message's query encoder, less the fields
        // this binding's path and body hold.
        let query = if route.query.is_empty() {
            list([])
        } else {
            let request = request?;
            let all = queries.get(&request.proto_full_name)?;
            if !self.query_typed(messages, request, all) {
                return None;
            }
            let module = messages.get(request.proto_full_name.as_str())?.1;
            let encoder = self.generated_value(module, query_encoder_name(request));
            let pairs = apply(encoder, [var(REQUEST)]);
            let excluded: Vec<Expr> = all
                .iter()
                .filter(|field| !route.query.iter().any(|param| &param.field == *field))
                .map(|field| string(field.dotted()))
                .collect();
            if excluded.is_empty() {
                pairs
            } else {
                apply(
                    self.reference((RPC_ROUTE, "except")),
                    [crate::elm::build::inline_list(excluded), pairs],
                )
            }
        };
        // The body.
        let body = match &route.body {
            Body::None => var(self.core("Nothing")),
            Body::All => {
                let paths: Vec<Expr> = route
                    .segments
                    .iter()
                    .filter_map(|segment| match segment {
                        PathSegment::Variable { field, .. } => {
                            Some(crate::elm::build::inline_list(
                                field.json.iter().map(|key| string(key.clone())),
                            ))
                        }
                        PathSegment::Literal(_) => None,
                    })
                    .collect();
                let json = apply(encode_request, [var(REQUEST)]);
                let json = if paths.is_empty() {
                    json
                } else {
                    apply(
                        self.reference((RPC_ROUTE, "without")),
                        [crate::elm::build::inline_list(paths), json],
                    )
                };
                apply(var(self.core("Just")), [json])
            }
            Body::Field(top) => {
                let field = request?
                    .fields
                    .iter()
                    .find(|f| f.proto_name == top.field.proto[0])?;
                if field.cyclic {
                    return None;
                }
                let shape = match field::field_shape(field, &HashMap::new(), self.holding) {
                    FieldShape::Maybe(value) => value,
                    _ => return None,
                };
                let encoder = self.value_encoder(shape);
                let empty = apply(self.reference((JSON_ENCODE, "object")), [list([])]);
                apply(
                    var(self.core("Just")),
                    [apply(
                        qualified("Maybe", "withDefault"),
                        [
                            empty,
                            apply(
                                qualified("Maybe", "map"),
                                [
                                    encoder,
                                    crate::elm::build::access(var(REQUEST), field.elm_name.clone()),
                                ],
                            ),
                        ],
                    )],
                )
            }
        };
        let invalid = match checks.len() {
            0 => var(self.core("Nothing")),
            1 => checks.pop().unwrap(),
            _ => apply(self.reference((RPC_ROUTE, "firstInvalid")), [list(checks)]),
        };
        let response_body = match &route.response_body {
            Some(top) => apply(var(self.core("Just")), [string(top.field.json[0].clone())]),
            None => var(self.core("Nothing")),
        };
        let result = record([
            ("method", string(route.verb.as_str())),
            ("path", path),
            ("query", query),
            ("body", body),
            ("responseBody", response_body),
            ("invalid", invalid),
        ]);
        Some(if values.is_empty() {
            result
        } else {
            crate::elm::build::let_in(values, result)
        })
    }

    /// `message`'s query encoder over `params`, `queryOfEverything :
    /// Everything -> List ( String, String )`, or `None` when a parameter
    /// cannot be typed.
    pub(super) fn query_encoder(
        &mut self,
        messages: &Messages,
        message: &Message,
        params: &[FieldPath],
    ) -> Option<crate::elm::ast::Decl> {
        let body = self.query_encoder_body(messages, message, params)?;
        let pair = crate::elm::ast::Type::Tuple(vec![
            crate::elm::build::ty("String", []),
            crate::elm::build::ty("String", []),
        ]);
        Some(crate::elm::ast::Decl::Value {
            doc: Some(format!(
                "The query parameters of a [`{0}`](#{0}) whose bindings put fields in the query: every such field that holds a value.",
                message.elm_name
            )),
            name: query_encoder_name(message),
            annotation: crate::elm::build::ty_fn(
                [crate::elm::build::ty(message.elm_name.clone(), [])],
                crate::elm::build::ty("List", [pair]),
            ),
            params: vec![crate::elm::build::pvar(REQUEST)],
            body,
        })
    }

    /// The body of `message`'s query encoder over `params`, or `None` when
    /// a parameter cannot be typed.
    pub(super) fn query_encoder_body(
        &mut self,
        messages: &Messages,
        message: &Message,
        params: &[FieldPath],
    ) -> Option<Expr> {
        let mut pairs = Vec::new();
        for param in params {
            let read = self.read(messages, message, &param.proto)?;
            pairs.push(self.query_pairs(param.dotted(), read)?);
        }
        Some(match pairs.len() {
            0 => list([]),
            1 => pairs.pop().unwrap(),
            _ => apply(qualified("List", "concat"), [list(pairs)]),
        })
    }

    /// Whether `message`'s query encoder over `params` can be typed, checked
    /// without touching this module's imports.
    fn query_typed(&self, messages: &Messages, message: &Message, params: &[FieldPath]) -> bool {
        let mut scratch = Emitter {
            module: self.module.clone(),
            imports: Default::default(),
            unqualified: Default::default(),
            holding: self.holding,
            enum_unknown: self.enum_unknown,
        };
        scratch
            .query_encoder_body(messages, message, params)
            .is_some()
    }

    /// The value at a field path of the request.
    fn read<'p>(
        &mut self,
        messages: &Messages<'p>,
        request: &'p Message,
        path: &[String],
    ) -> Option<Leaf<'p>> {
        let mut message = request;
        let mut steps = Vec::new();
        for (index, name) in path.iter().enumerate() {
            let step = if let Some(field) = message.fields.iter().find(|f| &f.proto_name == name) {
                Step::Field(field)
            } else {
                let (oneof, variant) = message.oneofs.iter().find_map(|oneof| {
                    oneof
                        .variants
                        .iter()
                        .find(|v| &v.proto_name == name)
                        .map(|v| (oneof, v))
                })?;
                let module = messages.get(message.proto_full_name.as_str())?.1;
                Step::Member(oneof, variant, module)
            };
            if index + 1 < path.len() {
                let ty = match &step {
                    Step::Field(field) if !field.cyclic => &field.ty,
                    Step::Member(_, variant, _) if !variant.cyclic => &variant.ty,
                    _ => return None,
                };
                message = match ty {
                    TypeRef::Message(name) => messages.get(name.proto_full_name.as_str())?.0,
                    _ => return None,
                };
            }
            steps.push(step);
        }
        let mut read = Read {
            expr: var(REQUEST),
            maybe: false,
        };
        let mut leaf = None;
        for step in steps {
            match step {
                Step::Field(field) => {
                    let shape = field::field_shape(field, &HashMap::new(), self.holding);
                    let (presence, value, repeated) = match shape {
                        FieldShape::Plain(zeroed) => (false, ValueShape::Zeroed(zeroed), false),
                        FieldShape::Maybe(value) => (true, value, false),
                        FieldShape::List(value) => (false, value, true),
                        _ => return None,
                    };
                    read = if read.maybe {
                        let how = if presence { "andThen" } else { "map" };
                        Read {
                            expr: apply(
                                qualified("Maybe", how),
                                [Expr::Accessor(field.elm_name.clone()), read.expr],
                            ),
                            maybe: true,
                        }
                    } else {
                        Read {
                            expr: crate::elm::build::access(read.expr, field.elm_name.clone()),
                            maybe: presence,
                        }
                    };
                    leaf = Some((value, repeated, presence));
                }
                Step::Member(oneof, variant, module) => {
                    let holding = field::field_holding(variant.jstype, self.holding);
                    let value = field::value_shape(&variant.ty, holding);
                    let own = *module == self.module;
                    let ctor = |name: &str| -> Pattern {
                        Pattern::Ctor {
                            module: (!own).then(|| ModuleName::new(module.to_string())),
                            name: name.to_owned(),
                            args: vec![Pattern::Var("member_".into())],
                        }
                    };
                    if !own {
                        self.imports.entry(module.to_string()).or_default();
                    }
                    let get = |subject: Expr, just: &str, nothing: &str| {
                        crate::elm::build::case(
                            crate::elm::build::access(subject, oneof.elm_field_name.clone()),
                            [
                                (
                                    ctor(&variant.elm_ctor),
                                    apply(var(just.to_owned()), [var("member_")]),
                                ),
                                (Pattern::Wildcard, var(nothing.to_owned())),
                            ],
                        )
                    };
                    let just = self.core("Just");
                    let nothing = self.core("Nothing");
                    read = if read.maybe {
                        Read {
                            expr: apply(
                                qualified("Maybe", "andThen"),
                                [
                                    lambda(
                                        [Pattern::Var("message_".into())],
                                        get(var("message_"), just, nothing),
                                    ),
                                    read.expr,
                                ],
                            ),
                            maybe: true,
                        }
                    } else {
                        Read {
                            expr: get(read.expr, just, nothing),
                            maybe: true,
                        }
                    };
                    leaf = Some((value, false, true));
                }
            }
        }
        let (value, repeated, presence) = leaf?;
        Some(Leaf {
            read,
            value,
            repeated,
            presence,
        })
    }

    /// How a leaf value becomes path or query text.
    fn text(&mut self, value: ValueShape) -> Option<Text> {
        let repr_text = |emitter: &mut Emitter, repr: Repr, value: ValueShape| -> Option<Text> {
            Some(match repr {
                Repr::String | Repr::Int64 | Repr::UInt64 => Text::Same,
                Repr::Int32 | Repr::UInt32 => Text::Fn(qualified("String", "fromInt")),
                Repr::Bool => Text::Fn(emitter.reference((RPC_ROUTE, "boolText"))),
                Repr::BytesAsBytes => return None,
                Repr::Float | Repr::Bytes | Repr::Int64AsInt | Repr::UInt64AsInt => {
                    let encoder = emitter.value_encoder(value);
                    Text::Fn(apply(emitter.reference((RPC_ROUTE, "viaJson")), [encoder]))
                }
            })
        };
        match value {
            ValueShape::Zeroed(Zeroed::Scalar(repr))
            | ValueShape::Present(Present::Wrapper(repr)) => repr_text(self, repr, value),
            ValueShape::Zeroed(Zeroed::Enum(..)) | ValueShape::Present(Present::FieldMask) => {
                let encoder = self.value_encoder(value);
                Some(Text::Fn(apply(
                    self.reference((RPC_ROUTE, "viaJson")),
                    [encoder],
                )))
            }
            ValueShape::Present(Present::Timestamp) => {
                Some(Text::Fn(self.reference(("Proto.Timestamp", "toString"))))
            }
            ValueShape::Present(Present::Duration) => {
                Some(Text::Fn(self.reference(("Proto.Duration", "toString"))))
            }
            _ => None,
        }
    }

    /// The zero value of a leaf without presence.
    fn zero(&mut self, value: ValueShape) -> Option<Expr> {
        match value {
            ValueShape::Zeroed(Zeroed::Scalar(Repr::BytesAsBytes)) => None,
            ValueShape::Zeroed(Zeroed::Scalar(repr)) => Some(self.scalar_zero(repr)),
            ValueShape::Zeroed(Zeroed::Enum(name, zero_ctor)) => {
                Some(self.generated_value(&name.module, zero_ctor.to_owned()))
            }
            _ => None,
        }
    }

    /// A path variable's text: the leaf's, or its default's when a message
    /// on the way or the leaf itself is unset.
    fn path_text(&mut self, leaf: Leaf) -> Option<Expr> {
        let Leaf {
            read,
            value,
            repeated,
            ..
        } = leaf;
        if repeated {
            return None;
        }
        let text = self.text(value)?;
        if !read.maybe {
            return Some(text.apply(read.expr));
        }
        Some(match self.zero(value) {
            Some(zero) => text.apply(apply(qualified("Maybe", "withDefault"), [zero, read.expr])),
            None => apply(
                qualified("Maybe", "withDefault"),
                [
                    string(""),
                    apply(qualified("Maybe", "map"), [text.function(), read.expr]),
                ],
            ),
        })
    }

    /// A query parameter's pairs, by the `Rpc.Route` helper of its kind:
    /// one taking the name and the value, with the zero and the text the
    /// helper's own.
    fn query_pairs(&mut self, name: String, leaf: Leaf) -> Option<Expr> {
        let Leaf {
            read,
            value,
            repeated,
            presence,
        } = leaf;
        let text = self.text(value)?;
        let mapped = |over: &str, values: Expr| match &text {
            Text::Same => values,
            Text::Fn(f) => apply(qualified(over, "map"), [f.clone(), values]),
        };
        if repeated {
            let values = if read.maybe {
                apply(qualified("Maybe", "withDefault"), [list([]), read.expr])
            } else {
                read.expr
            };
            let values = mapped("List", values);
            return Some(apply(
                self.reference((RPC_ROUTE, "repeated")),
                [string(name), values],
            ));
        }
        match self.zero(value) {
            Some(zero) if !presence => {
                let value_expr = if read.maybe {
                    apply(qualified("Maybe", "withDefault"), [zero.clone(), read.expr])
                } else {
                    read.expr
                };
                let helper = match value {
                    ValueShape::Zeroed(Zeroed::Scalar(repr)) => match repr {
                        Repr::String | Repr::Bytes => Some("string"),
                        Repr::Int32 | Repr::UInt32 => Some("int"),
                        Repr::Int64 | Repr::UInt64 => Some("int64"),
                        Repr::Bool => Some("bool"),
                        Repr::Float => Some("float"),
                        Repr::Int64AsInt | Repr::UInt64AsInt | Repr::BytesAsBytes => None,
                    },
                    _ => None,
                };
                Some(match (helper, value) {
                    (Some(helper), _) => apply(
                        self.reference((RPC_ROUTE, helper)),
                        [string(name), value_expr],
                    ),
                    (None, ValueShape::Zeroed(Zeroed::Enum(..))) => {
                        let encoder = self.value_encoder(value);
                        apply(
                            self.reference((RPC_ROUTE, "enum")),
                            [string(name), zero, encoder, value_expr],
                        )
                    }
                    (None, _) => apply(
                        self.reference((RPC_ROUTE, "unlessZero")),
                        [string(name), zero, text.function(), value_expr],
                    ),
                })
            }
            _ if read.maybe => {
                let values = mapped("Maybe", read.expr);
                Some(apply(
                    self.reference((RPC_ROUTE, "optional")),
                    [string(name), values],
                ))
            }
            _ => None,
        }
    }
}
