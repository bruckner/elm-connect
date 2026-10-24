//! An enum's three declarations: its custom type, its encoder and its
//! decoder (design §3.3).

use super::{Emitter, JSON_DECODE, JSON_ENCODE, PROTO_JSON, docs};
use crate::elm::ast::{Decl, Expr, Type, Variant};
use crate::elm::build::{apply, case, int, list, pctor, pvar, string, ty, var};
use crate::ir::{Enum, ModuleName};
use crate::naming::ENCODER_ARGUMENT;
use crate::options::EnumUnknown;

impl Emitter {
    /// `type Status = StatusUnspecified | ...`, one constructor per number,
    /// the zero value first.
    pub(super) fn enum_type(&mut self, package: &ModuleName, enumeration: &Enum) -> Decl {
        let descriptors = docs::page(&enumeration.descriptor_module(package));
        Decl::CustomType {
            doc: Some(docs::enumeration(enumeration, &descriptors)),
            name: enumeration.elm_name.clone(),
            type_params: Vec::new(),
            variants: enumeration
                .values()
                .map(|value| Variant {
                    name: value.elm_ctor.clone(),
                    args: Vec::new(),
                })
                .collect(),
        }
    }

    /// `encodeStatus : Status -> Json.Encode.Value`: a `case` giving each
    /// constructor its proto name as a JSON string, the first declared
    /// name for an aliased number.
    pub(super) fn enum_encoder(&mut self, enumeration: &Enum) -> Decl {
        let branches: Vec<_> = enumeration
            .values()
            .map(|value| {
                let encode = self.reference((JSON_ENCODE, "string"));
                (
                    pctor(value.elm_ctor.clone(), []),
                    apply(encode, [string(value.proto_name.clone())]),
                )
            })
            .collect();
        let value_type = self.library_type(JSON_ENCODE, "Value", []);
        Decl::Value {
            doc: Some(format!(
                "Encodes {} as proto3 JSON.",
                docs::a_local(&enumeration.elm_name)
            )),
            name: enumeration.encoder_name(),
            annotation: Type::Function(
                Box::new(ty(enumeration.elm_name.clone(), [])),
                Box::new(value_type),
            ),
            params: vec![pvar(ENCODER_ARGUMENT)],
            body: case(var(ENCODER_ARGUMENT), branches),
        }
    }

    /// `decodeStatus : Json.Decode.Decoder Status`: `Proto.Json.enum`, or
    /// `Proto.Json.enumOrZero` under `enum_unknown=zero`, with the enum's
    /// proto name, the zero value and a
    /// `( name, number, constructor )` row per value name, an alias's row
    /// after its constructor's own.
    pub(super) fn enum_decoder(&mut self, enumeration: &Enum) -> Decl {
        let rows = enumeration.values().flat_map(|value| {
            std::iter::once(&value.proto_name)
                .chain(&value.aliases)
                .map(|name| {
                    Expr::Tuple(vec![
                        string(name.clone()),
                        int(value.number.into()),
                        var(value.elm_ctor.clone()),
                    ])
                })
        });
        let decoder = match self.enum_unknown {
            EnumUnknown::Fail => "enum",
            EnumUnknown::Zero => "enumOrZero",
        };
        let decode = self.reference((PROTO_JSON, decoder));
        let body = apply(
            decode,
            [
                string(enumeration.proto_name.clone()),
                var(enumeration.zero().elm_ctor.clone()),
                list(rows),
            ],
        );
        let annotation = self.library_type(
            JSON_DECODE,
            "Decoder",
            [ty(enumeration.elm_name.clone(), [])],
        );
        Decl::Value {
            doc: Some(format!(
                "Decodes {} from proto3 JSON.",
                docs::a_local(&enumeration.elm_name)
            )),
            name: enumeration.decoder_name(),
            annotation,
            params: Vec::new(),
            body,
        }
    }
}
