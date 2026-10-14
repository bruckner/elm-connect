//! The typed records of a package's messages and enums and the package's
//! registry (design §3.9): `messageFoo : Proto.Message.Message Foo`,
//! holding the message's codecs and its descriptor, `enumBar :
//! Proto.Enum.Enum Bar`, holding the enum's name, codecs and values, and
//! `registry : Proto.Registry.Registry`.

use std::collections::BTreeSet;

use super::{
    Descriptors, Emitter, MessageShape, PROTO_DESCRIPTOR, PROTO_ENUM, PROTO_MESSAGE,
    PROTO_REGISTRY, RecordField,
};
use crate::elm::ast::{Decl, Expr};
use crate::elm::build::{access, apply, inline_record, int, list, record, string, ty, var};
use crate::ir::{Cardinality, Enum, MapKey, ModuleName, Package, ScalarKind, TypeRef};
use crate::naming::REGISTRY;

impl Emitter {
    /// `messageFoo : Proto.Message.Message Foo`: the message's encoder,
    /// decoder and default, and its descriptor.
    pub(super) fn message_record(&mut self, shape: &MessageShape) -> Decl {
        let message = shape.message;
        let (fields, oneofs) = match self.descriptors {
            Descriptors::On => (self.field_descriptors(shape), oneof_names(shape)),
            Descriptors::Off => (Vec::new(), Vec::new()),
        };
        let descriptor = record([
            ("typeName", string(message.proto_full_name.clone())),
            ("fields", list(fields)),
            ("oneofs", list(oneofs)),
        ]);
        let annotation =
            self.library_type(PROTO_MESSAGE, "Message", [ty(message.elm_name.clone(), [])]);
        Decl::Value {
            doc: None,
            name: message.value_name(),
            annotation,
            params: Vec::new(),
            body: record([
                ("encodeJson", var(message.encoder_name())),
                ("jsonDecoder", var(message.decoder_name())),
                ("default", var(message.default_name())),
                ("descriptor", descriptor),
            ]),
        }
    }

    /// `enumBar : Proto.Enum.Enum Bar`: the enum's full name, its encoder
    /// and decoder, and every value name in declaration order with its
    /// number and constructor (an alias with its value's). That is all the
    /// proto says about an enum, so the record carries no descriptor;
    /// `Proto.Enum.descriptor` builds one.
    pub(super) fn enum_record(&mut self, enumeration: &Enum) -> Decl {
        let values: Vec<Expr> = enumeration
            .declared()
            .map(|(name, value)| {
                inline_record([
                    ("name", string(name)),
                    ("number", int(value.number.into())),
                    ("value", var(value.elm_ctor.clone())),
                ])
            })
            .collect();
        let annotation =
            self.library_type(PROTO_ENUM, "Enum", [ty(enumeration.elm_name.clone(), [])]);
        Decl::Value {
            doc: None,
            name: enumeration.value_name(),
            annotation,
            params: Vec::new(),
            body: record([
                ("typeName", string(enumeration.proto_full_name.clone())),
                ("encodeJson", var(enumeration.encoder_name())),
                ("jsonDecoder", var(enumeration.decoder_name())),
                ("values", list(values)),
            ]),
        }
    }

    /// `registry : Proto.Registry.Registry`: the package's own descriptors
    /// (an enum's built by `Proto.Enum.descriptor`), then the registries of the generated packages its module imports,
    /// each of which holds those of its own imports, then the well-known
    /// types'. Of two descriptors with one full name the first is kept,
    /// though a full name is never in two packages.
    pub(super) fn registry(&mut self, package: &Package) -> Decl {
        let messages: Vec<Expr> = package
            .messages
            .iter()
            .map(|message| access(var(message.value_name()), "descriptor"))
            .collect();
        let enums: Vec<Expr> = package
            .enums
            .iter()
            .map(|enumeration| {
                let descriptor = self.reference((PROTO_ENUM, "descriptor"));
                apply(descriptor, [var(enumeration.value_name())])
            })
            .collect();
        let union = self.reference((PROTO_REGISTRY, "union"));
        let mut parts: Vec<Expr> = Vec::new();
        if !messages.is_empty() || !enums.is_empty() {
            let own = self.reference((PROTO_REGISTRY, "fromDescriptors"));
            parts.push(apply(own, [list(messages), list(enums)]));
        }
        for module in imported_packages(package) {
            parts.push(self.generated_value(&module, REGISTRY.to_owned()));
        }
        parts.push(self.reference((PROTO_REGISTRY, "wellKnown")));
        let body = parts
            .into_iter()
            .rev()
            .reduce(|right, left| apply(union.clone(), [left, right]))
            .expect("at least the well-known types");
        Decl::Value {
            doc: None,
            name: REGISTRY.to_owned(),
            annotation: self.library_type(PROTO_REGISTRY, "Registry", []),
            params: Vec::new(),
            body,
        }
    }

    /// One `Proto.Descriptor.Field` per field of the message, in
    /// declaration order: each oneof's members where the oneof is.
    fn field_descriptors(&mut self, shape: &MessageShape) -> Vec<Expr> {
        let mut fields = Vec::new();
        for field in shape.record() {
            match field {
                RecordField::Field(field, _) => {
                    let cardinality = self.cardinality(field.cardinality);
                    fields.push(self.field_descriptor(
                        &field.proto_name,
                        &field.json_name,
                        field.number,
                        cardinality,
                        &field.ty,
                        None,
                    ));
                }
                RecordField::Oneof(oneof) => {
                    for (variant, _) in &oneof.variants {
                        let cardinality = self.descriptor_value("Singular");
                        fields.push(self.field_descriptor(
                            &variant.proto_name,
                            &variant.json_name,
                            variant.number,
                            cardinality,
                            &variant.ty,
                            Some(&oneof.oneof.proto_name),
                        ));
                    }
                }
            }
        }
        fields
    }

    /// `{ name = …, jsonName = …, number = …, cardinality = …, kind = …,
    /// oneof = … }`, on one line.
    fn field_descriptor(
        &mut self,
        name: &str,
        json_name: &str,
        number: u32,
        cardinality: Expr,
        ty: &TypeRef,
        oneof: Option<&str>,
    ) -> Expr {
        let kind = self.kind(ty);
        let oneof = match oneof {
            Some(name) => apply(var("Just"), [string(name)]),
            None => var("Nothing"),
        };
        inline_record([
            ("name", string(name)),
            ("jsonName", string(json_name)),
            ("number", int(number.into())),
            ("cardinality", cardinality),
            ("kind", kind),
            ("oneof", oneof),
        ])
    }

    /// `Proto.Descriptor.Singular`, `Optional`, `Repeated`, or `Map` of the
    /// key's scalar.
    fn cardinality(&mut self, cardinality: Cardinality) -> Expr {
        match cardinality {
            Cardinality::Singular => self.descriptor_value("Singular"),
            Cardinality::Optional => self.descriptor_value("Optional"),
            Cardinality::Repeated => self.descriptor_value("Repeated"),
            Cardinality::Map(key) => {
                let map = self.descriptor_value("Map");
                let key = self.descriptor_value(map_key_scalar(key));
                apply(map, [key])
            }
        }
    }

    /// `Proto.Descriptor.Scalar` of the scalar, or `Enum` or `Message` of
    /// the type's full name.
    fn kind(&mut self, ty: &TypeRef) -> Expr {
        let (constructor, argument) = match ty {
            TypeRef::Scalar(kind) => ("Scalar", self.descriptor_value(scalar(*kind))),
            TypeRef::Enum { name, .. } => ("Enum", string(name.proto_full_name.clone())),
            TypeRef::Message(name) => ("Message", string(name.proto_full_name.clone())),
            TypeRef::WellKnown(known) => ("Message", string(known.proto_full_name())),
        };
        apply(self.descriptor_value(constructor), [argument])
    }

    /// A constructor of `Proto.Descriptor`.
    fn descriptor_value(&mut self, name: &str) -> Expr {
        self.reference((PROTO_DESCRIPTOR, name))
    }
}

/// The names of the message's oneofs, as strings, in declaration order.
fn oneof_names(shape: &MessageShape) -> Vec<Expr> {
    shape
        .oneofs
        .iter()
        .map(|oneof| string(oneof.oneof.proto_name.clone()))
        .collect()
}

/// The other generated packages `package`'s module imports: those its
/// fields and oneof members refer to, by module name.
fn imported_packages(package: &Package) -> BTreeSet<ModuleName> {
    let types = package
        .messages
        .iter()
        .flat_map(|message| {
            message.fields.iter().map(|field| &field.ty).chain(
                message
                    .oneofs
                    .iter()
                    .flat_map(|oneof| oneof.variants.iter().map(|variant| &variant.ty)),
            )
        })
        .filter_map(|ty| match ty {
            TypeRef::Message(name) | TypeRef::Enum { name, .. } => Some(&name.module),
            TypeRef::Scalar(_) | TypeRef::WellKnown(_) => None,
        });
    types
        .filter(|module| **module != package.module)
        .cloned()
        .collect()
}

/// The `Proto.Descriptor.Scalar` constructor of a proto scalar.
fn scalar(kind: ScalarKind) -> &'static str {
    match kind {
        ScalarKind::Double => "Double",
        ScalarKind::Float => "Float",
        ScalarKind::Int32 => "Int32",
        ScalarKind::Int64 => "Int64",
        ScalarKind::UInt32 => "Uint32",
        ScalarKind::UInt64 => "Uint64",
        ScalarKind::SInt32 => "Sint32",
        ScalarKind::SInt64 => "Sint64",
        ScalarKind::Fixed32 => "Fixed32",
        ScalarKind::Fixed64 => "Fixed64",
        ScalarKind::SFixed32 => "Sfixed32",
        ScalarKind::SFixed64 => "Sfixed64",
        ScalarKind::Bool => "Bool",
        ScalarKind::String => "String",
        ScalarKind::Bytes => "Bytes",
    }
}

/// The `Proto.Descriptor.Scalar` constructor of a map key.
fn map_key_scalar(key: MapKey) -> &'static str {
    match key {
        MapKey::Int32 => "Int32",
        MapKey::Int64 => "Int64",
        MapKey::UInt32 => "Uint32",
        MapKey::UInt64 => "Uint64",
        MapKey::SInt32 => "Sint32",
        MapKey::SInt64 => "Sint64",
        MapKey::Fixed32 => "Fixed32",
        MapKey::Fixed64 => "Fixed64",
        MapKey::SFixed32 => "Sfixed32",
        MapKey::SFixed64 => "Sfixed64",
        MapKey::String => "String",
        MapKey::Bool => "Bool",
    }
}
