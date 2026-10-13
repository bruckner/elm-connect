//! The typed intermediate representation between protobuf descriptors and
//! Elm: one [`Package`] per proto package, holding the messages and enums
//! the Elm module for that package will define.
//!
//! The IR holds the type layer (messages, enums, oneofs) and the method
//! layer (services, their methods, and each method's `google.api.http`
//! rule). It keeps proto kinds (scalar kinds, map key kinds, well-known types)
//! and leaves their Elm spelling to the emitter, but every Elm *name* is
//! decided here, by [`crate::naming`], so the emitter never invents one.
//!
//! Invariants a built IR upholds:
//!
//! - Every Elm name is a valid Elm identifier, and names that share an Elm
//!   namespace are unique: record fields within a message, types within a
//!   module, constructors within a module, method values within a service,
//!   and module names across the build (every package's and every
//!   service's). A clash is a diagnostic from [`build`], never a silent
//!   rename.
//! - Nested messages and enums are flattened into their package, their Elm
//!   names prefixed by the enclosing names (`Outer.Inner` becomes
//!   `OuterInner`).
//! - Proto3 `optional` fields are [`Cardinality::Optional`] fields, never
//!   [`Oneof`]s; only real oneofs appear as oneofs.
//! - Every cycle of message references is marked: each field that closes
//!   a cycle of record fields is [`Field::cyclic`], its target has a
//!   [`Message::wrapper`], and each oneof member that closes any other
//!   cycle is [`OneofVariant::cyclic`]. Cycles never cross packages, since
//!   packages that refer to each other in a cycle are a diagnostic.
//! - Every [`TypeName`] refers to a type in a package of the same build,
//!   and the packages' references to each other form no cycle.
//! - `google.protobuf` is never a package; its supported types appear as
//!   [`TypeRef::WellKnown`].

mod build;
mod graph;

use std::fmt;

pub use build::build;

/// Everything generated from one proto package, across all of its files:
/// the content of one Elm module.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Package {
    /// The proto package name, such as `notes.v1`.
    pub proto_name: String,
    /// The Elm module the package becomes, such as `Notes.V1`.
    pub module: ModuleName,
    /// The generated files that declare this package, sorted by name.
    pub files: Vec<String>,
    /// Every message of the package, nested ones included, in declaration
    /// order (files by name, an enclosing message before its nested ones).
    /// Map entry messages are not messages here; they are
    /// [`Cardinality::Map`] fields.
    pub messages: Vec<Message>,
    /// Every enum of the package, nested ones included, in the same order.
    pub enums: Vec<Enum>,
    /// Every service of the package, in declaration order (files by name).
    pub services: Vec<Service>,
}

/// A service: a group of methods, and an Elm module of its own holding
/// one value per method. Its full name is part of each method's Connect
/// path.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Service {
    /// The fully-qualified proto name, such as `notes.v1.Notes`.
    pub proto_full_name: String,
    /// The Elm module of its methods, inside its package's, such as
    /// `Notes.V1.Notes`. No other service's or package's module has this
    /// name.
    pub module: ModuleName,
    /// The methods, in declaration order. Streaming methods are
    /// diagnostics, so every method here is unary.
    pub methods: Vec<Method>,
}

/// A unary RPC method: one Elm value in its service's module (design §4).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Method {
    /// The proto method name, such as `GetNote`; the last segment of its
    /// Connect path.
    pub proto_name: String,
    /// The Elm value of its call, such as `getNote`, unique among the
    /// methods of its service.
    pub elm_name: String,
    /// The request type: a [`TypeRef::Message`] or a
    /// [`TypeRef::WellKnown`] message type, never a scalar or an enum.
    pub input: TypeRef,
    /// The response type, under the same rule as [`Method::input`].
    pub output: TypeRef,
    /// Whether the method declares `idempotency_level = NO_SIDE_EFFECTS`,
    /// which lets Connect call it with GET.
    pub idempotent: bool,
    /// The method's `google.api.http` rule, if it has one.
    pub http: Option<HttpRule>,
    /// One route per HTTP binding: the rule's own first, then each
    /// additional binding's. Empty without a rule.
    pub routes: Vec<crate::route::Route>,
}

/// A `google.api.http` rule as written: the verb and path template, the
/// body and response body field names, and the additional bindings.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HttpRule {
    /// The HTTP method.
    pub verb: HttpVerb,
    /// The path template, such as `/v1/{name=notes/*}`.
    pub template: String,
    /// The `body` field: empty for none, `*` for every field not in the
    /// path, or a top-level field name.
    pub body: String,
    /// The `response_body` field: empty for the whole response, or a
    /// top-level field name of the response.
    pub response_body: String,
    /// The `additional_bindings`, each with no bindings of its own.
    pub additional_bindings: Vec<HttpRule>,
}

/// The HTTP method of a rule.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum HttpVerb {
    /// `get`
    Get,
    /// `put`
    Put,
    /// `post`
    Post,
    /// `delete`
    Delete,
    /// `patch`
    Patch,
    /// `custom`, with its `kind`, such as `HEAD`.
    Custom(String),
}

impl HttpVerb {
    /// The method as sent on the wire: `GET`, or a custom kind as written.
    pub fn as_str(&self) -> &str {
        match self {
            HttpVerb::Get => "GET",
            HttpVerb::Put => "PUT",
            HttpVerb::Post => "POST",
            HttpVerb::Delete => "DELETE",
            HttpVerb::Patch => "PATCH",
            HttpVerb::Custom(kind) => kind,
        }
    }
}

/// An Elm module name, such as `Notes.V1`.
///
/// Every segment is a valid Elm module segment: an ASCII uppercase letter
/// followed by ASCII letters, digits or underscores; [`ModuleName::new`]
/// checks it, and [`crate::naming::module_name`] derives one from a proto
/// package.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct ModuleName {
    segments: Vec<String>,
}

impl ModuleName {
    /// A module name from its segments, outermost first, or `None` if
    /// there are none or one is not a valid Elm module segment.
    pub fn new(segments: Vec<String>) -> Option<Self> {
        let valid = |segment: &String| {
            let mut chars = segment.chars();
            chars.next().is_some_and(|c| c.is_ascii_uppercase())
                && chars.all(|c| c.is_ascii_alphanumeric() || c == '_')
        };
        (!segments.is_empty() && segments.iter().all(valid)).then_some(ModuleName { segments })
    }

    /// The dot-separated segments, outermost first.
    pub fn segments(&self) -> &[String] {
        &self.segments
    }
}

impl fmt::Display for ModuleName {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.segments.join("."))
    }
}

/// A reference to a generated Elm type: the module that defines it and its
/// unqualified name. The emitter qualifies it when `module` is not the
/// module being emitted.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct TypeName {
    /// The module that defines the type.
    pub module: ModuleName,
    /// The type's name within that module, such as `OuterInner`.
    pub name: String,
}

impl TypeName {
    /// The Elm name of the type's JSON encoder, such as `encodeNote`.
    pub fn encoder_name(&self) -> String {
        crate::naming::encoder_name(&self.name)
    }

    /// The Elm name of the type's JSON decoder, such as `decodeNote`.
    pub fn decoder_name(&self) -> String {
        crate::naming::decoder_name(&self.name)
    }
}

/// A message: one Elm record type alias.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Message {
    /// The fully-qualified proto name, such as `notes.v1.Outer.Inner`.
    pub proto_full_name: String,
    /// The Elm type name, such as `OuterInner`. A record alias also defines
    /// a constructor of this name, which counts against the module's
    /// constructor namespace.
    pub elm_name: String,
    /// The fields outside any real oneof, in declaration order. Proto3
    /// `optional` fields are here, as [`Cardinality::Optional`].
    pub fields: Vec<Field>,
    /// The real oneofs, in declaration order; each records its
    /// [`Oneof::position`] among `fields`.
    pub oneofs: Vec<Oneof>,
    /// The wrapper of a recursive message: `Some` when the message reaches itself through singular, optional,
    /// repeated or map-value message fields, directly or through other
    /// messages. Elm rejects a recursive type alias, so the fields that
    /// close such a cycle ([`Field::cyclic`]) hold the message wrapped in
    /// a one-constructor custom type (design §3.2).
    /// References through a oneof do not count: a oneof is a custom type,
    /// which already breaks an Elm alias cycle.
    pub wrapper: Option<Wrapper>,
}

/// The wrapper of a recursive message: `type Node_ = Node_ Node`, a custom
/// type whose one constructor has the type's name.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Wrapper {
    /// The Elm name of the type and of its constructor, such as `Node_`.
    pub elm_name: String,
}

impl Wrapper {
    /// The Elm name of the wrapper's JSON encoder, such as `encodeNode_`.
    pub fn encoder_name(&self) -> String {
        crate::naming::encoder_name(&self.elm_name)
    }

    /// The Elm name of the wrapper's JSON decoder, such as `decodeNode_`.
    pub fn decoder_name(&self) -> String {
        crate::naming::decoder_name(&self.elm_name)
    }
}

impl Message {
    /// The Elm name of the message's JSON encoder, such as `encodeNote`.
    pub fn encoder_name(&self) -> String {
        crate::naming::encoder_name(&self.elm_name)
    }

    /// The Elm name of the message's JSON decoder, such as `decodeNote`.
    pub fn decoder_name(&self) -> String {
        crate::naming::decoder_name(&self.elm_name)
    }

    /// The Elm name of the message's default value, such as
    /// `defaultNote`.
    pub fn default_name(&self) -> String {
        crate::naming::default_name(&self.elm_name)
    }
}

/// A message field outside any real oneof: one Elm record field.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Field {
    /// The proto field name, such as `display_name`.
    pub proto_name: String,
    /// The JSON name on the wire, such as `displayName` (proto's
    /// `json_name`, defaulted or explicit). It never shapes Elm names.
    pub json_name: String,
    /// The field number.
    pub number: u32,
    /// The Elm record field name, such as `displayName`; reserved words
    /// carry a trailing underscore (`type_`).
    pub elm_name: String,
    /// How many values the field holds.
    pub cardinality: Cardinality,
    /// The type of each value: the element type of a repeated field, the
    /// value type of a map.
    pub ty: TypeRef,
    /// Whether the field closes a cycle of record fields: its message type
    /// reaches back to the message holding it through fields alone. Such a
    /// field holds that type's [`Message::wrapper`] rather than its record,
    /// and its values decode lazily.
    pub cyclic: bool,
    /// The field's `jstype` option; [`JsType::Normal`] unless the field is
    /// a 64-bit integer that sets it.
    pub jstype: JsType,
}

/// The standard field option `jstype` of a 64-bit integer field, which
/// overrides the generator's `int64` option for that field (design §3.4).
/// Only fields whose values are 64-bit integer scalars carry anything but
/// [`JsType::Normal`]; the option is ignored elsewhere.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum JsType {
    /// No override (`JS_NORMAL`, or unset): the `int64` option decides.
    #[default]
    Normal,
    /// `JS_STRING`: the field is a decimal `String`.
    String,
    /// `JS_NUMBER`: the field is an `Int`, range-checked when decoded.
    Number,
}

/// How many values a field holds. The value type is the field's
/// [`Field::ty`].
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Cardinality {
    /// A plain proto3 field. Scalars and enums read as their zero value
    /// when absent; message-typed fields are still `Singular` here, and
    /// the emitter gives them `Maybe`.
    Singular,
    /// A proto3 `optional` field, with explicit presence.
    Optional,
    /// A `repeated` field.
    Repeated,
    /// A `map<K, V>` field, with this key kind; `V` is [`Field::ty`].
    Map(MapKey),
}

/// The type of a field's values.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum TypeRef {
    /// A proto scalar.
    Scalar(ScalarKind),
    /// A generated message.
    Message(TypeName),
    /// A generated enum.
    Enum {
        /// The enum's type.
        name: TypeName,
        /// The constructor of its zero value, which a field of the enum
        /// reads as when absent: [`Enum::zero`]'s, in the enum's module.
        zero_ctor: String,
    },
    /// A supported `google.protobuf` type.
    WellKnown(WellKnown),
}

/// The fifteen proto scalar types, kept as proto spells them; the Elm
/// mapping is the emitter's (design §3.4).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ScalarKind {
    /// `double`
    Double,
    /// `float`
    Float,
    /// `int32`
    Int32,
    /// `int64`
    Int64,
    /// `uint32`
    UInt32,
    /// `uint64`
    UInt64,
    /// `sint32`
    SInt32,
    /// `sint64`
    SInt64,
    /// `fixed32`
    Fixed32,
    /// `fixed64`
    Fixed64,
    /// `sfixed32`
    SFixed32,
    /// `sfixed64`
    SFixed64,
    /// `bool`
    Bool,
    /// `string`
    String,
    /// `bytes`
    Bytes,
}

/// The key kinds of a `map<K, V>`: every key proto allows, which is every
/// scalar but the floating-point ones and `bytes`. The emitter maps these
/// onto a `Dict` keyed by `String` or `Int`, or, for `bool`, which is not
/// `comparable` in Elm, an association list (design §3.2).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum MapKey {
    /// `int32`
    Int32,
    /// `int64`
    Int64,
    /// `uint32`
    UInt32,
    /// `uint64`
    UInt64,
    /// `sint32`
    SInt32,
    /// `sint64`
    SInt64,
    /// `fixed32`
    Fixed32,
    /// `fixed64`
    Fixed64,
    /// `sfixed32`
    SFixed32,
    /// `sfixed64`
    SFixed64,
    /// `string`
    String,
    /// `bool`
    Bool,
}

/// The `google.protobuf` types elm-connect maps (design §3.5). `Any` and
/// every other `google.protobuf` type are diagnostics instead.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum WellKnown {
    /// `google.protobuf.Timestamp`
    Timestamp,
    /// `google.protobuf.Duration`
    Duration,
    /// `google.protobuf.FieldMask`
    FieldMask,
    /// `google.protobuf.Empty`
    Empty,
    /// `google.protobuf.Struct`
    Struct,
    /// `google.protobuf.Value`
    Value,
    /// `google.protobuf.ListValue`
    ListValue,
    /// `google.protobuf.DoubleValue`
    DoubleValue,
    /// `google.protobuf.FloatValue`
    FloatValue,
    /// `google.protobuf.Int64Value`
    Int64Value,
    /// `google.protobuf.UInt64Value`
    UInt64Value,
    /// `google.protobuf.Int32Value`
    Int32Value,
    /// `google.protobuf.UInt32Value`
    UInt32Value,
    /// `google.protobuf.BoolValue`
    BoolValue,
    /// `google.protobuf.StringValue`
    StringValue,
    /// `google.protobuf.BytesValue`
    BytesValue,
}

impl WellKnown {
    /// The well-known type with this unqualified name in
    /// `google.protobuf`, if elm-connect supports it.
    pub fn from_name(name: &str) -> Option<Self> {
        Some(match name {
            "Timestamp" => WellKnown::Timestamp,
            "Duration" => WellKnown::Duration,
            "FieldMask" => WellKnown::FieldMask,
            "Empty" => WellKnown::Empty,
            "Struct" => WellKnown::Struct,
            "Value" => WellKnown::Value,
            "ListValue" => WellKnown::ListValue,
            "DoubleValue" => WellKnown::DoubleValue,
            "FloatValue" => WellKnown::FloatValue,
            "Int64Value" => WellKnown::Int64Value,
            "UInt64Value" => WellKnown::UInt64Value,
            "Int32Value" => WellKnown::Int32Value,
            "UInt32Value" => WellKnown::UInt32Value,
            "BoolValue" => WellKnown::BoolValue,
            "StringValue" => WellKnown::StringValue,
            "BytesValue" => WellKnown::BytesValue,
            _ => return None,
        })
    }
}

/// A real (not synthetic) oneof: an Elm custom type whose unset case is a
/// constructor of the type itself, held in one record field of the message
/// (design §3.6).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Oneof {
    /// The proto oneof name, such as `kind`.
    pub proto_name: String,
    /// The record field of the message that holds the oneof, such as
    /// `kind`. It shares the message's field namespace.
    pub elm_field_name: String,
    /// The Elm custom type, such as `NoteEventKind`.
    pub elm_type_name: String,
    /// The constructor for the unset case, such as `NoteEventKindUnset`.
    pub unset_ctor: String,
    /// Where the oneof sits among the message's record fields: the number
    /// of [`Message::fields`] declared before its first member. Oneofs
    /// with the same position keep their declaration order.
    pub position: usize,
    /// One constructor per member field, in declaration order.
    pub variants: Vec<OneofVariant>,
}

impl Oneof {
    /// The Elm name of the oneof's JSON encoder, such as
    /// `encodeNoteEventKind`.
    pub fn encoder_name(&self) -> String {
        crate::naming::encoder_name(&self.elm_type_name)
    }

    /// The Elm name of the oneof's JSON decoder, such as
    /// `decodeNoteEventKind`.
    pub fn decoder_name(&self) -> String {
        crate::naming::decoder_name(&self.elm_type_name)
    }
}

/// One member field of a oneof: one constructor of the oneof's custom type,
/// carrying the field's value. Oneof members are always single values.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OneofVariant {
    /// The proto field name, such as `created`.
    pub proto_name: String,
    /// The JSON name on the wire.
    pub json_name: String,
    /// The field number.
    pub number: u32,
    /// The constructor, such as `NoteEventKindCreated`.
    pub elm_ctor: String,
    /// The type of the value the constructor carries.
    pub ty: TypeRef,
    /// Whether the member closes a cycle: its message type reaches back to
    /// the message holding the oneof, through fields or oneof members. The
    /// types need nothing (a oneof is a custom type), but the decoders
    /// would define each other directly, so this member decodes lazily.
    pub cyclic: bool,
    /// The member's `jstype` option, as for [`Field::jstype`].
    pub jstype: JsType,
}

/// An enum: one Elm custom type with a constructor per number.
///
/// Proto3 requires the first value to be number 0; it is the value unknown
/// numbers decode to (design §3.3), so it is held apart as [`Enum::zero`].
/// With `allow_alias`, the values sharing a number are one [`EnumValue`],
/// named for the first declared, holding the others as aliases.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Enum {
    /// The fully-qualified proto name, such as `notes.v1.Status`.
    pub proto_full_name: String,
    /// The proto name within its package, such as `Status` or
    /// `Note.Visibility`, which a decoding error names.
    pub proto_name: String,
    /// The Elm type name, such as `Status`.
    pub elm_name: String,
    zero: EnumValue,
    rest: Vec<EnumValue>,
}

impl Enum {
    /// An enum from its zero value and the values after it, or `None` if
    /// `zero`'s number is not 0.
    pub fn new(
        proto_full_name: String,
        proto_name: String,
        elm_name: String,
        zero: EnumValue,
        rest: Vec<EnumValue>,
    ) -> Option<Self> {
        (zero.number == 0).then_some(Enum {
            proto_full_name,
            proto_name,
            elm_name,
            zero,
            rest,
        })
    }

    /// The first value, whose number is 0.
    pub fn zero(&self) -> &EnumValue {
        &self.zero
    }

    /// Every constructor in declaration order of its first value, the zero
    /// value first. No two share a number.
    pub fn values(&self) -> impl Iterator<Item = &EnumValue> {
        std::iter::once(&self.zero).chain(&self.rest)
    }
}

impl Enum {
    /// The Elm name of the enum's JSON encoder, such as `encodeStatus`.
    pub fn encoder_name(&self) -> String {
        crate::naming::encoder_name(&self.elm_name)
    }

    /// The Elm name of the enum's JSON decoder, such as `decodeStatus`.
    pub fn decoder_name(&self) -> String {
        crate::naming::decoder_name(&self.elm_name)
    }
}

/// One number of an enum: one constructor of the enum's custom type.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EnumValue {
    /// The name of the first value declared with the number, such as
    /// `STATUS_ACTIVE`; the JSON wire form.
    pub proto_name: String,
    /// The value's number.
    pub number: i32,
    /// The constructor, named for `proto_name`, such as `StatusActive`.
    pub elm_ctor: String,
    /// The names of the values declared after it with the same number,
    /// under `allow_alias`, in declaration order. They decode to this
    /// constructor and are never written.
    pub aliases: Vec<String>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn module_names_hold_only_valid_segments() {
        let new = |segments: &[&str]| {
            ModuleName::new(segments.iter().map(|s| s.to_string()).collect())
                .map(|module| module.to_string())
        };
        assert_eq!(new(&["Notes", "V1"]).as_deref(), Some("Notes.V1"));
        assert_eq!(new(&["A_b2"]).as_deref(), Some("A_b2"));
        assert_eq!(new(&[]), None);
        assert_eq!(new(&["notes"]), None);
        assert_eq!(new(&["1V"]), None);
        assert_eq!(new(&["No-tes"]), None);
        assert_eq!(new(&[""]), None);
    }

    #[test]
    fn an_enum_starts_at_zero() {
        let value = |number| EnumValue {
            proto_name: format!("V{number}"),
            number,
            elm_ctor: format!("EV{number}"),
            aliases: Vec::new(),
        };
        let e = Enum::new(
            "t.E".into(),
            "E".into(),
            "E".into(),
            value(0),
            vec![value(1), value(2)],
        )
        .expect("zero first");
        let numbers: Vec<_> = e.values().map(|v| v.number).collect();
        assert_eq!(numbers, [0, 1, 2]);
        assert_eq!(e.zero().number, 0);
        assert_eq!(
            Enum::new("t.E".into(), "E".into(), "E".into(), value(1), vec![]),
            None
        );
    }
}
