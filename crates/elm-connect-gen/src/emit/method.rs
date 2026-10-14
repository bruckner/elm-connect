//! A method's declaration in its service's module (design §4): a function
//! from the request to an `Rpc.Call`, built point-free with `Rpc.call` from
//! the method's typed record, its HTTP bindings written out as data.

use super::field::{Present, ValueShape, value_shape};
use super::scalar::Repr;
use super::{Emitter, PROTO_HTTP, PROTO_WELL_KNOWN, RPC};
use crate::elm::ast::{Decl, Expr, Type};
use crate::elm::build::{apply, inline_list, list, record, string, ty_fn, var};
use crate::ir::{Method, TypeRef, WellKnown};
use crate::route::{Body, PathSegment, QueryParam, Route, Segment};

impl Emitter {
    /// `getNote : GetNoteRequest -> Rpc.Call GetNoteRequest Note`:
    /// `Rpc.call` of the method's `Proto.Method.Method`, the typed records
    /// of its request and response and its descriptor (service, name,
    /// idempotency, type names and bindings). A method without an HTTP rule
    /// has no bindings; the runtime calls it over the implicit route.
    ///
    /// The value binds no locals and every name in it is qualified, so it
    /// cannot clash with the package module's names or the runtime's,
    /// whatever the method is called.
    pub(super) fn method(&mut self, service: &str, method: &Method) -> Decl {
        let request = self.method_type(&method.input);
        let response = self.method_type(&method.output);
        let request_record = self.message_value(&method.input);
        let response_record = self.message_value(&method.output);
        let idempotent = if method.idempotent { "True" } else { "False" };
        let bindings: Vec<Expr> = method
            .routes
            .iter()
            .map(|route| self.binding(route))
            .collect();
        let descriptor = record([
            ("service", string(service)),
            ("name", string(method.proto_name.clone())),
            ("idempotent", var(idempotent)),
            ("input", string(proto_full_name(&method.input))),
            ("output", string(proto_full_name(&method.output))),
            ("bindings", list(bindings)),
        ]);
        let body = apply(
            self.reference((RPC, "call")),
            [record([
                ("request", request_record),
                ("response", response_record),
                ("descriptor", descriptor),
            ])],
        );
        let call = self.library_type(RPC, "Call", [request.clone(), response]);
        Decl::Value {
            doc: None,
            name: method.elm_name.clone(),
            annotation: ty_fn([request], call),
            params: Vec::new(),
            body,
        }
    }

    /// The typed record of a method's request or response type: the
    /// generated `messageFoo`, or the runtime's for a well-known type, in
    /// the Elm form the `int64` option gives the 64-bit wrappers.
    fn message_value(&mut self, ty: &TypeRef) -> Expr {
        match ty {
            TypeRef::Message(name) => self.generated_value(&name.module, name.message_value_name()),
            TypeRef::WellKnown(known) => {
                let name = match (known, value_shape(ty, self.int64)) {
                    (
                        WellKnown::Int64Value,
                        ValueShape::Present(Present::Wrapper(Repr::Int64AsInt)),
                    ) => "int64ValueAsInt",
                    (
                        WellKnown::UInt64Value,
                        ValueShape::Present(Present::Wrapper(Repr::Int64AsInt)),
                    ) => "uint64ValueAsInt",
                    _ => well_known_value(*known),
                };
                self.reference((PROTO_WELL_KNOWN, name))
            }
            // A method's types are messages (`ir::Method::input`).
            TypeRef::Scalar(_) | TypeRef::Enum { .. } => {
                unreachable!("a method type that is not a message")
            }
        }
    }

    /// `Proto.Http.binding { … }`: one binding of a method's HTTP rule.
    fn binding(&mut self, route: &Route) -> Expr {
        let path: Vec<Expr> = route
            .segments
            .iter()
            .map(|segment| self.path_segment(segment))
            .collect();
        let custom_verb = maybe(route.custom_verb.as_deref().map(string));
        let body = match &route.body {
            Body::None => self.reference((PROTO_HTTP, "noBody")),
            Body::All => self.reference((PROTO_HTTP, "wholeBody")),
            Body::Field(field) => apply(
                self.reference((PROTO_HTTP, "bodyField")),
                [string(field.json[0].clone())],
            ),
        };
        let response_body = maybe(
            route
                .response_body
                .as_ref()
                .map(|field| string(field.json[0].clone())),
        );
        let query: Vec<Expr> = route
            .query
            .iter()
            .map(|param| self.query_param(param))
            .collect();
        apply(
            self.reference((PROTO_HTTP, "binding")),
            [record([
                ("method", string(route.verb.as_str())),
                ("path", list(path)),
                ("customVerb", custom_verb),
                ("body", body),
                ("responseBody", response_body),
                ("query", list(query)),
            ])],
        )
    }

    /// The Elm type of a method's request or response.
    fn method_type(&mut self, ty: &TypeRef) -> Type {
        let shape = value_shape(ty, self.int64);
        self.value_type(shape)
    }

    fn path_segment(&mut self, segment: &PathSegment) -> Expr {
        match segment {
            PathSegment::Literal(text) => apply(
                self.reference((PROTO_HTTP, "literal")),
                [string(text.clone())],
            ),
            PathSegment::Variable { field, template } => {
                let names = inline_list(field.json.iter().map(|name| string(name.clone())));
                let template: Vec<Expr> = template
                    .iter()
                    .map(|segment| self.template_segment(segment))
                    .collect();
                apply(
                    self.reference((PROTO_HTTP, "variable")),
                    [names, inline_list(template)],
                )
            }
        }
    }

    fn template_segment(&mut self, segment: &Segment) -> Expr {
        match segment {
            Segment::Literal(text) => apply(
                self.reference((PROTO_HTTP, "literal")),
                [string(text.clone())],
            ),
            Segment::Wildcard => self.reference((PROTO_HTTP, "wildcard")),
            Segment::DoubleWildcard => self.reference((PROTO_HTTP, "doubleWildcard")),
            // A variable's template holds no variables (`route::parse_template`).
            Segment::Variable { .. } => unreachable!("a variable inside a variable"),
        }
    }

    fn query_param(&mut self, param: &QueryParam) -> Expr {
        let zero = maybe(param.zero.as_deref().map(string));
        apply(
            self.reference((PROTO_HTTP, "param")),
            [
                string(param.field.dotted()),
                inline_list(param.field.json.iter().map(|name| string(name.clone()))),
                zero,
            ],
        )
    }
}

/// `Just value`, or `Nothing`.
fn maybe(value: Option<Expr>) -> Expr {
    match value {
        Some(value) => apply(var("Just"), [value]),
        None => var("Nothing"),
    }
}

/// A method type's full proto name, such as `notes.v1.Note`.
fn proto_full_name(ty: &TypeRef) -> String {
    match ty {
        TypeRef::Message(name) => name.proto_full_name.clone(),
        TypeRef::WellKnown(known) => known.proto_full_name().to_owned(),
        // A method's types are messages (`ir::Method::input`).
        TypeRef::Scalar(_) | TypeRef::Enum { .. } => {
            unreachable!("a method type that is not a message")
        }
    }
}

/// The runtime's typed record of a well-known type, in `Proto.WellKnown`.
fn well_known_value(known: WellKnown) -> &'static str {
    match known {
        WellKnown::Timestamp => "timestamp",
        WellKnown::Duration => "duration",
        WellKnown::FieldMask => "fieldMask",
        WellKnown::Empty => "empty",
        WellKnown::Struct => "struct",
        WellKnown::Value => "value",
        WellKnown::ListValue => "listValue",
        WellKnown::DoubleValue => "doubleValue",
        WellKnown::FloatValue => "floatValue",
        WellKnown::Int64Value => "int64Value",
        WellKnown::UInt64Value => "uint64Value",
        WellKnown::Int32Value => "int32Value",
        WellKnown::UInt32Value => "uint32Value",
        WellKnown::BoolValue => "boolValue",
        WellKnown::StringValue => "stringValue",
        WellKnown::BytesValue => "bytesValue",
    }
}
