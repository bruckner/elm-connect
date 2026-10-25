//! A method's declarations in its service's module (design §4): its
//! descriptor, `descriptorGetNote`, built by `Proto.Method.descriptor`
//! with its HTTP bindings written out as data, and its call, a function
//! from the request to an `Rpc.Call`, built point-free with `Rpc.call`
//! from the codecs of its request and response and that descriptor. Both
//! applications are stacked, one argument per line, however short.

use super::field::{ValueShape, Zeroed, value_shape};
use super::scalar::Holding;
use super::{Emitter, PROTO_HTTP, PROTO_METHOD, RPC, RPC_STREAM, docs};
use crate::elm::ast::{Decl, Expr, Type};
use crate::elm::build::{
    apply, inline_list, list, qualified, record, stacked_apply, string, ty_fn, var,
};
use crate::ir::{Idempotency, Method, TypeRef};
use crate::route::{Body, FieldRef, PathSegment, QueryParam, Route, Segment};

impl Emitter {
    /// `descriptorGetNote : Proto.Method.Descriptor`, built by
    /// `Proto.Method.descriptor` from the method's service, name,
    /// idempotency, type names and bindings. A method without an HTTP rule
    /// has no bindings; the runtime calls it over the implicit route.
    ///
    /// Every name in it is qualified, so it cannot clash with the package
    /// module's names or the runtime's, whatever the method is called.
    pub(super) fn method_descriptor(&mut self, service: &str, method: &Method) -> Decl {
        let idempotency = self.reference((
            PROTO_METHOD,
            match method.idempotency {
                Idempotency::Unknown => "IdempotencyUnknown",
                Idempotency::NoSideEffects => "IdempotencyNoSideEffects",
                Idempotency::Idempotent => "IdempotencyIdempotent",
            },
        ));
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

    /// `getNote : GetNoteRequest -> Rpc.Call GetNoteRequest Note`:
    /// `Rpc.call` of the method's `Proto.Method.Method`, built by
    /// `Proto.Method.method` from the encoder of its request, the decoder
    /// of its response, and its descriptor value
    /// ([`Self::method_descriptor`]).
    ///
    /// The value binds no locals and every library name in it is
    /// qualified, so it cannot clash with the package module's names or
    /// the runtime's, whatever the method is called; the descriptor it
    /// refers to is the module's own. Its documentation names its Connect
    /// path, under `service`, the full name of its service.
    pub(super) fn method(&mut self, service: &str, method: &Method) -> Decl {
        let request = self.method_type(&method.input);
        let response = self.method_type(&method.output);
        let encode_request = self.request_encoder(&method.input);
        let response_decoder = self.response_decoder(&method.output);
        // A server-streaming method is a `Proto.Method.ServerStreaming`,
        // which only `Rpc.Stream.call` takes, so it is never sent unary.
        let (constructor, module, caller, call_type) = if method.server_streaming {
            ("serverStreaming", RPC_STREAM, "call", "StreamCall")
        } else {
            ("method", RPC, "call", "Call")
        };
        let built = stacked_apply(
            self.reference((PROTO_METHOD, constructor)),
            [
                encode_request,
                response_decoder,
                var(method.descriptor_name()),
            ],
        );
        let body = apply(self.reference((module, caller)), [built]);
        let call = self.library_type(module, call_type, [request.clone(), response]);
        Decl::Value {
            doc: Some(docs::method(service, method)),
            name: method.elm_name.clone(),
            annotation: ty_fn([request], call),
            params: Vec::new(),
            body,
        }
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
    fn request_encoder(&mut self, ty: &TypeRef) -> Expr {
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
    fn method_type(&mut self, ty: &TypeRef) -> Type {
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
