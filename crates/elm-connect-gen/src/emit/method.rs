//! A method's declaration in its service's module (design §4): a function
//! from the request to an `Rpc.Call`, built point-free with `Rpc.call` from
//! the method's descriptor, its HTTP bindings written out as data.

use super::field::value_shape;
use super::{Emitter, RPC};
use crate::elm::ast::{Decl, Expr, Type};
use crate::elm::build::{apply, inline_list, list, record, string, ty_fn, var};
use crate::ir::{Method, TypeRef};
use crate::route::{Body, PathSegment, QueryParam, Route, Segment};

impl Emitter {
    /// `getNote : GetNoteRequest -> Rpc.Call GetNoteRequest Note`: the
    /// method's service, name, idempotency, codecs and bindings, given to
    /// `Rpc.call`. A method without an HTTP rule has no bindings; the
    /// runtime calls it over the implicit route.
    ///
    /// The value binds no locals and every name in it is qualified, so it
    /// cannot clash with the package module's names or the runtime's,
    /// whatever the method is called.
    pub(super) fn method(&mut self, service: &str, method: &Method) -> Decl {
        let request = self.method_type(&method.input);
        let response = self.method_type(&method.output);
        let encode = self.value_encoder(value_shape(&method.input, self.int64));
        let decoder = self.value_decoder(value_shape(&method.output, self.int64));
        let idempotent = if method.idempotent { "True" } else { "False" };
        let bindings: Vec<Expr> = method
            .routes
            .iter()
            .map(|route| self.binding(route))
            .collect();
        let body = apply(
            self.reference((RPC, "call")),
            [record([
                ("service", string(service)),
                ("method", string(method.proto_name.clone())),
                ("idempotent", var(idempotent)),
                ("encodeJson", encode),
                ("jsonDecoder", decoder),
                ("bindings", list(bindings)),
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

    /// `Rpc.binding { … }`: one binding of a method's HTTP rule.
    fn binding(&mut self, route: &Route) -> Expr {
        let path: Vec<Expr> = route
            .segments
            .iter()
            .map(|segment| self.path_segment(segment))
            .collect();
        let custom_verb = maybe(route.custom_verb.as_deref().map(string));
        let body = match &route.body {
            Body::None => self.reference((RPC, "noBody")),
            Body::All => self.reference((RPC, "wholeBody")),
            Body::Field(field) => apply(
                self.reference((RPC, "bodyField")),
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
            self.reference((RPC, "binding")),
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
            PathSegment::Literal(text) => {
                apply(self.reference((RPC, "literal")), [string(text.clone())])
            }
            PathSegment::Variable { field, template } => {
                let names = inline_list(field.json.iter().map(|name| string(name.clone())));
                let template: Vec<Expr> = template
                    .iter()
                    .map(|segment| self.template_segment(segment))
                    .collect();
                apply(
                    self.reference((RPC, "variable")),
                    [names, inline_list(template)],
                )
            }
        }
    }

    fn template_segment(&mut self, segment: &Segment) -> Expr {
        match segment {
            Segment::Literal(text) => {
                apply(self.reference((RPC, "literal")), [string(text.clone())])
            }
            Segment::Wildcard => self.reference((RPC, "wildcard")),
            Segment::DoubleWildcard => self.reference((RPC, "doubleWildcard")),
            // A variable's template holds no variables (`route::parse_template`).
            Segment::Variable { .. } => unreachable!("a variable inside a variable"),
        }
    }

    fn query_param(&mut self, param: &QueryParam) -> Expr {
        let zero = maybe(param.zero.as_deref().map(string));
        apply(
            self.reference((RPC, "param")),
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
