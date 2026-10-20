//! The descriptors of a package's messages and enums, their typed values
//! and the package's registry (design §3.9).
//!
//! A message's descriptor module, `Notes.V1.Note`, holds one
//! `Proto.Field.Descriptor` per field, named as its record field
//! (`title`), and `descriptor : Proto.Message.Descriptor` built from
//! them; an enum's, `Notes.V1.Visibility`, holds `descriptor :
//! Proto.Enum.Descriptor`. The package's module holds the typed values,
//! `messageNote : Proto.Message.Message Note` and `enumVisibility :
//! Proto.Enum.Enum Visibility`, each built from its type's codecs,
//! default and descriptor, and `registry : Proto.Registry.Registry`,
//! built from the descriptors alone.

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
use crate::naming::{DESCRIPTOR_VALUE, REGISTRY};

/// One field or oneof member of a message, as its descriptor module
/// declares it.
struct FieldValue<'m> {
    /// The Elm value, such as `pageSize`.
    elm_name: String,
    proto_name: &'m str,
    json_name: &'m str,
    number: u32,
    cardinality: Option<Cardinality>,
    ty: &'m TypeRef,
    /// The proto name of the oneof it is a member of.
    oneof: Option<&'m str>,
    annotations: &'m Annotations,
}

impl Emitter {
    /// The declarations of a message's descriptor module: `descriptor :
    /// Proto.Message.Descriptor`, the message's full name and its fields,
    /// then one `Proto.Field.Descriptor` per field in declaration order,
    /// each oneof's members where the oneof is. The builder derives the
    /// message's oneofs from the fields.
    pub(super) fn message_descriptor_module(&mut self, shape: &MessageShape) -> Vec<Decl> {
        let message = shape.message;
        let fields = field_values(shape);
        let builder = self.reference((PROTO_MESSAGE, "descriptor"));
        let body = apply(
            builder,
            [
                string(message.proto_full_name.clone()),
                list(fields.iter().map(|field| var(field.elm_name.clone()))),
            ],
        );
        let mut decls = vec![Decl::Value {
            doc: Some(format!(
                "What the proto says about the message `{}`: its full name and its fields, \
                 in declaration order.",
                message.proto_full_name
            )),
            name: DESCRIPTOR_VALUE.to_owned(),
            annotation: self.library_type(PROTO_MESSAGE, "Descriptor", []),
            params: Vec::new(),
            body,
        }];
        for field in &fields {
            let doc = match field.oneof {
                Some(oneof) => format!(
                    "The field `{}` of `{}`, a member of the oneof `{oneof}`.",
                    field.proto_name, message.proto_full_name
                ),
                None => format!(
                    "The field `{}` of `{}`.",
                    field.proto_name, message.proto_full_name
                ),
            };
            let body = self.field_descriptor(field);
            decls.push(Decl::Value {
                doc: Some(doc),
                name: field.elm_name.clone(),
                annotation: self.library_type(PROTO_FIELD, "Descriptor", []),
                params: Vec::new(),
                body,
            });
        }
        decls
    }

    /// `messageFoo : Proto.Message.Message Foo`, built by
    /// `Proto.Message.message` from the message's encoder, decoder and
    /// default, and its descriptor.
    pub(super) fn message_record(&mut self, package: &ModuleName, shape: &MessageShape) -> Decl {
        let message = shape.message;
        let annotation =
            self.library_type(PROTO_MESSAGE, "Message", [ty(message.elm_name.clone(), [])]);
        let builder = self.reference((PROTO_MESSAGE, "message"));
        let descriptor = self.generated_value(
            &message.descriptor_module(package),
            DESCRIPTOR_VALUE.to_owned(),
        );
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
                    descriptor,
                ],
            ),
        }
    }

    /// The declaration of an enum's descriptor module: `descriptor :
    /// Proto.Enum.Descriptor`, the enum's full name and every declared
    /// name in order with its number (an alias with its number), each
    /// deprecated one marked.
    pub(super) fn enum_descriptor_module(&mut self, enumeration: &Enum) -> Vec<Decl> {
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
        vec![Decl::Value {
            doc: Some(format!(
                "What the proto says about the enum `{}`: its full name and its values, in \
                 declaration order.",
                enumeration.proto_full_name
            )),
            name: DESCRIPTOR_VALUE.to_owned(),
            annotation: self.library_type(PROTO_ENUM, "Descriptor", []),
            params: Vec::new(),
            body,
        }]
    }

    /// `enumBar : Proto.Enum.Enum Bar`, built by `Proto.Enum.enum` from
    /// the enum's encoder, decoder and zero value, and its descriptor.
    pub(super) fn enum_record(&mut self, package: &ModuleName, enumeration: &Enum) -> Decl {
        let annotation =
            self.library_type(PROTO_ENUM, "Enum", [ty(enumeration.elm_name.clone(), [])]);
        let builder = self.reference((PROTO_ENUM, "enum"));
        let descriptor = self.generated_value(
            &enumeration.descriptor_module(package),
            DESCRIPTOR_VALUE.to_owned(),
        );
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
                    descriptor,
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
    /// It lists the descriptor modules' `descriptor` values, not the
    /// typed values: Elm's dead-code elimination keeps a top-level value
    /// whole, so a registry built from `messageFoo` would keep every type's
    /// codecs and default in a program that uses it.
    pub(super) fn registry(&mut self, package: &Package) -> Decl {
        let messages: Vec<Expr> = package
            .messages
            .iter()
            .map(|message| {
                let module = message.descriptor_module(&package.module);
                self.generated_value(&module, DESCRIPTOR_VALUE.to_owned())
            })
            .collect();
        let enums: Vec<Expr> = package
            .enums
            .iter()
            .map(|enumeration| {
                let module = enumeration.descriptor_module(&package.module);
                self.generated_value(&module, DESCRIPTOR_VALUE.to_owned())
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

    /// `Proto.Field.descriptor name jsonName number cardinality kind`,
    /// then a modifier for each property the field has beyond those: its
    /// oneof, its behavior, its deprecation. A field without any is the
    /// builder alone, so the common field stays one line.
    fn field_descriptor(&mut self, field: &FieldValue) -> Expr {
        let cardinality = match field.cardinality {
            Some(cardinality) => self.cardinality(cardinality),
            None => self.reference((PROTO_FIELD, "CardinalitySingular")),
        };
        let kind = self.kind(field.ty);
        let mut built = apply(
            self.reference((PROTO_FIELD, "descriptor")),
            [
                string(field.proto_name),
                string(field.json_name),
                int(field.number.into()),
                cardinality,
                kind,
            ],
        );
        if let Some(oneof) = field.oneof {
            let modifier = apply(self.reference((PROTO_FIELD, "inOneof")), [string(oneof)]);
            built = pipe(built, modifier);
        }
        let annotations = field.annotations;
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
    /// descriptor, from its descriptor module, or `KindMessage` of the
    /// message's full name.
    fn kind(&mut self, ty: &TypeRef) -> Expr {
        let (constructor, argument) = match ty {
            TypeRef::Scalar(kind) => ("KindScalar", self.reference((PROTO_FIELD, scalar(*kind)))),
            TypeRef::Enum { name, .. } => (
                "KindEnum",
                self.generated_value(&name.descriptor_module(), DESCRIPTOR_VALUE.to_owned()),
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

/// The fields of a message's descriptor module, in declaration order:
/// each oneof's members where the oneof is.
fn field_values<'m>(shape: &MessageShape<'m>) -> Vec<FieldValue<'m>> {
    let mut fields = Vec::new();
    for field in shape.record() {
        match field {
            RecordField::Field(field, _) => fields.push(FieldValue {
                elm_name: field.value_name(),
                proto_name: &field.proto_name,
                json_name: &field.json_name,
                number: field.number,
                cardinality: Some(field.cardinality),
                ty: &field.ty,
                oneof: None,
                annotations: &field.annotations,
            }),
            RecordField::Oneof(oneof) => {
                for (variant, _) in &oneof.variants {
                    fields.push(FieldValue {
                        elm_name: variant.elm_name.clone(),
                        proto_name: &variant.proto_name,
                        json_name: &variant.json_name,
                        number: variant.number,
                        cardinality: None,
                        ty: &variant.ty,
                        oneof: Some(&oneof.oneof.proto_name),
                        annotations: &variant.annotations,
                    });
                }
            }
        }
    }
    fields
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
