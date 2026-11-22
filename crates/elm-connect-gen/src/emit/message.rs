//! A message's four declarations: its record type alias, its default
//! value, its encoder and its decoder.

use super::Deep;
use super::field::plain_name;
use super::recursion::{DEPTH, level_name};
use super::{
    Emitter, JSON_DECODE, JSON_ENCODE, MessageShape, PROTO_JSON, PROTO_REGISTRY, PROTO_UNKNOWN,
    RecordField, call, docs,
};
use crate::elm::ast::{BinOp, Decl, Expr, Pattern, Type};
use crate::elm::build::{
    access, apply, binop, lambda, list, pipeline, pvar, record, string, tuple2, ty, ty_fn, var,
};
use crate::ir::ModuleName;
use crate::naming::{ENCODER_ARGUMENT, REGISTRY_ARGUMENT, UNKNOWN_FIELDS, with_registry};
use crate::options::UnknownFields;

impl Emitter {
    /// `type alias Foo = { ... }`, one record field per proto field and per
    /// oneof, in declaration order.
    pub(super) fn message_alias(&mut self, package: &ModuleName, shape: &MessageShape) -> Decl {
        let record = shape.record();
        let descriptors = docs::page(&shape.message.descriptor_module(package));
        let mut items: Vec<String> = record
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
        if self.keeps_unknown() {
            items.push(docs::unknown_fields_item());
        }
        let doc = docs::message(shape.message, &descriptors, items);
        let mut body: Vec<(String, Type)> = record
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
        if self.keeps_unknown() {
            body.push((
                UNKNOWN_FIELDS.to_owned(),
                self.library_type(PROTO_UNKNOWN, "Fields", []),
            ));
        }
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
        let mut fields: Vec<(String, Expr)> = shape
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
        if self.keeps_unknown() {
            fields.push((
                UNKNOWN_FIELDS.to_owned(),
                self.reference((PROTO_UNKNOWN, "empty")),
            ));
        }
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
    pub(super) fn message_encoder(&mut self, shape: &MessageShape) -> Vec<Decl> {
        if self.message_write_reaches(shape) {
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
        // `Json.Encode.object []` when there is nothing to leave out.
        let object = if nothing {
            self.reference((JSON_ENCODE, "object"))
        } else {
            self.reference((PROTO_JSON, "objectOfFields"))
        };
        let value_type = self.library_type(JSON_ENCODE, "Value", []);
        let encoder_type = self.library_type(PROTO_JSON, "Encoder", []);
        let plain = plain_name(&shape.message.encoder_name());
        let ready = self.reference((PROTO_JSON, "ready"));
        vec![
            Decl::Value {
                doc: Some(format!(
                    "Encodes {} as proto3 JSON.",
                    docs::a_local(&shape.message.elm_name)
                )),
                name: shape.message.encoder_name(),
                annotation: Type::Function(
                    Box::new(ty(shape.message.elm_name.clone(), [])),
                    Box::new(encoder_type),
                ),
                params: vec![pvar(ENCODER_ARGUMENT)],
                body: apply(ready, [apply(var(plain.clone()), [var(ENCODER_ARGUMENT)])]),
            },
            Decl::Value {
                doc: Some(format!(
                    "Writes {} as proto3 JSON, which nothing it holds can refuse.",
                    docs::a_local(&shape.message.elm_name)
                )),
                name: plain,
                annotation: Type::Function(
                    Box::new(ty(shape.message.elm_name.clone(), [])),
                    Box::new(value_type),
                ),
                params: vec![param],
                body: apply(object, [members]),
            },
        ]
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

    /// Whether a message's JSON write can be refused.
    pub(super) fn message_write_reaches(&self, shape: &MessageShape) -> bool {
        self.write_reach.message(&shape.message.proto_full_name)
    }

    /// `encodeFoo : Foo -> Proto.Json.Encoder` for a message whose write can
    /// be refused: `Proto.Json.writeObject` of the fields that cannot be
    /// refused, as plain code, and of those that can, each a
    /// `Proto.Json.Encoder` ([`Self::write_field`]), then each oneof's
    /// members in the list its encoder gives.
    fn message_encoder_with(&mut self, shape: &MessageShape) -> Vec<Decl> {
        let at = shape.message.recursive && self.static_depth();
        self.write_depth = at;
        let mut plain: Vec<Expr> = Vec::new();
        let mut checked: Vec<Expr> = Vec::new();
        for &(field, value) in &shape.fields {
            let field_value = access(var(ENCODER_ARGUMENT), field.elm_name.clone());
            self.deeper_registry = shape.message.recursive && field.recursive;
            if self.write_all_fields || self.field_write_reaches(value) {
                let encoded = self.write_field(value, field_value);
                checked.push(tuple2(string(field.json_name.clone()), encoded));
            } else {
                let encoded = self.encode_field(value, field_value);
                plain.push(tuple2(string(field.json_name.clone()), encoded));
            }
            self.deeper_registry = false;
        }
        let mut plain_oneofs: Vec<Expr> = Vec::new();
        let mut checked_oneofs: Vec<Expr> = Vec::new();
        for oneof in &shape.oneofs {
            let field_value = access(var(ENCODER_ARGUMENT), oneof.oneof.elm_field_name.clone());
            let members = if at && self.oneof_write_reaches(oneof) {
                apply(
                    var(super::field::at_name(&oneof.oneof.encoder_name())),
                    [var(super::recursion::DEPTH), field_value],
                )
            } else {
                apply(var(oneof.oneof.encoder_name()), [field_value])
            };
            if self.oneof_write_reaches(oneof) {
                checked_oneofs.push(members);
            } else {
                plain_oneofs.push(members);
            }
        }
        let join = |pairs: Vec<Expr>, oneofs: Vec<Expr>| {
            (!pairs.is_empty() || oneofs.is_empty())
                .then(|| list(pairs))
                .into_iter()
                .chain(oneofs)
                .rev()
                .reduce(|right, left| binop(BinOp::Append, left, right))
                .expect("at least the fields' list")
        };
        let plain = join(plain, plain_oneofs);
        let checked = join(checked, checked_oneofs);
        let object = self.reference((PROTO_JSON, "writeObject"));
        let encoder_type = self.library_type(PROTO_JSON, "Encoder", []);
        self.write_depth = false;
        let doc = format!(
            "Encodes {} as proto3 JSON, refusing a value it holds that has no proto3 \
             JSON form, and writing each `Any` with the registry it is run with.",
            docs::a_local(&shape.message.elm_name)
        );
        let message_type = ty(shape.message.elm_name.clone(), []);
        if !at {
            return vec![Decl::Value {
                doc: Some(doc),
                name: shape.message.encoder_name(),
                annotation: Type::Function(Box::new(message_type), Box::new(encoder_type)),
                params: vec![pvar(ENCODER_ARGUMENT)],
                body: apply(object, [plain, checked]),
            }];
        }
        let at_name = super::field::at_name(&shape.message.encoder_name());
        let limit = self.reference((PROTO_JSON, "writeLimit"));
        let too_deep = self.reference((PROTO_JSON, "writeTooDeep"));
        let from = self.reference((PROTO_JSON, "writeFrom"));
        let int_type = ty(self.core("Int"), []);
        vec![
            Decl::Value {
                doc: Some(doc),
                name: shape.message.encoder_name(),
                annotation: Type::Function(
                    Box::new(message_type.clone()),
                    Box::new(encoder_type.clone()),
                ),
                params: vec![pvar(ENCODER_ARGUMENT)],
                body: apply(from, [var(at_name.clone()), var(ENCODER_ARGUMENT)]),
            },
            Decl::Value {
                doc: Some(format!(
                    "Encodes {} at a level of its cycle, refused past the limit.",
                    docs::a_local(&shape.message.elm_name)
                )),
                name: at_name,
                annotation: ty_fn([int_type, message_type], encoder_type),
                params: vec![pvar(super::recursion::DEPTH), pvar(ENCODER_ARGUMENT)],
                body: crate::elm::build::if_then_else(
                    binop(BinOp::Gt, var(super::recursion::DEPTH), limit),
                    apply(too_deep, [string(shape.message.proto_full_name.clone())]),
                    apply(object, [plain, checked]),
                ),
            },
        ]
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

    /// `decodeFoo : Json.Decode.Decoder Foo`: `Proto.Json.message` of
    /// `Json.Decode.succeed Foo` with one step per record field, in record
    /// order: an [`Emitter::field_step`] per proto field
    /// (`Proto.Json.messageField`, or `Proto.Json.messageValueField` for a
    /// singular `google.protobuf.Value`), a `Proto.Json.oneof` per oneof;
    /// `Proto.Json.emptyMessage` for a message without fields.
    /// `Proto.Json.message` checks once that the JSON is an object, and the
    /// field steps trust it rather than each checking again; a message of
    /// oneofs alone is not wrapped, since a oneof step checks for itself.
    ///
    /// A message that reaches an `Any` gets `decodeFooWith :
    /// Proto.Registry.Registry -> Json.Decode.Decoder Foo`, whose steps
    /// read each `Any` with the registry, and no `decodeFoo`: one bound to
    /// the package's `registry` would read only that package's `Any`s.
    pub(super) fn message_decoder(&mut self, shape: &MessageShape) -> Vec<Decl> {
        let name = &shape.message.elm_name;
        let deep = shape.message.recursive.then(|| {
            if self.message_reaches(shape) {
                Deep::Built
            } else {
                Deep::Table
            }
        });
        self.deep = deep;
        let body = if shape.fields.is_empty() && shape.oneofs.is_empty() {
            // An empty message decodes to the empty record, from a JSON
            // object only, as a message with fields does.
            let empty = self.reference((PROTO_JSON, "emptyMessage"));
            if self.keeps_unknown() {
                // The record is not empty: its one field holds no unknown
                // fields, as JSON carries none.
                let map = self.reference((JSON_DECODE, "map"));
                let default = lambda([Pattern::Wildcard], var(shape.message.default_name()));
                apply(map, [default, empty])
            } else {
                empty
            }
        } else {
            let succeed = self.reference((JSON_DECODE, "succeed"));
            let mut steps: Vec<Expr> = shape
                .record()
                .into_iter()
                .map(|field| match field {
                    RecordField::Field(field, value) => match self.deep_field_decoder(field, value)
                    {
                        Some((decoder, zero)) => self.field_step(
                            ("messageField", "messageFieldEither"),
                            &field.json_name,
                            &field.proto_name,
                            [zero, decoder],
                        ),
                        None if self.deep.is_some() => self.field_step(
                            ("messageValueFieldAt", "messageValueFieldEitherAt"),
                            &field.json_name,
                            &field.proto_name,
                            [var(DEPTH)],
                        ),
                        None => self.field_step(
                            ("messageValueField", "messageValueFieldEither"),
                            &field.json_name,
                            &field.proto_name,
                            [],
                        ),
                    },
                    RecordField::Oneof(oneof) => {
                        let step = self.reference((PROTO_JSON, "oneof"));
                        let leveled = deep.is_some()
                            && oneof.variants.iter().any(|(variant, _)| variant.cyclic);
                        let decoder = if leveled {
                            let level = level_name(&oneof.oneof.elm_type_name);
                            if self.oneof_reaches(oneof) {
                                apply(
                                    var(with_registry(level)),
                                    [var(REGISTRY_ARGUMENT), var(DEPTH)],
                                )
                            } else {
                                apply(var(level), [var(DEPTH)])
                            }
                        } else if self.oneof_reaches(oneof) {
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
            if self.keeps_unknown() {
                // JSON carries no unknown fields: the record's last field
                // is always empty.
                let map = self.reference((JSON_DECODE, "map"));
                let empty = self.reference((PROTO_UNKNOWN, "empty"));
                steps.push(apply(
                    map,
                    [lambda(
                        [pvar(ENCODER_ARGUMENT)],
                        apply(var(ENCODER_ARGUMENT), [empty]),
                    )],
                ));
            }
            let decoder = pipeline(apply(succeed, [var(name.clone())]), steps);
            if shape.fields.is_empty() {
                // Each oneof step checks the object itself, so a message of
                // oneofs alone needs no check of its own.
                decoder
            } else {
                let message = self.reference((PROTO_JSON, "message"));
                apply(message, [decoder])
            }
        };
        self.deep = None;
        let doc = format!(
            "Decodes {} from proto3 JSON.",
            docs::a_local(&shape.message.elm_name)
        );
        if let Some(deep) = deep {
            let doc = if deep == Deep::Built {
                format!(
                    "Decodes {} from proto3 JSON, reading each `Any` it holds with the \
                     registry: one of a type the registry lacks fails.",
                    docs::a_local(&shape.message.elm_name)
                )
            } else {
                doc
            };
            return self.leveled_decoders(deep, name, shape.message.decoder_name(), doc, body);
        }
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

    /// A field's decoder ([`Self::field_decoder`]), its values read one
    /// level deeper when the field is on its message's cycle.
    fn deep_field_decoder(
        &mut self,
        field: &crate::ir::Field,
        value: super::field::FieldShape,
    ) -> Option<(Expr, Expr)> {
        self.deep_value = field.recursive;
        let decoder = self.field_decoder(value);
        self.deep_value = false;
        decoder
    }

    /// Whether messages hold their unknown fields (`unknown_fields=keep`).
    pub(super) fn keeps_unknown(&self) -> bool {
        self.unknown_fields == UnknownFields::Keep
    }
}
