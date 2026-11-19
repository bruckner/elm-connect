//! Protobuf binary codecs, under every `wire` option: per
//! message `encodeFooBytes : Foo -> Bytes.Encode.Encoder`,
//! `mergeFooBytes : Foo -> Proto.Binary.Decoder Foo` (reading into a value
//! read before, as protobuf merges a message arriving twice) and
//! `decodeFooBytes : Proto.Binary.Decoder Foo` (`mergeFooBytes` of the
//! default), per enum its number conversions `encodeBarBytes : Bar -> Int`
//! and `decodeBarBytes : Int -> Bar`, per oneof an encoder of its set
//! member, and per recursion wrapper a pair that unwraps and wraps.
//!
//! An encoder is `Bytes.Encode.sequence` of one `Proto.Binary` field
//! helper per field in field-number order, each oneof's encoder where its
//! first member's number falls; a oneof whose members' numbers have
//! another field's between them is written instead as one `case` per run
//! of members with no other field between them, each where its run falls,
//! so the set member is in field-number order too. A merge is `Proto.Binary.merge` of the
//! message's full name, which a decoding failure's path names it by, a step
//! that `case`s on the field number into a record update (an unknown
//! number skipped by its wire type) and a finishing function that reverses
//! the lists the step built front-first. A singular message field, and a
//! oneof's message member, is read into the message read before it
//! (`Proto.Binary.fieldInto`). Every value's codec is a
//! `Proto.Binary.Codec`: the runtime's for a scalar or well-known type,
//! `Proto.Binary.enum` of an enum's conversions (for
//! `google.protobuf.NullValue`, conversions to and from `()`),
//! `Proto.Binary.embedded` of a message's encoder, merge and default.

use super::field::{FieldShape, Present, ValueShape, Zeroed, field_holding};
use super::scalar::Holding;
use super::{Emitter, MessageShape, OneofShape, RecordField, docs};
use crate::elm::ast::{BinOp, Decl, Expr, LetBinding, Pattern, Type};
use crate::elm::build::{
    access, apply, binop, case, if_then_else, int, lambda, let_in, list, pctor, pipe, pvar,
    qualified, record, string, ty, var,
};
use crate::ir::{
    Cardinality, Enum, Field, MapKey, Message, OneofVariant, ScalarKind, TypeRef, WellKnown,
    Wrapper,
};
use crate::naming::{ENCODER_ARGUMENT, ONEOF_MEMBER, default_name};
use crate::options::Int64;

/// elm/bytes' encoders.
pub(super) const BYTES_ENCODE: &str = "Bytes.Encode";
/// The runtime package's wire format.
pub(super) const PROTO_BINARY: &str = "Proto.Binary";

/// The locals a binary decoder binds: the field number and wire type its
/// step is given, and the key and value a field helper hands its update.
/// Like `ENCODER_ARGUMENT`, none is the name of a generated top-level
/// value: those all start with a prefix or are a method's, and a method's
/// lives in its service's module.
const NUMBER: &str = "number";
const WIRE: &str = "wire";
const ITEM: &str = "v";
const KEY: &str = "k";

/// The binary codec's name beside a JSON codec's: `encodeNote` becomes
/// `encodeNoteBytes`.
pub(super) fn bytes_name(json_name: String) -> String {
    format!("{json_name}Bytes")
}

/// The binary merge beside a decoder's name: `decodeNote` becomes
/// `mergeNoteBytes`. `merge` is a prefix like the others
/// (`crate::naming::default_name`), none of which it begins or ends.
fn merge_name(decoder_name: String) -> String {
    let type_name = decoder_name
        .strip_prefix("decode")
        .expect("a decoder's name starts with decode");
    format!("merge{type_name}Bytes")
}

/// The runtime codec of a scalar of `kind`, held as `holding` says.
fn scalar_codec(kind: ScalarKind, holding: Holding) -> &'static str {
    let int = holding.int64 == Int64::Int;
    match kind {
        ScalarKind::Double => "double",
        ScalarKind::Float => "float",
        ScalarKind::Int32 => "int32",
        ScalarKind::SInt32 => "sint32",
        ScalarKind::SFixed32 => "sfixed32",
        ScalarKind::UInt32 => "uint32",
        ScalarKind::Fixed32 => "fixed32",
        ScalarKind::Int64 if int => "int64AsInt",
        ScalarKind::Int64 => "int64",
        ScalarKind::SInt64 if int => "sint64AsInt",
        ScalarKind::SInt64 => "sint64",
        ScalarKind::SFixed64 if int => "sfixed64AsInt",
        ScalarKind::SFixed64 => "sfixed64",
        ScalarKind::UInt64 if int => "uint64AsInt",
        ScalarKind::UInt64 => "uint64",
        ScalarKind::Fixed64 if int => "fixed64AsInt",
        ScalarKind::Fixed64 => "fixed64",
        ScalarKind::Bool => "bool",
        ScalarKind::String => "string",
        ScalarKind::Bytes => match holding.bytes {
            crate::options::Bytes::String => "bytes",
            crate::options::Bytes::Bytes => "bytesAsBytes",
        },
    }
}

/// The runtime codec of a well-known message type.
pub(super) fn well_known_codec(known: WellKnown, holding: Holding) -> &'static str {
    let int = holding.int64 == Int64::Int;
    match known {
        WellKnown::Value => "value",
        WellKnown::Struct => "struct",
        WellKnown::ListValue => "listValue",
        WellKnown::Timestamp => "timestamp",
        WellKnown::Duration => "duration",
        WellKnown::FieldMask => "fieldMask",
        WellKnown::Empty => "empty",
        WellKnown::Any => "any",
        WellKnown::DoubleValue => "doubleValue",
        WellKnown::FloatValue => "floatValue",
        WellKnown::Int64Value if int => "int64ValueAsInt",
        WellKnown::Int64Value => "int64Value",
        WellKnown::UInt64Value if int => "uint64ValueAsInt",
        WellKnown::UInt64Value => "uint64Value",
        WellKnown::Int32Value => "int32Value",
        WellKnown::UInt32Value => "uint32Value",
        WellKnown::BoolValue => "boolValue",
        WellKnown::StringValue => "stringValue",
        WellKnown::BytesValue => match holding.bytes {
            crate::options::Bytes::String => "bytesValue",
            crate::options::Bytes::Bytes => "bytesValueAsBytes",
        },
        WellKnown::NullValue => unreachable!("NullValue is an enum, with no runtime codec"),
    }
}

/// The codec of a map's keys: 64-bit keys are held as text under either
/// `int64` option, as the JSON codecs hold them.
fn key_codec(key: MapKey) -> &'static str {
    match key {
        MapKey::Int32 => "int32",
        MapKey::Int64 => "int64",
        MapKey::UInt32 => "uint32",
        MapKey::UInt64 => "uint64",
        MapKey::SInt32 => "sint32",
        MapKey::SInt64 => "sint64",
        MapKey::Fixed32 => "fixed32",
        MapKey::Fixed64 => "fixed64",
        MapKey::SFixed32 => "sfixed32",
        MapKey::SFixed64 => "sfixed64",
        MapKey::Bool => "bool",
        MapKey::String => "string",
    }
}

/// The wrapper a field's values are held in, when it closes a cycle.
fn wrapper_of<'m>(shape: FieldShape<'m>) -> Option<&'m Wrapper> {
    let value = match shape {
        FieldShape::Maybe(value)
        | FieldShape::List(value)
        | FieldShape::Dict(_, value)
        | FieldShape::BoolMap(value) => value,
        FieldShape::Plain(_) | FieldShape::Json => return None,
    };
    match value {
        ValueShape::Present(Present::Wrapped(wrapper, _)) => Some(wrapper),
        _ => None,
    }
}

/// Which form a generated binary merge takes. A spike-only switch, read
/// from `ELM_CONNECT_MERGE` (`m0`, the default, to `m3`), so that one
/// build generates every form for comparison.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum MergeForm {
    /// A `case` arm per field setting it with a record update.
    Update,
    /// The arms set their field by writing the whole record, for records
    /// of at most [`RECORD_LITERAL_MAX`] fields.
    Literal,
    /// Stages in field-number order building the record once, then the
    /// update form's loop from the record built so far at the first field
    /// that arrives out of order.
    Staged,
    /// The same stages, run again from the record built so far at each
    /// field that arrives out of order, until the message ends.
    Reentrant,
}

fn merge_form() -> MergeForm {
    match std::env::var("ELM_CONNECT_MERGE").as_deref() {
        Ok("m1") => MergeForm::Literal,
        Ok("m2") => MergeForm::Staged,
        Ok("m3") => MergeForm::Reentrant,
        _ => MergeForm::Update,
    }
}

/// The most fields a record may have for a merge step to set one of them by
/// writing the whole record out.
const RECORD_LITERAL_MAX: usize = 64;

/// How a merge step sets fields of the record it is given: `{ value | name
/// = update }`, or, for a record of at most [`RECORD_LITERAL_MAX`] fields
/// under the literal form, the whole record with `name` replaced and every
/// other field copied.
struct Setter {
    names: Option<Vec<String>>,
}

impl Setter {
    fn new(shape: &MessageShape, form: MergeForm) -> Self {
        let names: Vec<String> = record_names(shape);
        Setter {
            names: (form == MergeForm::Literal && names.len() <= RECORD_LITERAL_MAX)
                .then_some(names),
        }
    }

    fn update(&self, name: &str, value: Expr) -> Expr {
        self.update_all(vec![(name.to_owned(), value)])
    }

    fn update_all(&self, mut fields: Vec<(String, Expr)>) -> Expr {
        match &self.names {
            Some(names) => {
                let whole: Vec<(String, Expr)> = names
                    .iter()
                    .map(
                        |other| match fields.iter().position(|(name, _)| name == other) {
                            Some(at) => (other.clone(), fields.swap_remove(at).1),
                            None => (other.clone(), access(var(ENCODER_ARGUMENT), other.clone())),
                        },
                    )
                    .collect();
                debug_assert!(
                    fields.is_empty(),
                    "a merge step sets a field the record lacks"
                );
                record(whole)
            }
            None => Expr::RecordUpdate {
                record: ENCODER_ARGUMENT.to_owned(),
                fields,
            },
        }
    }
}

/// The record's field names, in its declaration order.
fn record_names(shape: &MessageShape) -> Vec<String> {
    shape
        .record()
        .into_iter()
        .map(|field| match field {
            RecordField::Field(field, _) => field.elm_name.clone(),
            RecordField::Oneof(oneof) => oneof.oneof.elm_field_name.clone(),
        })
        .collect()
}

/// `\number -> ...`: whether a field number is one of `numbers`, as runs of
/// consecutive numbers.
fn known_numbers(mut numbers: Vec<u32>) -> Expr {
    numbers.sort_unstable();
    numbers.dedup();
    let mut runs: Vec<(u32, u32)> = Vec::new();
    for n in numbers {
        match runs.last_mut() {
            Some((_, hi)) if *hi + 1 == n => *hi = n,
            _ => runs.push((n, n)),
        }
    }
    let test = runs
        .into_iter()
        .map(|(lo, hi)| {
            if lo == hi {
                binop(BinOp::Eq, var(NUMBER), int(lo.into()))
            } else {
                binop(
                    BinOp::And,
                    binop(BinOp::Ge, var(NUMBER), int(lo.into())),
                    binop(BinOp::Le, var(NUMBER), int(hi.into())),
                )
            }
        })
        .reduce(|a, b| binop(BinOp::Or, a, b))
        .unwrap_or(Expr::Var {
            module: None,
            name: "False".to_owned(),
        });
    lambda([pvar(NUMBER)], test)
}

impl Emitter {
    fn binary(&mut self, name: &str) -> Expr {
        self.reference((PROTO_BINARY, name))
    }

    /// The `Proto.Binary.Codec` of one value of type `ty`, held as
    /// `holding` says; in `wrapped`, when the field closes a cycle.
    fn binary_codec(&mut self, ty: &TypeRef, holding: Holding, wrapped: Option<&Wrapper>) -> Expr {
        match (ty, wrapped) {
            (TypeRef::Message(name), Some(wrapper)) => {
                let default = self.generated_value(&name.module, default_name(&name.name));
                let embedded = self.binary("embedded");
                apply(
                    embedded,
                    [
                        var(bytes_name(wrapper.encoder_name())),
                        var(merge_name(wrapper.decoder_name())),
                        apply(var(wrapper.elm_name.clone()), [default]),
                    ],
                )
            }
            (TypeRef::Scalar(kind), _) => self.binary(scalar_codec(*kind, holding)),
            (TypeRef::Enum { name, .. }, _) => {
                let encode = self.generated_value(&name.module, bytes_name(name.encoder_name()));
                let decode = self.generated_value(&name.module, bytes_name(name.decoder_name()));
                let codec = self.binary("enum");
                apply(codec, [encode, decode])
            }
            (TypeRef::Message(name), None) => {
                let encode = self.generated_value(&name.module, bytes_name(name.encoder_name()));
                let decode = self.generated_value(&name.module, merge_name(name.decoder_name()));
                let default = self.generated_value(&name.module, default_name(&name.name));
                let embedded = self.binary("embedded");
                apply(embedded, [encode, decode, default])
            }
            (TypeRef::WellKnown(WellKnown::NullValue), _) => {
                // Its one value, `NULL_VALUE`, is the number 0.
                let codec = self.binary("enum");
                let to_number = lambda([Pattern::Wildcard], int(0));
                let from_number = lambda([Pattern::Wildcard], Expr::Unit);
                apply(codec, [to_number, from_number])
            }
            (TypeRef::WellKnown(known), _) => self.binary(well_known_codec(*known, holding)),
        }
    }

    fn field_codec(&mut self, field: &Field, shape: FieldShape) -> Expr {
        let holding = field_holding(field.jstype, self.holding);
        self.binary_codec(&field.ty, holding, wrapper_of(shape))
    }

    fn bytes_encoder_type(&mut self) -> Type {
        self.library_type(BYTES_ENCODE, "Encoder", [])
    }

    fn bytes_decoder_type(&mut self, of: Type) -> Type {
        self.library_type(PROTO_BINARY, "Decoder", [of])
    }

    /// `Foo -> Proto.Binary.Decoder Foo`.
    fn bytes_merge_type(&mut self, of: Type) -> Type {
        let decoder = self.bytes_decoder_type(of.clone());
        Type::Function(Box::new(of), Box::new(decoder))
    }

    /// `encodeFooBytes : Foo -> Bytes.Encode.Encoder`.
    pub(super) fn message_encoder_bytes(&mut self, shape: &MessageShape) -> Decl {
        let mut items: Vec<(u32, Expr)> = Vec::new();
        for &(field, field_shape) in &shape.fields {
            let value = access(var(ENCODER_ARGUMENT), field.elm_name.clone());
            let number = int(field.number.into());
            let codec = self.field_codec(field, field_shape);
            let encoded = match field_shape {
                // `()` has no presence to leave it out by; it is written,
                // as the JSON encoder writes `{}`.
                FieldShape::Plain(Zeroed::Empty) => {
                    apply(self.binary("present"), [codec, number, value])
                }
                FieldShape::Plain(_) => apply(self.binary("implicit"), [codec, number, value]),
                FieldShape::Maybe(_) | FieldShape::Json => {
                    apply(self.binary("optional"), [codec, number, value])
                }
                FieldShape::List(_) if field.unpacked => {
                    apply(self.binary("listUnpacked"), [codec, number, value])
                }
                FieldShape::List(_) => apply(self.binary("list"), [codec, number, value]),
                FieldShape::Dict(..) => {
                    let Cardinality::Map(key) = field.cardinality else {
                        unreachable!("a Dict field is a map")
                    };
                    let key = self.binary(key_codec(key));
                    apply(self.binary("dict"), [key, codec, number, value])
                }
                FieldShape::BoolMap(_) => apply(self.binary("boolMap"), [codec, number, value]),
            };
            items.push((field.number, encoded));
        }
        for (index, oneof) in shape.oneofs.iter().enumerate() {
            let value = || access(var(ENCODER_ARGUMENT), oneof.oneof.elm_field_name.clone());
            // The numbers of every other field and oneof member.
            let others: Vec<u32> = shape
                .fields
                .iter()
                .map(|(field, _)| field.number)
                .chain(
                    shape
                        .oneofs
                        .iter()
                        .enumerate()
                        .filter(|&(other, _)| other != index)
                        .flat_map(|(_, other)| other.variants.iter().map(|(v, _)| v.number)),
                )
                .collect();
            let mut members = oneof.variants.clone();
            members.sort_by_key(|(variant, _)| variant.number);
            let mut runs: Vec<Vec<(&OneofVariant, ValueShape)>> = Vec::new();
            for member in members {
                let split = runs.last().and_then(|run| run.last()).is_some_and(|last| {
                    others
                        .iter()
                        .any(|&n| last.0.number < n && n < member.0.number)
                });
                match runs.last_mut() {
                    Some(run) if !split => run.push(member),
                    _ => runs.push(vec![member]),
                }
            }
            if runs.len() <= 1 {
                let first = runs
                    .first()
                    .and_then(|run| run.first())
                    .map_or(0, |(variant, _)| variant.number);
                items.push((
                    first,
                    apply(var(bytes_name(oneof.oneof.encoder_name())), [value()]),
                ));
                continue;
            }
            for run in runs {
                let first = run[0].0.number;
                let nothing = apply(self.reference((BYTES_ENCODE, "sequence")), [list([])]);
                let arms: Vec<(Pattern, Expr)> = run
                    .into_iter()
                    .map(|(variant, member)| self.oneof_member_bytes(variant, member))
                    .chain(std::iter::once((Pattern::Wildcard, nothing)))
                    .collect();
                items.push((first, case(value(), arms)));
            }
        }
        items.sort_by_key(|(number, _)| *number);
        let param = if items.is_empty() {
            Pattern::Wildcard
        } else {
            pvar(ENCODER_ARGUMENT)
        };
        let sequence = self.reference((BYTES_ENCODE, "sequence"));
        let encoder = self.bytes_encoder_type();
        Decl::Value {
            doc: Some(format!(
                "Encodes {} as protobuf binary.",
                docs::a_local(&shape.message.elm_name)
            )),
            name: bytes_name(shape.message.encoder_name()),
            annotation: Type::Function(
                Box::new(ty(shape.message.elm_name.clone(), [])),
                Box::new(encoder),
            ),
            params: vec![param],
            body: apply(
                sequence,
                [list(
                    items.into_iter().map(|(_, item)| item).collect::<Vec<_>>(),
                )],
            ),
        }
    }

    /// `decodeFooBytes : Proto.Binary.Decoder Foo`, `mergeFooBytes` of the
    /// default.
    pub(super) fn message_decoder_bytes(&mut self, shape: &MessageShape) -> Decl {
        let annotation = self.bytes_decoder_type(ty(shape.message.elm_name.clone(), []));
        Decl::Value {
            doc: Some(format!(
                "Decodes {} from protobuf binary.",
                docs::a_local(&shape.message.elm_name)
            )),
            name: bytes_name(shape.message.decoder_name()),
            annotation,
            params: Vec::new(),
            body: apply(
                var(merge_name(shape.message.decoder_name())),
                [var(shape.message.default_name())],
            ),
        }
    }

    /// `mergeFooBytes : Foo -> Proto.Binary.Decoder Foo`: a `Foo` read
    /// into the one given, as protobuf merges a message arriving twice.
    pub(super) fn message_merge_bytes(&mut self, shape: &MessageShape) -> Decl {
        let form = merge_form();
        let mut branches: Vec<(u32, Expr)> = Vec::new();
        let mut reversed: Vec<String> = Vec::new();
        let setter = Setter::new(shape, form);
        let update = |name: &str, value: Expr| setter.update(name, value);
        let wire = || var(WIRE);
        let record = || var(ENCODER_ARGUMENT);
        for &(field, field_shape) in &shape.fields {
            let name = field.elm_name.as_str();
            let current = access(var(ENCODER_ARGUMENT), name);
            let codec = self.field_codec(field, field_shape);
            let step = match field_shape {
                FieldShape::Plain(_) => {
                    let set = lambda([pvar(ITEM)], update(name, var(ITEM)));
                    apply(self.binary("field"), [codec, set, wire(), record()])
                }
                FieldShape::Maybe(_) if matches!(field.ty, TypeRef::Message(_)) => {
                    let just = apply(var(self.core("Just")), [var(ITEM)]);
                    let set = lambda([pvar(ITEM)], update(name, just));
                    apply(
                        self.binary("fieldInto"),
                        [codec, current, set, wire(), record()],
                    )
                }
                FieldShape::Maybe(_) | FieldShape::Json => {
                    let just = apply(var(self.core("Just")), [var(ITEM)]);
                    let set = lambda([pvar(ITEM)], update(name, just));
                    apply(self.binary("field"), [codec, set, wire(), record()])
                }
                FieldShape::List(_) => {
                    reversed.push(name.to_owned());
                    let set = lambda([pvar(ITEM)], update(name, var(ITEM)));
                    apply(
                        self.binary("repeated"),
                        [codec, set, current, wire(), record()],
                    )
                }
                FieldShape::Dict(..) => {
                    let Cardinality::Map(key) = field.cardinality else {
                        unreachable!("a Dict field is a map")
                    };
                    let key = self.binary(key_codec(key));
                    let insert = self.reference((super::CORE_DICT, "insert"));
                    let inserted = apply(insert, [var(KEY), var(ITEM), current]);
                    let set = lambda([pvar(KEY), pvar(ITEM)], update(name, inserted));
                    apply(self.binary("mapEntry"), [key, codec, set, wire(), record()])
                }
                FieldShape::BoolMap(_) => {
                    reversed.push(name.to_owned());
                    let key = self.binary("bool");
                    let insert = self.binary("insertBool");
                    let inserted = apply(insert, [var(KEY), var(ITEM), current]);
                    let set = lambda([pvar(KEY), pvar(ITEM)], update(name, inserted));
                    apply(self.binary("mapEntry"), [key, codec, set, wire(), record()])
                }
            };
            branches.push((field.number, step));
        }
        for oneof in &shape.oneofs {
            let name = oneof.oneof.elm_field_name.as_str();
            for &(variant, value) in &oneof.variants {
                let holding = field_holding(variant.jstype, self.holding);
                let codec = self.binary_codec(&variant.ty, holding, None);
                let set = if matches!(value, ValueShape::Zeroed(Zeroed::Empty | Zeroed::Null)) {
                    lambda(
                        [Pattern::Wildcard],
                        update(name, var(variant.elm_ctor.clone())),
                    )
                } else {
                    let member = apply(var(variant.elm_ctor.clone()), [var(ITEM)]);
                    lambda([pvar(ITEM)], update(name, member))
                };
                let step = if matches!(variant.ty, TypeRef::Message(_)) {
                    // The member read before, when it is this one.
                    let just = apply(var(self.core("Just")), [var(ONEOF_MEMBER)]);
                    let nothing = var(self.core("Nothing"));
                    let existing = case(
                        access(var(ENCODER_ARGUMENT), name),
                        [
                            (pctor(variant.elm_ctor.clone(), [pvar(ONEOF_MEMBER)]), just),
                            (Pattern::Wildcard, nothing),
                        ],
                    );
                    apply(
                        self.binary("fieldInto"),
                        [codec, existing, set, wire(), record()],
                    )
                } else {
                    apply(self.binary("field"), [codec, set, wire(), record()])
                };
                branches.push((variant.number, step));
            }
        }
        branches.sort_by_key(|(number, _)| *number);
        let skip = apply(self.binary("skip"), [wire(), var(ENCODER_ARGUMENT)]);
        let step = if branches.is_empty() {
            lambda(
                [Pattern::Wildcard, pvar(WIRE), pvar(ENCODER_ARGUMENT)],
                skip,
            )
        } else {
            let arms = branches
                .into_iter()
                .map(|(number, step)| (Pattern::Int(number.into()), step))
                .chain([(Pattern::Wildcard, skip)]);
            lambda(
                [pvar(NUMBER), pvar(WIRE), pvar(ENCODER_ARGUMENT)],
                case(var(NUMBER), arms),
            )
        };
        let finish = if reversed.is_empty() {
            var("identity")
        } else {
            let reverse = qualified("List", "reverse");
            let fields = reversed
                .into_iter()
                .map(|name| {
                    let current = access(var(ENCODER_ARGUMENT), name.clone());
                    (name, apply(reverse.clone(), [current]))
                })
                .collect();
            lambda([pvar(ENCODER_ARGUMENT)], setter.update_all(fields))
        };
        let annotation = self.bytes_merge_type(ty(shape.message.elm_name.clone(), []));
        let has_fields = !shape.fields.is_empty() || !shape.oneofs.is_empty();
        let body = match form {
            MergeForm::Staged | MergeForm::Reentrant if has_fields => {
                self.staged_merge(shape, form, step, finish)
            }
            _ => {
                let merge = self.binary("merge");
                apply(
                    merge,
                    [string(shape.message.proto_full_name.clone()), step, finish],
                )
            }
        };
        Decl::Value {
            doc: Some(format!(
                "Decodes {} from protobuf binary into the one given, as protobuf merges a message that arrives twice.",
                docs::a_local(&shape.message.elm_name)
            )),
            name: merge_name(shape.message.decoder_name()),
            annotation,
            params: Vec::new(),
            body,
        }
    }

    /// The body of a merge read in field-number order:
    /// `Proto.Binary.mergeStaged` (with the update form's step) or
    /// `Proto.Binary.mergeReentrant` of the message's name, the numbers it
    /// knows, its finishing function, a builder of the record from every
    /// field's value and the record the oneofs are in, and a stage per field
    /// and oneof member in field-number order. Each oneof's reader and
    /// member test are bound once, in a `let`, since every member's stage
    /// takes them.
    fn staged_merge(
        &mut self,
        shape: &MessageShape,
        form: MergeForm,
        step: Expr,
        finish: Expr,
    ) -> Expr {
        let wire = || var(WIRE);
        let slot = || var(ENCODER_ARGUMENT);
        let identity = || var("identity");
        let mut numbers: Vec<u32> = Vec::new();
        // (number, stage, the builder's parameter for a field stage)
        let mut entries: Vec<(u32, Expr, Option<String>)> = Vec::new();
        let mut bindings: Vec<LetBinding> = Vec::new();
        for &(field, field_shape) in &shape.fields {
            numbers.push(field.number);
            let name = field.elm_name.as_str();
            let codec = self.field_codec(field, field_shape);
            let just = || var("Just");
            let read = match field_shape {
                FieldShape::Plain(_) => apply(self.binary("field"), [codec, identity()]),
                FieldShape::Maybe(_) if matches!(field.ty, TypeRef::Message(_)) => {
                    let _ = self.core("Just");
                    lambda(
                        [pvar(WIRE), pvar(ENCODER_ARGUMENT)],
                        apply(
                            self.binary("fieldInto"),
                            [codec, slot(), just(), wire(), slot()],
                        ),
                    )
                }
                FieldShape::Maybe(_) | FieldShape::Json => {
                    let _ = self.core("Just");
                    apply(self.binary("field"), [codec, just()])
                }
                FieldShape::List(_) => lambda(
                    [pvar(WIRE), pvar(ENCODER_ARGUMENT)],
                    apply(
                        self.binary("repeated"),
                        [codec, identity(), slot(), wire(), slot()],
                    ),
                ),
                FieldShape::Dict(..) => {
                    let Cardinality::Map(key) = field.cardinality else {
                        unreachable!("a Dict field is a map")
                    };
                    let key = self.binary(key_codec(key));
                    let insert = self.reference((super::CORE_DICT, "insert"));
                    let inserted = apply(insert, [var(KEY), var(ITEM), slot()]);
                    let set = lambda([pvar(KEY), pvar(ITEM)], inserted);
                    lambda(
                        [pvar(WIRE), pvar(ENCODER_ARGUMENT)],
                        apply(self.binary("mapEntry"), [key, codec, set, wire(), slot()]),
                    )
                }
                FieldShape::BoolMap(_) => {
                    let key = self.binary("bool");
                    let insert = self.binary("insertBool");
                    let inserted = apply(insert, [var(KEY), var(ITEM), slot()]);
                    let set = lambda([pvar(KEY), pvar(ITEM)], inserted);
                    lambda(
                        [pvar(WIRE), pvar(ENCODER_ARGUMENT)],
                        apply(self.binary("mapEntry"), [key, codec, set, wire(), slot()]),
                    )
                }
            };
            let stage = apply(
                self.binary("stage"),
                [
                    int(field.number.into()),
                    read,
                    Expr::Accessor(name.to_owned()),
                ],
            );
            entries.push((field.number, stage, Some(name.to_owned())));
        }
        for oneof in &shape.oneofs {
            let name = oneof.oneof.elm_field_name.as_str();
            let reader = format!("read_{name}");
            let member_test = format!("accepts_{name}");
            let mut arms: Vec<(Pattern, Expr)> = Vec::new();
            let mut member_numbers: Vec<u32> = Vec::new();
            for &(variant, value) in &oneof.variants {
                member_numbers.push(variant.number);
                let holding = field_holding(variant.jstype, self.holding);
                let codec = self.binary_codec(&variant.ty, holding, None);
                let set = if matches!(value, ValueShape::Zeroed(Zeroed::Empty | Zeroed::Null)) {
                    lambda([Pattern::Wildcard], var(variant.elm_ctor.clone()))
                } else {
                    var(variant.elm_ctor.clone())
                };
                let read = if matches!(variant.ty, TypeRef::Message(_)) {
                    let just = apply(var(self.core("Just")), [var(ONEOF_MEMBER)]);
                    let nothing = var(self.core("Nothing"));
                    let existing = case(
                        slot(),
                        [
                            (pctor(variant.elm_ctor.clone(), [pvar(ONEOF_MEMBER)]), just),
                            (Pattern::Wildcard, nothing),
                        ],
                    );
                    apply(
                        self.binary("fieldInto"),
                        [codec, existing, set, wire(), slot()],
                    )
                } else {
                    apply(self.binary("field"), [codec, set, wire(), slot()])
                };
                arms.push((Pattern::Int(variant.number.into()), read));
            }
            arms.push((
                Pattern::Wildcard,
                apply(self.binary("skip"), [wire(), slot()]),
            ));
            numbers.extend(member_numbers.iter().copied());
            bindings.push(LetBinding {
                name: reader.clone(),
                annotation: None,
                params: vec![pvar(NUMBER), pvar(WIRE), pvar(ENCODER_ARGUMENT)],
                body: case(var(NUMBER), arms),
            });
            let mut test_numbers = member_numbers.clone();
            test_numbers.sort_unstable();
            let test = test_numbers
                .iter()
                .map(|&n| binop(BinOp::Eq, var(NUMBER), int(n.into())))
                .reduce(|a, b| binop(BinOp::Or, a, b))
                .expect("a oneof has members");
            bindings.push(LetBinding {
                name: member_test.clone(),
                annotation: None,
                params: vec![pvar(NUMBER)],
                body: test,
            });
            let set = lambda(
                [pvar(ITEM), pvar(ENCODER_ARGUMENT)],
                Expr::RecordUpdate {
                    record: ENCODER_ARGUMENT.to_owned(),
                    fields: vec![(name.to_owned(), var(ITEM))],
                },
            );
            for &n in &member_numbers {
                let stage = apply(
                    self.binary("stageOneof"),
                    [
                        int(n.into()),
                        var(member_test.clone()),
                        var(reader.clone()),
                        Expr::Accessor(name.to_owned()),
                        set.clone(),
                    ],
                );
                entries.push((n, stage, None));
            }
        }
        entries.sort_by_key(|(number, ..)| *number);
        // The builder: a parameter per field stage, in stage order, then the
        // record the oneofs are read from.
        let mut params: Vec<Pattern> = Vec::new();
        let mut field_param: std::collections::HashMap<String, String> =
            std::collections::HashMap::new();
        for (index, (_, _, field)) in entries.iter().enumerate() {
            if let Some(name) = field {
                let param = format!("v_{}", index + 1);
                params.push(pvar(param.clone()));
                field_param.insert(name.clone(), param);
            }
        }
        let has_oneofs = !shape.oneofs.is_empty();
        params.push(if has_oneofs {
            pvar(ENCODER_ARGUMENT)
        } else {
            Pattern::Wildcard
        });
        let fields: Vec<(String, Expr)> = shape
            .record()
            .into_iter()
            .map(|field| match field {
                RecordField::Field(field, _) => (
                    field.elm_name.clone(),
                    var(field_param[&field.elm_name].clone()),
                ),
                RecordField::Oneof(oneof) => (
                    oneof.oneof.elm_field_name.clone(),
                    access(var(ENCODER_ARGUMENT), oneof.oneof.elm_field_name.clone()),
                ),
            })
            .collect();
        let build = lambda(params, record(fields));
        let pipeline = entries
            .into_iter()
            .fold(self.binary("stages"), |acc, (_, stage, _)| pipe(acc, stage));
        let name = string(shape.message.proto_full_name.clone());
        let known = known_numbers(numbers);
        let body = match form {
            MergeForm::Staged => apply(
                self.binary("mergeStaged"),
                [name, known, step, finish, build, pipeline],
            ),
            _ => apply(
                self.binary("mergeReentrant"),
                [name, known, finish, build, pipeline],
            ),
        };
        if bindings.is_empty() {
            body
        } else {
            let_in(bindings, body)
        }
    }

    /// The `case` arm that writes a oneof's member: its field, written
    /// whatever its value.
    fn oneof_member_bytes(&mut self, variant: &OneofVariant, value: ValueShape) -> (Pattern, Expr) {
        let holding = field_holding(variant.jstype, self.holding);
        let codec = self.binary_codec(&variant.ty, holding, None);
        let number = int(variant.number.into());
        let present = self.binary("present");
        if matches!(value, ValueShape::Zeroed(Zeroed::Empty | Zeroed::Null)) {
            (
                pctor(variant.elm_ctor.clone(), []),
                apply(present, [codec, number, Expr::Unit]),
            )
        } else {
            (
                pctor(variant.elm_ctor.clone(), [pvar(ONEOF_MEMBER)]),
                apply(present, [codec, number, var(ONEOF_MEMBER)]),
            )
        }
    }

    /// `encodeFooKindBytes : FooKind -> Bytes.Encode.Encoder`: the set
    /// member, written whatever its value, or nothing when unset.
    pub(super) fn oneof_encoder_bytes(&mut self, shape: &OneofShape) -> Decl {
        let sequence = self.reference((BYTES_ENCODE, "sequence"));
        let unset = (
            pctor(shape.oneof.unset_ctor.clone(), []),
            apply(sequence, [list([])]),
        );
        let members: Vec<(Pattern, Expr)> = shape
            .variants
            .iter()
            .map(|&(variant, value)| self.oneof_member_bytes(variant, value))
            .collect();
        let encoder = self.bytes_encoder_type();
        Decl::Value {
            doc: Some(format!(
                "Encodes {} as protobuf binary: its set member's field.",
                docs::a_local(&shape.oneof.elm_type_name)
            )),
            name: bytes_name(shape.oneof.encoder_name()),
            annotation: Type::Function(
                Box::new(ty(shape.oneof.elm_type_name.clone(), [])),
                Box::new(encoder),
            ),
            params: vec![pvar(ENCODER_ARGUMENT)],
            body: case(var(ENCODER_ARGUMENT), std::iter::once(unset).chain(members)),
        }
    }

    /// `encodeNode_Bytes (Node_ value) = encodeNodeBytes value`.
    pub(super) fn wrapper_encoder_bytes(&mut self, message: &Message, wrapper: &Wrapper) -> Decl {
        let encoder = self.bytes_encoder_type();
        Decl::Value {
            doc: Some(format!(
                "Encodes {} as protobuf binary.",
                docs::a_local(&wrapper.elm_name)
            )),
            name: bytes_name(wrapper.encoder_name()),
            annotation: Type::Function(
                Box::new(ty(wrapper.elm_name.clone(), [])),
                Box::new(encoder),
            ),
            params: vec![pctor(wrapper.elm_name.clone(), [pvar(ENCODER_ARGUMENT)])],
            body: apply(
                var(bytes_name(message.encoder_name())),
                [var(ENCODER_ARGUMENT)],
            ),
        }
    }

    /// `mergeNode_Bytes (Node_ value) = Proto.Binary.map Node_
    /// (mergeNodeBytes value)`: a function, so the merges of a cycle refer
    /// to each other through functions only.
    pub(super) fn wrapper_decoder_bytes(&mut self, message: &Message, wrapper: &Wrapper) -> Decl {
        let map = self.binary("map");
        let annotation = self.bytes_merge_type(ty(wrapper.elm_name.clone(), []));
        Decl::Value {
            doc: Some(format!(
                "Decodes {} from protobuf binary into the one given.",
                docs::a_local(&wrapper.elm_name)
            )),
            name: merge_name(wrapper.decoder_name()),
            annotation,
            params: vec![pctor(wrapper.elm_name.clone(), [pvar(ENCODER_ARGUMENT)])],
            body: apply(
                map,
                [
                    var(wrapper.elm_name.clone()),
                    apply(
                        var(merge_name(message.decoder_name())),
                        [var(ENCODER_ARGUMENT)],
                    ),
                ],
            ),
        }
    }

    /// `encodeStatusBytes : Status -> Int`: each constructor's number, the
    /// first declared for an aliased number.
    pub(super) fn enum_encoder_bytes(&mut self, enumeration: &Enum) -> Decl {
        let branches: Vec<(Pattern, Expr)> = enumeration
            .values()
            .map(|value| (pctor(value.elm_ctor.clone(), []), int(value.number.into())))
            .collect();
        Decl::Value {
            doc: Some(format!(
                "The number protobuf binary writes {} as.",
                docs::a_local(&enumeration.elm_name)
            )),
            name: bytes_name(enumeration.encoder_name()),
            annotation: Type::Function(
                Box::new(ty(enumeration.elm_name.clone(), [])),
                Box::new(ty(self.core("Int"), [])),
            ),
            params: vec![pvar(ENCODER_ARGUMENT)],
            body: case(var(ENCODER_ARGUMENT), branches),
        }
    }

    /// `decodeStatusBytes : Int -> Status`: an unknown number reads as the
    /// zero value, as the JSON decoder reads one. Elm has no negative
    /// literal patterns, so negative numbers are tested in the fallback.
    pub(super) fn enum_decoder_bytes(&mut self, enumeration: &Enum) -> Decl {
        let zero = var(enumeration.zero().elm_ctor.clone());
        let negatives = enumeration
            .values()
            .filter(|value| value.number < 0)
            .collect::<Vec<_>>();
        let fallback = negatives.into_iter().rev().fold(zero, |otherwise, value| {
            if_then_else(
                binop(BinOp::Eq, var(NUMBER), int(value.number.into())),
                var(value.elm_ctor.clone()),
                otherwise,
            )
        });
        let arms: Vec<(Pattern, Expr)> = enumeration
            .values()
            .filter(|value| value.number > 0)
            .map(|value| {
                (
                    Pattern::Int(value.number as u64),
                    var(value.elm_ctor.clone()),
                )
            })
            .chain([(Pattern::Wildcard, fallback)])
            .collect();
        Decl::Value {
            doc: Some(format!(
                "{} from the number protobuf binary carries.",
                docs::a_local_capital(&enumeration.elm_name)
            )),
            name: bytes_name(enumeration.decoder_name()),
            annotation: Type::Function(
                Box::new(ty(self.core("Int"), [])),
                Box::new(ty(enumeration.elm_name.clone(), [])),
            ),
            params: vec![pvar(NUMBER)],
            body: case(var(NUMBER), arms),
        }
    }

    /// The binary encoder of a method's request type: the generated
    /// `encodeFooBytes`, or a well-known type's runtime codec's.
    pub(super) fn request_encoder_bytes(&mut self, ty: &TypeRef) -> Expr {
        match ty {
            TypeRef::Message(name) => {
                self.generated_value(&name.module, bytes_name(name.encoder_name()))
            }
            TypeRef::WellKnown(known) => {
                let codec = self.binary(well_known_codec(*known, self.holding));
                apply(self.binary("messageEncoder"), [codec])
            }
            TypeRef::Scalar(_) | TypeRef::Enum { .. } => {
                unreachable!("a method type that is not a message")
            }
        }
    }

    /// The binary decoder of a method's response type, as
    /// [`Self::request_encoder_bytes`] finds the encoder.
    pub(super) fn response_decoder_bytes(&mut self, ty: &TypeRef) -> Expr {
        match ty {
            TypeRef::Message(name) => {
                self.generated_value(&name.module, bytes_name(name.decoder_name()))
            }
            TypeRef::WellKnown(known) => {
                let codec = self.binary(well_known_codec(*known, self.holding));
                apply(self.binary("messageDecoder"), [codec])
            }
            TypeRef::Scalar(_) | TypeRef::Enum { .. } => {
                unreachable!("a method type that is not a message")
            }
        }
    }
}
