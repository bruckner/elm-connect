//! The descriptors of a package's messages and enums, their typed values
//! and the package's registry (design §3.9): `descriptorFoo :
//! Proto.Message.Descriptor` and `descriptorBar : Proto.Enum.Descriptor`,
//! built with the positional `descriptor` builders; `messageFoo : Proto.Message.Message
//! Foo` and `enumBar : Proto.Enum.Enum Bar`, each built from its type's
//! codecs, default and descriptor; and `registry :
//! Proto.Registry.Registry`, built from the descriptors alone.

use std::collections::BTreeSet;

use super::{
    Emitter, MessageShape, PROTO_ENUM, PROTO_ENUM_VALUE, PROTO_FIELD, PROTO_MESSAGE,
    PROTO_REGISTRY, RecordField,
};
use crate::elm::ast::{Decl, Expr};
use crate::elm::build::{apply, inline_list, int, list, pipe, string, ty, var};
use crate::ir::{
    Annotations, Cardinality, Enum, FieldBehavior, MapKey, ModuleName, Package, ScalarKind, TypeRef,
};
use crate::naming::{self, REGISTRY};

impl Emitter {
    /// `descriptorFoo : Proto.Message.Descriptor`: the
    /// message's full name and its fields; the builder derives its oneofs
    /// from the fields.
    pub(super) fn message_descriptor(&mut self, shape: &MessageShape) -> Decl {
        let message = shape.message;
        let fields = self.field_descriptors(shape);
        let builder = self.reference((PROTO_MESSAGE, "descriptor"));
        let body = apply(
            builder,
            [string(message.proto_full_name.clone()), list(fields)],
        );
        Decl::Value {
            doc: None,
            name: message.descriptor_name(),
            annotation: self.library_type(PROTO_MESSAGE, "Descriptor", []),
            params: Vec::new(),
            body,
        }
    }

    /// `messageFoo : Proto.Message.Message Foo`, built by
    /// `Proto.Message.message` from the message's encoder, decoder and
    /// default, and its descriptor.
    pub(super) fn message_record(&mut self, shape: &MessageShape) -> Decl {
        let message = shape.message;
        let annotation =
            self.library_type(PROTO_MESSAGE, "Message", [ty(message.elm_name.clone(), [])]);
        let builder = self.reference((PROTO_MESSAGE, "message"));
        Decl::Value {
            doc: None,
            name: message.value_name(),
            annotation,
            params: Vec::new(),
            body: apply(
                builder,
                [
                    var(message.encoder_name()),
                    var(message.decoder_name()),
                    var(message.default_name()),
                    var(message.descriptor_name()),
                ],
            ),
        }
    }

    /// `descriptorBar : Proto.Enum.Descriptor`: the enum's full
    /// name and every declared name in order with its number (an alias
    /// with its number), each deprecated one marked.
    pub(super) fn enum_descriptor(&mut self, enumeration: &Enum) -> Decl {
        let values: Vec<Expr> = enumeration
            .declared()
            .map(|(name, value)| {
                let builder = self.reference((PROTO_ENUM_VALUE, "descriptor"));
                let built = apply(builder, [string(name), int(value.number.into())]);
                if enumeration.is_deprecated(name) {
                    pipe(built, self.reference((PROTO_ENUM_VALUE, "withDeprecated")))
                } else {
                    built
                }
            })
            .collect();
        let builder = self.reference((PROTO_ENUM, "descriptor"));
        let body = apply(
            builder,
            [string(enumeration.proto_full_name.clone()), list(values)],
        );
        Decl::Value {
            doc: None,
            name: enumeration.descriptor_name(),
            annotation: self.library_type(PROTO_ENUM, "Descriptor", []),
            params: Vec::new(),
            body,
        }
    }

    /// `enumBar : Proto.Enum.Enum Bar`, built by `Proto.Enum.enum` from
    /// the enum's encoder, decoder and zero value, and its descriptor.
    pub(super) fn enum_record(&mut self, enumeration: &Enum) -> Decl {
        let annotation =
            self.library_type(PROTO_ENUM, "Enum", [ty(enumeration.elm_name.clone(), [])]);
        let builder = self.reference((PROTO_ENUM, "enum"));
        Decl::Value {
            doc: None,
            name: enumeration.value_name(),
            annotation,
            params: Vec::new(),
            body: apply(
                builder,
                [
                    var(enumeration.encoder_name()),
                    var(enumeration.decoder_name()),
                    var(enumeration.zero().elm_ctor.clone()),
                    var(enumeration.descriptor_name()),
                ],
            ),
        }
    }

    /// `registry : Proto.Registry.Registry`: the package's own descriptors,
    /// then the registries of the generated packages its module imports,
    /// each of which holds those of its own imports, then the well-known
    /// types'. Of two descriptors with one full name the first is kept,
    /// though a full name is never in two packages.
    ///
    /// It lists the `descriptorFoo` values, not the typed values: Elm's
    /// dead-code elimination keeps a top-level value whole, so a registry
    /// built from `messageFoo` would keep every type's codecs and default
    /// in a program that uses it.
    pub(super) fn registry(&mut self, package: &Package) -> Decl {
        let messages: Vec<Expr> = package
            .messages
            .iter()
            .map(|message| var(message.descriptor_name()))
            .collect();
        let enums: Vec<Expr> = package
            .enums
            .iter()
            .map(|enumeration| var(enumeration.descriptor_name()))
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

    /// One `Proto.Field.Descriptor` per field of the message, in
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
                        &field.annotations,
                    ));
                }
                RecordField::Oneof(oneof) => {
                    for (variant, _) in &oneof.variants {
                        let cardinality = self.reference((PROTO_FIELD, "CardinalitySingular"));
                        fields.push(self.field_descriptor(
                            &variant.proto_name,
                            &variant.json_name,
                            variant.number,
                            cardinality,
                            &variant.ty,
                            Some(&oneof.oneof.proto_name),
                            &variant.annotations,
                        ));
                    }
                }
            }
        }
        fields
    }

    /// `Proto.Field.descriptor name jsonName number cardinality kind`,
    /// then a modifier for each property the field has beyond those: its
    /// oneof, its behavior, its deprecation. A field without any is the
    /// builder alone, so the common field stays one line.
    #[allow(clippy::too_many_arguments)]
    fn field_descriptor(
        &mut self,
        name: &str,
        json_name: &str,
        number: u32,
        cardinality: Expr,
        ty: &TypeRef,
        oneof: Option<&str>,
        annotations: &Annotations,
    ) -> Expr {
        let kind = self.kind(ty);
        let mut built = apply(
            self.reference((PROTO_FIELD, "descriptor")),
            [
                string(name),
                string(json_name),
                int(number.into()),
                cardinality,
                kind,
            ],
        );
        if let Some(oneof) = oneof {
            let modifier = apply(self.reference((PROTO_FIELD, "inOneof")), [string(oneof)]);
            built = pipe(built, modifier);
        }
        if !annotations.behavior.is_empty() {
            let behavior: Vec<Expr> = annotations
                .behavior
                .iter()
                .map(|behavior| self.reference((PROTO_FIELD, behavior_constructor(*behavior))))
                .collect();
            let modifier = apply(
                self.reference((PROTO_FIELD, "withBehavior")),
                [inline_list(behavior)],
            );
            built = pipe(built, modifier);
        }
        if annotations.deprecated {
            built = pipe(built, self.reference((PROTO_FIELD, "withDeprecated")));
        }
        built
    }

    /// `Proto.Field.CardinalitySingular`, `CardinalityOptional`,
    /// `CardinalityRepeated`, or `CardinalityMap` of the key's scalar.
    fn cardinality(&mut self, cardinality: Cardinality) -> Expr {
        match cardinality {
            Cardinality::Singular => self.reference((PROTO_FIELD, "CardinalitySingular")),
            Cardinality::Optional => self.reference((PROTO_FIELD, "CardinalityOptional")),
            Cardinality::Repeated => self.reference((PROTO_FIELD, "CardinalityRepeated")),
            Cardinality::Map(key) => {
                let map = self.reference((PROTO_FIELD, "CardinalityMap"));
                let key = self.reference((PROTO_FIELD, map_key_scalar(key)));
                apply(map, [key])
            }
        }
    }

    /// `Proto.Field.KindScalar` of the scalar, `KindEnum` of the enum's
    /// descriptor value, or `KindMessage` of the message's full name.
    fn kind(&mut self, ty: &TypeRef) -> Expr {
        let (constructor, argument) = match ty {
            TypeRef::Scalar(kind) => ("KindScalar", self.reference((PROTO_FIELD, scalar(*kind)))),
            TypeRef::Enum { name, .. } => (
                "KindEnum",
                self.generated_value(&name.module, naming::descriptor_name(&name.name)),
            ),
            TypeRef::Message(name) => ("KindMessage", string(name.proto_full_name.clone())),
            TypeRef::WellKnown(known) => ("KindMessage", string(known.proto_full_name())),
        };
        apply(self.reference((PROTO_FIELD, constructor)), [argument])
    }
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

/// The `Proto.Field.Behavior` constructor of a field behavior.
fn behavior_constructor(behavior: FieldBehavior) -> &'static str {
    match behavior {
        FieldBehavior::Optional => "BehaviorOptional",
        FieldBehavior::Required => "BehaviorRequired",
        FieldBehavior::OutputOnly => "BehaviorOutputOnly",
        FieldBehavior::InputOnly => "BehaviorInputOnly",
        FieldBehavior::Immutable => "BehaviorImmutable",
        FieldBehavior::UnorderedList => "BehaviorUnorderedList",
        FieldBehavior::NonEmptyDefault => "BehaviorNonEmptyDefault",
        FieldBehavior::Identifier => "BehaviorIdentifier",
    }
}

/// The `Proto.Field.Scalar` constructor of a proto scalar.
fn scalar(kind: ScalarKind) -> &'static str {
    match kind {
        ScalarKind::Double => "ScalarDouble",
        ScalarKind::Float => "ScalarFloat",
        ScalarKind::Int32 => "ScalarInt32",
        ScalarKind::Int64 => "ScalarInt64",
        ScalarKind::UInt32 => "ScalarUint32",
        ScalarKind::UInt64 => "ScalarUint64",
        ScalarKind::SInt32 => "ScalarSint32",
        ScalarKind::SInt64 => "ScalarSint64",
        ScalarKind::Fixed32 => "ScalarFixed32",
        ScalarKind::Fixed64 => "ScalarFixed64",
        ScalarKind::SFixed32 => "ScalarSfixed32",
        ScalarKind::SFixed64 => "ScalarSfixed64",
        ScalarKind::Bool => "ScalarBool",
        ScalarKind::String => "ScalarString",
        ScalarKind::Bytes => "ScalarBytes",
    }
}

/// The `Proto.Field.Scalar` constructor of a map key.
fn map_key_scalar(key: MapKey) -> &'static str {
    match key {
        MapKey::Int32 => "ScalarInt32",
        MapKey::Int64 => "ScalarInt64",
        MapKey::UInt32 => "ScalarUint32",
        MapKey::UInt64 => "ScalarUint64",
        MapKey::SInt32 => "ScalarSint32",
        MapKey::SInt64 => "ScalarSint64",
        MapKey::Fixed32 => "ScalarFixed32",
        MapKey::Fixed64 => "ScalarFixed64",
        MapKey::SFixed32 => "ScalarSfixed32",
        MapKey::SFixed64 => "ScalarSfixed64",
        MapKey::String => "ScalarString",
        MapKey::Bool => "ScalarBool",
    }
}
