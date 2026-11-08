//! A message's four declarations: its record type alias, its default
//! value, its encoder and its decoder.

use super::{
    Emitter, JSON_DECODE, JSON_ENCODE, MessageShape, PROTO_ANY, PROTO_JSON, PROTO_REGISTRY,
    RecordField, call, docs,
};
use crate::elm::ast::{BinOp, Decl, Expr, Pattern, Type};
use crate::elm::build::{
    access, apply, binop, list, pipeline, pvar, qualified, record, string, tuple2, ty, ty_fn, var,
};
use crate::ir::ModuleName;
use crate::naming::{ENCODER_ARGUMENT, REGISTRY_ARGUMENT, with_registry};

impl Emitter {
    /// `type alias Foo = { ... }`, one record field per proto field and per
    /// oneof, in declaration order.
    pub(super) fn message_alias(&mut self, package: &ModuleName, shape: &MessageShape) -> Decl {
        let record = shape.record();
        let descriptors = docs::page(&shape.message.descriptor_module(package));
        let items = record
            .iter()
            .map(|field| match field {
                RecordField::Field(field, _) => docs::field_item(
                    &field.elm_name,
                    &format!("{descriptors}#{}", field.value_name()),
                    &field.doc,
                    &field.annotations.behavior,
                ),
                RecordField::Oneof(oneof) => docs::oneof_item(oneof.oneof),
            })
            .collect();
        let doc = docs::message(shape.message, &descriptors, items);
        let body = record
            .iter()
            .map(|field| match field {
                RecordField::Field(field, value) => {
                    (field.elm_name.clone(), self.field_type(*value))
                }
                RecordField::Oneof(oneof) => (
                    oneof.oneof.elm_field_name.clone(),
                    ty(oneof.oneof.elm_type_name.clone(), []),
                ),
            })
            .collect();
        Decl::TypeAlias {
            doc: Some(doc),
            name: shape.message.elm_name.clone(),
            type_params: Vec::new(),
            body: Type::Record(body),
        }
    }

    /// `defaultFoo : Foo`: every field at its proto3 default, the value it
    /// reads as when absent (design §3.2), and every oneof unset. A field
    /// that closes a cycle is a `Maybe`, `List` or `Dict` of the wrapper,
    /// whose default is empty, so a recursive message's default needs no
    /// laziness and its wrapper no default of its own.
    pub(super) fn message_default(&mut self, shape: &MessageShape) -> Decl {
        let fields: Vec<(String, Expr)> = shape
            .record()
            .into_iter()
            .map(|field| match field {
                RecordField::Field(field, value) => {
                    (field.elm_name.clone(), self.field_default(value))
                }
                RecordField::Oneof(oneof) => (
                    oneof.oneof.elm_field_name.clone(),
                    var(oneof.oneof.unset_ctor.clone()),
                ),
            })
            .collect();
        Decl::Value {
            doc: Some(format!(
                "{} with every field at its default and every oneof unset.",
                docs::a_local_capital(&shape.message.elm_name)
            )),
            name: shape.message.default_name(),
            annotation: ty(shape.message.elm_name.clone(), []),
            params: Vec::new(),
            body: record(fields),
        }
    }

    /// `encodeFoo : Foo -> Json.Encode.Value`: `Proto.Json.objectOfFields` of every
    /// field under its JSON name, each as a `Maybe Json.Encode.Value` that
    /// is `Nothing` when the field is left out
    /// ([`encode_field`](Self::encode_field)), followed by the members
    /// each oneof's encoder gives (none when it is unset). Key order means
    /// nothing in JSON, so the fields come first, whatever the declaration
    /// order.
    pub(super) fn message_encoder(&mut self, shape: &MessageShape) -> Decl {
        if self.message_reaches(shape) {
            return self.message_encoder_with(shape);
        }
        let pairs: Vec<Expr> = shape
            .fields
            .iter()
            .map(|&(field, value)| {
                let field_value = access(var(ENCODER_ARGUMENT), field.elm_name.clone());
                tuple2(
                    string(field.json_name.clone()),
                    self.encode_field(value, field_value),
                )
            })
            .collect();
        let oneofs: Vec<Expr> = shape
            .oneofs
            .iter()
            .map(|oneof| {
                let field_value = access(var(ENCODER_ARGUMENT), oneof.oneof.elm_field_name.clone());
                apply(var(oneof.oneof.encoder_name()), [field_value])
            })
            .collect();
        // A message without fields or oneofs has nothing to read from its
        // argument.
        let nothing = pairs.is_empty() && oneofs.is_empty();
        let param = if nothing {
            Pattern::Wildcard
        } else {
            pvar(ENCODER_ARGUMENT)
        };
        // The fields' list, then each oneof's, joined with `++`.
        let parts = (!pairs.is_empty() || oneofs.is_empty())
            .then(|| list(pairs))
            .into_iter()
            .chain(oneofs);
        let members = parts
            .rev()
            .reduce(|right, left| binop(BinOp::Append, left, right))
            .expect("at least the fields' list");
        // `Json.Encode.object []` when there is nothing to leave out, so a
        // module of empty messages needs no `Proto.Json`.
        let object = if nothing {
            self.reference((JSON_ENCODE, "object"))
        } else {
            self.reference((PROTO_JSON, "objectOfFields"))
        };
        let value_type = self.library_type(JSON_ENCODE, "Value", []);
        Decl::Value {
            doc: Some(format!(
                "Encodes {} as proto3 JSON.",
                docs::a_local(&shape.message.elm_name)
            )),
            name: shape.message.encoder_name(),
            annotation: Type::Function(
                Box::new(ty(shape.message.elm_name.clone(), [])),
                Box::new(value_type),
            ),
            params: vec![param],
            body: apply(object, [members]),
        }
    }

    /// Whether a message reaches an `Any`: one of its
    /// fields' or oneofs' values does.
    pub(super) fn message_reaches(&self, shape: &MessageShape) -> bool {
        shape
            .fields
            .iter()
            .any(|&(_, value)| self.field_reaches(value))
            || shape.oneofs.iter().any(|oneof| self.oneof_reaches(oneof))
    }

    /// `encodeFooWith : Proto.Registry.Registry -> Foo -> Result
    /// Proto.Any.Problem Json.Encode.Value`, for a message that reaches an
    /// `Any`: `Proto.Json.tryObjectOfFields` of every
    /// field ([`Self::try_encode_field`]) and of each oneof's members, the
    /// first `Err` failing the whole. It has no `encodeFoo`: writing an
    /// `Any` can fail, and a total encoder would need a fallback form.
    fn message_encoder_with(&mut self, shape: &MessageShape) -> Decl {
        let pairs: Vec<Expr> = shape
            .fields
            .iter()
            .map(|&(field, value)| {
                let field_value = access(var(ENCODER_ARGUMENT), field.elm_name.clone());
                tuple2(
                    string(field.json_name.clone()),
                    self.try_encode_field(value, field_value),
                )
            })
            .collect();
        let oneofs: Vec<Expr> = shape
            .oneofs
            .iter()
            .map(|oneof| {
                let field_value = access(var(ENCODER_ARGUMENT), oneof.oneof.elm_field_name.clone());
                if self.oneof_reaches(oneof) {
                    apply(
                        var(with_registry(oneof.oneof.encoder_name())),
                        [var(REGISTRY_ARGUMENT), field_value],
                    )
                } else {
                    // A oneof that reaches no `Any` gives its members' JSON;
                    // each is lifted into `Ok`.
                    let ok = var(self.core("Ok"));
                    apply(
                        qualified("List", "map"),
                        [
                            apply(qualified("Tuple", "mapSecond"), [ok]),
                            apply(var(oneof.oneof.encoder_name()), [field_value]),
                        ],
                    )
                }
            })
            .collect();
        let parts = (!pairs.is_empty() || oneofs.is_empty())
            .then(|| list(pairs))
            .into_iter()
            .chain(oneofs);
        let members = parts
            .rev()
            .reduce(|right, left| binop(BinOp::Append, left, right))
            .expect("at least the fields' list");
        let object = self.reference((PROTO_JSON, "tryObjectOfFields"));
        let annotation = self.encoder_with_type(ty(shape.message.elm_name.clone(), []));
        Decl::Value {
            doc: Some(format!(
                "Encodes {} as proto3 JSON, writing each `Any` it holds with the registry: \
                 an `Err` names the first type the registry cannot write.",
                docs::a_local(&shape.message.elm_name)
            )),
            name: with_registry(shape.message.encoder_name()),
            annotation,
            params: vec![pvar(REGISTRY_ARGUMENT), pvar(ENCODER_ARGUMENT)],
            body: apply(object, [members]),
        }
    }

    /// `Proto.Registry.Registry -> of -> Result Proto.Any.Problem
    /// Json.Encode.Value`: the type of an encoder taking the registry.
    pub(super) fn encoder_with_type(&mut self, of: Type) -> Type {
        let registry = self.library_type(PROTO_REGISTRY, "Registry", []);
        let problem = self.library_type(PROTO_ANY, "Problem", []);
        let value = self.library_type(JSON_ENCODE, "Value", []);
        let result = ty(self.core("Result"), [problem, value]);
        ty_fn([registry, of], result)
    }

    /// `Proto.Registry.Registry -> Json.Decode.Decoder of`: the type of a
    /// decoder taking the registry.
    pub(super) fn decoder_with_type(&mut self, of: Type) -> Type {
        let registry = self.library_type(PROTO_REGISTRY, "Registry", []);
        let decoder = self.library_type(JSON_DECODE, "Decoder", [of]);
        ty_fn([registry], decoder)
    }

    /// A decoding pipeline step reading the field `json_name`, also
    /// accepted under `proto_name` as proto3 JSON requires:
    /// `Proto.Json.<one> json_name ...` when the two are equal, else
    /// `Proto.Json.<either> json_name proto_name ...`, followed by `args`,
    /// where `(one, either)` is `helpers`.
    fn field_step(
        &mut self,
        helpers: (&'static str, &'static str),
        json_name: &str,
        proto_name: &str,
        args: impl IntoIterator<Item = Expr>,
    ) -> Expr {
        let (one, either) = helpers;
        let step = if json_name == proto_name {
            let field = self.reference((PROTO_JSON, one));
            apply(field, [string(json_name)])
        } else {
            let field = self.reference((PROTO_JSON, either));
            apply(field, [string(json_name), string(proto_name)])
        };
        call(step, args)
    }

    /// `decodeFoo : Json.Decode.Decoder Foo`: `Json.Decode.succeed Foo`
    /// with one step per record field, in record order: an
    /// [`Emitter::field_step`] per proto field (`Proto.Json.field`, or
    /// `Proto.Json.valueField` for a singular `google.protobuf.Value`), a
    /// `Proto.Json.oneof` per oneof; `Proto.Json.emptyMessage` for a message
    /// without fields.
    ///
    /// A message that reaches an `Any` gets `decodeFooWith :
    /// Proto.Registry.Registry -> Json.Decode.Decoder Foo`, whose steps
    /// read each `Any` with the registry, and no `decodeFoo`: one bound to
    /// the package's `registry` would read only that package's `Any`s.
    pub(super) fn message_decoder(&mut self, shape: &MessageShape) -> Vec<Decl> {
        let name = &shape.message.elm_name;
        let body = if shape.fields.is_empty() && shape.oneofs.is_empty() {
            // An empty message decodes to the empty record, from a JSON
            // object only, as a message with fields does.
            self.reference((PROTO_JSON, "emptyMessage"))
        } else {
            let succeed = self.reference((JSON_DECODE, "succeed"));
            let steps: Vec<Expr> = shape
                .record()
                .into_iter()
                .map(|field| match field {
                    RecordField::Field(field, value) => match self.field_decoder(value) {
                        Some((decoder, zero)) => self.field_step(
                            ("field", "fieldEither"),
                            &field.json_name,
                            &field.proto_name,
                            [zero, decoder],
                        ),
                        None => self.field_step(
                            ("valueField", "valueFieldEither"),
                            &field.json_name,
                            &field.proto_name,
                            [],
                        ),
                    },
                    RecordField::Oneof(oneof) => {
                        let step = self.reference((PROTO_JSON, "oneof"));
                        let decoder = if self.oneof_reaches(oneof) {
                            apply(
                                var(with_registry(oneof.oneof.decoder_name())),
                                [var(REGISTRY_ARGUMENT)],
                            )
                        } else {
                            var(oneof.oneof.decoder_name())
                        };
                        apply(step, [decoder])
                    }
                })
                .collect();
            pipeline(apply(succeed, [var(name.clone())]), steps)
        };
        let doc = format!(
            "Decodes {} from proto3 JSON.",
            docs::a_local(&shape.message.elm_name)
        );
        if !self.message_reaches(shape) {
            let annotation = self.library_type(JSON_DECODE, "Decoder", [ty(name.clone(), [])]);
            return vec![Decl::Value {
                doc: Some(doc),
                name: shape.message.decoder_name(),
                annotation,
                params: Vec::new(),
                body,
            }];
        }
        let with = with_registry(shape.message.decoder_name());
        let annotation = self.decoder_with_type(ty(name.clone(), []));
        vec![Decl::Value {
            doc: Some(format!(
                "Decodes {} from proto3 JSON, reading each `Any` it holds with the \
                 registry: one of a type the registry lacks fails.",
                docs::a_local(&shape.message.elm_name)
            )),
            name: with,
            annotation,
            params: vec![pvar(REGISTRY_ARGUMENT)],
            body,
        }]
    }
}
