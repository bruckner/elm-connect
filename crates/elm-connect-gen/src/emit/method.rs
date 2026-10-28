//! A method's declarations in its service's module (design §4): its
//! call, a function from the request to an `Rpc.Call`, built point-free
//! with `Rpc.call` from the codecs of its request and response, its
//! service's and its own name, its idempotency when the proto declares one,
//! and its route functions ([`super::route_fn`]); and its descriptor,
//! `descriptorGetNote`, built by `Proto.Method.descriptor` with its HTTP
//! bindings written out as data, which the call does not refer to. Both
//! builders are stacked, one argument per line, however short.

use super::field::{ValueShape, Zeroed, value_shape};
use super::route_fn::{Messages, PROTO_ROUTE, Queries, REQUEST};
use super::scalar::Holding;
use super::{Emitter, PROTO_HTTP, PROTO_METHOD, RPC, docs};
use crate::elm::ast::{Decl, Expr, Type};
use crate::elm::build::{
    apply, inline_list, list, pipeline, pvar, qualified, record, stacked_apply, string, ty_fn, var,
};
use crate::ir::{Idempotency, Method, TypeRef};
use crate::options::Codec;
use crate::route::{Body, FieldRef, PathSegment, QueryParam, Route, Segment};

impl Emitter {
    /// `descriptorGetNote : Proto.Method.Descriptor`, built by
    /// `Proto.Method.descriptor` from the method's service, name,
    /// idempotency, type names and bindings: what the proto says about the
    /// method, for a program that reads it. The call does not refer to it,
    /// so a program that does not name it keeps none of it, nor the
    /// binding data and field descriptors it holds.
    ///
    /// Every name in it is qualified, so it cannot clash with the package
    /// module's names or the runtime's, whatever the method is called.
    pub(super) fn method_descriptor(&mut self, service: &str, method: &Method) -> Decl {
        let idempotency = self.idempotency(method);
        let bindings: Vec<Expr> = method
            .routes
            .iter()
            .map(|route| self.binding(route))
            .collect();
        let body = stacked_apply(
            self.reference((PROTO_METHOD, "descriptor")),
            [
                string(service),
                string(method.proto_name.clone()),
                idempotency,
                string(proto_full_name(&method.input)),
                string(proto_full_name(&method.output)),
                list(bindings),
            ],
        );
        Decl::Value {
            doc: Some(docs::descriptor(&method.doc, None)),
            name: method.descriptor_name(),
            annotation: self.library_type(PROTO_METHOD, "Descriptor", []),
            params: Vec::new(),
            body,
        }
    }

    /// `Proto.Method.IdempotencyNoSideEffects`: a method's declared
    /// idempotency.
    fn idempotency(&mut self, method: &Method) -> Expr {
        self.reference((
            PROTO_METHOD,
            match method.idempotency {
                Idempotency::Unknown => "IdempotencyUnknown",
                Idempotency::NoSideEffects => "IdempotencyNoSideEffects",
                Idempotency::Idempotent => "IdempotencyIdempotent",
            },
        ))
    }

    /// `getNote : GetNoteRequest -> Rpc.Call GetNoteRequest Note`:
    /// `Rpc.call` of the method's `Proto.Method.Method`, built by
    /// `Proto.Method.method` from the encoder of its request, the decoder
    /// of its response, its service's full name and its name, then
    /// `withIdempotency` when the proto declares one, `withRoutes` with its
    /// route functions ([`Self::method_routes`]) or, when one of its
    /// bindings cannot be typed, `withBindings` with its descriptor's
    /// bindings, and `withBinary` under `codec=both`. Under `codec=binary`
    /// it is built by `Proto.Method.methodBinary` and has no routes: its
    /// calls cannot be transcoded, which takes JSON.
    ///
    /// The value binds no locals and every library name in it is
    /// qualified, so it cannot clash with the package module's names or
    /// the runtime's, whatever the method is called; the route functions
    /// and descriptor it refers to are the module's own. Its documentation
    /// names its Connect path, under `service`, the full name of its
    /// service.
    pub(super) fn method(&mut self, service: &str, method: &Method, routes: &Routes) -> Decl {
        let request = self.method_type(&method.input);
        let response = self.method_type(&method.output);
        let names = [string(service), string(method.proto_name.clone())];
        let (built, binary) = match self.codec {
            Codec::Json | Codec::Both => {
                let encode_request = self.request_encoder(&method.input);
                let response_decoder = self.response_decoder(&method.output);
                let [service, name] = names;
                let built = stacked_apply(
                    self.reference((PROTO_METHOD, "method")),
                    [encode_request, response_decoder, service, name],
                );
                (built, self.codec == Codec::Both)
            }
            Codec::Binary => {
                let encode = self.request_encoder_bytes(&method.input);
                let decode = self.response_decoder_bytes(&method.output);
                let [service, name] = names;
                let built = stacked_apply(
                    self.reference((PROTO_METHOD, "methodBinary")),
                    [encode, decode, service, name],
                );
                (built, false)
            }
        };
        let mut steps = Vec::new();
        if method.idempotency != Idempotency::Unknown {
            let level = self.idempotency(method);
            steps.push(apply(
                self.reference((PROTO_METHOD, "withIdempotency")),
                [level],
            ));
        }
        match routes {
            Routes::None => {}
            Routes::Functions(count) => {
                let functions: Vec<Expr> = (0..*count)
                    .map(|index| var(route_name(method, index)))
                    .collect();
                steps.push(apply(
                    self.reference((PROTO_METHOD, "withRoutes")),
                    [inline_list(functions)],
                ));
            }
            Routes::Bindings => {
                let bindings = apply(
                    self.reference((PROTO_METHOD, "bindings")),
                    [var(method.descriptor_name())],
                );
                steps.push(apply(
                    self.reference((PROTO_METHOD, "withBindings")),
                    [bindings],
                ));
            }
        }
        if binary {
            let encode = self.request_encoder_bytes(&method.input);
            let decode = self.response_decoder_bytes(&method.output);
            let with = self.reference((PROTO_METHOD, "withBinary"));
            steps.push(stacked_apply(with, [encode, decode]));
        }
        let body = apply(self.reference((RPC, "call")), [pipeline(built, steps)]);
        let call = self.library_type(RPC, "Call", [request.clone(), response]);
        Decl::Value {
            doc: Some(docs::method(service, method)),
            name: method.elm_name.clone(),
            annotation: ty_fn([request], call),
            params: Vec::new(),
            body,
        }
    }

    /// A method's route functions, `routeGetNote0 : GetNoteRequest ->
    /// Proto.Route.Route`, one per binding of its HTTP rule, and how its
    /// call takes its routes: from them, from its bindings as data when one
    /// of them cannot be typed ([`super::route_fn`]), or not at all, for a
    /// method without a rule and under `codec=binary`.
    ///
    /// Each binding is typed on a copy of the emitter first, so that a
    /// method that falls back imports nothing its typed routes would have.
    pub(super) fn method_routes(
        &mut self,
        messages: &Messages,
        queries: &Queries,
        method: &Method,
    ) -> (Vec<Decl>, Routes) {
        if method.routes.is_empty() || self.codec == Codec::Binary {
            return (Vec::new(), Routes::None);
        }
        let mut scratch = self.clone();
        if !method.routes.iter().all(|route| {
            scratch
                .typed_route(messages, queries, &method.input, route)
                .is_some()
        }) {
            return (Vec::new(), Routes::Bindings);
        }
        let mut decls = Vec::new();
        for (index, route) in method.routes.iter().enumerate() {
            let body = self
                .typed_route(messages, queries, &method.input, route)
                .expect("typed on the copy");
            let request = self.method_type(&method.input);
            let built = self.library_type(PROTO_ROUTE, "Route", []);
            decls.push(Decl::Value {
                doc: Some(docs::route(method, index)),
                name: route_name(method, index),
                annotation: ty_fn([request], built),
                params: vec![pvar(REQUEST)],
                body,
            });
        }
        (decls, Routes::Functions(method.routes.len()))
    }

    /// The JSON encoder of a method's request type: the generated
    /// `encodeFoo`, or for a well-known type the runtime's encoder a field
    /// of that type uses, in the Elm form the `int64` option gives the
    /// 64-bit wrappers.
    ///
    /// A method carries codecs, not the types' typed values: Elm's
    /// dead-code elimination keeps a top-level value whole, so a typed value
    /// would bring the type's default and descriptor tree into every
    /// program that calls the method.
    pub(super) fn request_encoder(&mut self, ty: &TypeRef) -> Expr {
        match method_shape(ty, self.holding) {
            // Qualified: a method may be called `identity`, and its own
            // name would then refer to itself.
            ValueShape::Zeroed(Zeroed::Json) => qualified("Basics", "identity"),
            shape => self.value_encoder(shape),
        }
    }

    /// The JSON decoder of a method's response type, as
    /// [`Self::request_encoder`] finds the encoder.
    fn response_decoder(&mut self, ty: &TypeRef) -> Expr {
        let shape = method_shape(ty, self.holding);
        self.value_decoder(shape)
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
            Body::Field(top) => apply(
                self.reference((PROTO_HTTP, "bodyField")),
                [self.field_ref(&top.descriptor)],
            ),
        };
        let response_body = maybe(
            route
                .response_body
                .as_ref()
                .map(|top| self.field_ref(&top.descriptor)),
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
    pub(super) fn method_type(&mut self, ty: &TypeRef) -> Type {
        let shape = method_shape(ty, self.holding);
        self.value_type(shape)
    }

    fn path_segment(&mut self, segment: &PathSegment) -> Expr {
        match segment {
            PathSegment::Literal(text) => apply(
                self.reference((PROTO_HTTP, "literal")),
                [string(text.clone())],
            ),
            PathSegment::Variable {
                template, fields, ..
            } => {
                let fields = self.field_refs(fields);
                let template: Vec<Expr> = template
                    .iter()
                    .map(|segment| self.template_segment(segment))
                    .collect();
                apply(
                    self.reference((PROTO_HTTP, "variable")),
                    [record([
                        ("fieldPath", fields),
                        ("template", inline_list(template)),
                    ])],
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
        let fields = self.field_refs(&param.fields);
        apply(self.reference((PROTO_HTTP, "param")), [fields])
    }

    /// `[ Notes.V1.ListNotesRequest.filter, … ]`: the descriptors of a
    /// path of fields from the request, each from its message's
    /// descriptor module, which the module then imports.
    fn field_refs(&mut self, fields: &[FieldRef]) -> Expr {
        let refs: Vec<Expr> = fields.iter().map(|field| self.field_ref(field)).collect();
        inline_list(refs)
    }

    /// `Notes.V1.Note.title`: a field's descriptor, from its message's
    /// descriptor module, which the module then imports.
    fn field_ref(&mut self, field: &FieldRef) -> Expr {
        self.generated_value(&field.module, field.name.clone())
    }
}

/// How a method's call takes its routes for transcoding.
pub(super) enum Routes {
    /// None: a method without an HTTP rule, or under `codec=binary`.
    None,
    /// Its route functions, as many as its bindings.
    Functions(usize),
    /// Its bindings as data, read by the runtime's interpreter.
    Bindings,
}

/// `routeGetNote0`: the route function of a method's binding, by its
/// number in the method's rule (`naming::route_name`).
fn route_name(method: &Method, index: usize) -> String {
    crate::naming::route_name(&method.elm_name, index)
}

/// `Just value`, or `Nothing`.
fn maybe(value: Option<Expr>) -> Expr {
    match value {
        Some(value) => apply(var("Just"), [value]),
        None => var("Nothing"),
    }
}

/// The shape of a method's request or response type.
fn method_shape(ty: &TypeRef, holding: Holding) -> ValueShape<'_> {
    // A method's types are messages (`ir::Method::input`).
    if let TypeRef::Scalar(_) | TypeRef::Enum { .. } = ty {
        unreachable!("a method type that is not a message")
    }
    value_shape(ty, holding)
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
