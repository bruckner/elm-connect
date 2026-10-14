//! The emitter: one IR [`Package`] to one Elm [`Module`] of types and
//! their proto3 JSON codecs (design §2, §3), and each of its services to a
//! module of calls (design §4).
//!
//! Invariant: every name comes from the IR, every layout from the printer.
//! The emitter chooses which declarations exist and what their bodies say;
//! the Elm names of types, fields, constructors and codecs come from
//! [`crate::ir`] (which takes them from [`crate::naming`]), and the text is
//! [`crate::elm::print`]'s. The only names written here are those of the
//! libraries generated code calls: elm/core, elm/json, elm/time and the
//! runtime package.
//!
//! The rules the emitter applies:
//!
//! - A module opens with a generated-file notice, imports exactly the
//!   modules its code refers to (beyond those Elm imports by default),
//!   and holds five sections in order: types, defaults, descriptors,
//!   encoders, decoders. Each section has the enums, then the messages,
//!   each followed by its recursion wrapper and its oneofs; the defaults
//!   section has the messages alone, and is left out when there are none,
//!   and the descriptors section has each enum's and message's typed
//!   record.
//! - A service's module, `Notes.V1.NotesService`, holds one function per
//!   method from its request to an `Rpc.Call`, written point-free as
//!   `Rpc.call` of the method's `Proto.Method.Method` record: the typed
//!   records of its request and response (`Notes.V1.messageNote`, or the
//!   runtime's for a well-known type) and its descriptor, holding its
//!   service, name, idempotency, type names and bindings, the bindings
//!   its HTTP rule's own and then its additional ones, as data
//!   (`Proto.Http.binding`). A method without a rule has no
//!   bindings, and the runtime calls it over the implicit route. Every
//!   name the module refers to is qualified, so a method's name cannot
//!   shadow or clash with one.
//! - A message's typed record, `messageFoo : Proto.Message.Message Foo`,
//!   holds its encoder, decoder and default and its descriptor; an enum's,
//!   `enumBar : Proto.Enum.Enum Bar`, its full name, its encoder and
//!   decoder, and every value name with its number and constructor. The
//!   message descriptors are written inline, faithful to the proto: each
//!   field's names, number, cardinality, kind (other types by full name)
//!   and oneof. The section ends with the package's `registry`: its own
//!   descriptors (an enum's built by `Proto.Enum.descriptor`), then the
//!   registries of the packages its module imports and the well-known
//!   types', so it is transitive. Under [`Descriptors::Off`] the message
//!   trees are empty and there is no registry; the enum values stay,
//!   since `Proto.Enum` reads names and numbers through them.
//! - A message is a record type alias, a default value (`defaultFoo :
//!   Foo`, every field at its proto3 default and every oneof unset), an
//!   encoder (`Foo -> Json.Encode.Value`) and a decoder
//!   (`Json.Decode.Decoder Foo`).
//! - Encoders emit every field, default values included. proto3 JSON lets
//!   a writer omit or include them; always including them keeps the
//!   encoder one expression per field. This is the current rule, not yet
//!   reviewed (design §3.4).
//! - Decoders are a pipeline of `Proto.Json.field` steps from
//!   `Json.Decode.succeed`, so they read the same at any field count
//!   (design §8). A missing or `null` field reads as its proto3 zero value.
//!   A field whose JSON name differs from its proto name uses
//!   `Proto.Json.fieldEither`, which accepts both keys (design §3.4).
//! - A field with presence (proto3 `optional`, or message-typed) is a
//!   `Maybe`: `Nothing` encodes as `null`, and an absent or `null` field
//!   decodes as `Nothing`. A repeated field is a `List`, encoded as an
//!   array; absent or `null` decodes as `[]`. Both reuse the one
//!   `Proto.Json.field` step with `Nothing` or `[]` as its zero value.
//! - Scalars follow design §3.4: 32-bit integers are range-checked `Int`s;
//!   64-bit integers are decimal `String`s, or range-checked `Int`s encoded
//!   as strings under [`Int64::Int`], a field's `jstype` overriding the
//!   option either way.
//! - A map field is a `Dict`, keyed by `String` (string and 64-bit integer
//!   keys) or `Int` (32-bit integer keys), encoded with
//!   `Json.Encode.dict`; absent or `null` decodes as `Dict.empty`. A map
//!   with `bool` keys, which Elm cannot put in a `Dict`, is a
//!   `List ( Bool, v )` read and written by `Proto.Json.boolMap` and
//!   `encodeBoolMap`; absent or `null` decodes as `[]`.
//! - An enum is a custom type, its zero value first, with an encoder that
//!   writes each constructor's proto name and a `Proto.Json.enum`
//!   decoder that reads a name or a number, an unknown one as the zero
//!   value (design §3.3).
//! - A oneof is a custom type whose first constructor is the unset case,
//!   held in one record field where its first member was declared. Its
//!   encoder gives the set member's key and value for the message's
//!   object; its decoder is `Proto.Json.members`, which reads the one
//!   member present, unset when none is, and fails on a malformed member,
//!   on two members present, and on a member written under both its names
//!   (design §3.6).
//! - A field or member whose JSON name differs from its proto name is
//!   read under either, and an object holding both fails (design §3.4).
//! - The well-known types map to `Time.Posix`, the runtime's `Duration`,
//!   `List String` (field masks), `()` (`Empty`), `Proto.Any.Any`,
//!   `Dict String Json.Encode.Value` (`Struct`), `List Json.Encode.Value`
//!   (`ListValue`), `Json.Encode.Value` (`Value`) and the wrappers'
//!   scalars (design §3.5). All but `Empty` and `Value` are messages, held
//!   with presence; `Value` is held directly, `null` when absent; `Empty`
//!   has no presence, and a oneof member of it is a constructor without
//!   an argument.
//! - A recursive message also gets a wrapper, `type Node_ = Node_ Node`,
//!   with an encoder and a decoder; a field that closes a cycle of record
//!   fields holds the wrapper, and the wrapper's decoder reads the message
//!   through `Json.Decode.lazy`. A oneof member that closes a cycle decodes
//!   through `Json.Decode.lazy` too (design §3.2).

mod descriptor;
mod enumeration;
mod field;
mod message;
mod method;
mod oneof;
mod recursion;
mod scalar;

use std::collections::{BTreeMap, BTreeSet, HashMap};

use crate::VERSION;
use crate::diagnostics::Diagnostics;
use crate::elm::ast::{Decl, Exposed, Exposing, Expr, Import, Module, ModuleName, Type};
use crate::elm::build::{apply, qualified, ty, ty_qualified, var};
use crate::ir::{
    Field, Message, ModuleName as IrModule, Oneof, OneofVariant, Package, Service, TypeName,
};

use self::field::{FieldShape, ValueShape};

/// elm/json's decoders.
const JSON_DECODE: &str = "Json.Decode";
/// elm/json's encoders.
const JSON_ENCODE: &str = "Json.Encode";
/// The runtime package's proto3 JSON helpers.
const PROTO_JSON: &str = "Proto.Json";
/// elm/core's `Dict`, imported as `import Dict exposing (Dict)` so the
/// type reads `Dict String V`, as Elm code conventionally writes it.
const CORE_DICT: &str = "Dict";
/// elm/core's `String`, which every Elm module imports by default.
const CORE_STRING: &str = "String";
/// elm/time's `Time`, for `Time.Posix`.
const TIME: &str = "Time";
/// The runtime package's `Duration`, imported as
/// `import Proto.Duration exposing (Duration)`.
const PROTO_DURATION: &str = "Proto.Duration";
/// The runtime package's calls, home of `Rpc.Call`.
const RPC: &str = "Rpc";
/// The runtime package's descriptors, whose constructors the trees use.
const PROTO_DESCRIPTOR: &str = "Proto.Descriptor";
/// The runtime package's HTTP bindings, which a method's descriptor holds.
const PROTO_HTTP: &str = "Proto.Http";
/// The runtime package's typed message records.
const PROTO_MESSAGE: &str = "Proto.Message";
/// The runtime package's typed enum records.
const PROTO_ENUM: &str = "Proto.Enum";
/// The runtime package's typed records of the well-known types.
const PROTO_WELL_KNOWN: &str = "Proto.WellKnown";
/// The runtime package's registry of descriptors.
const PROTO_REGISTRY: &str = "Proto.Registry";
/// The runtime package's `google.protobuf.Any`.
const PROTO_ANY: &str = "Proto.Any";

/// How to generate (design §6). The options design §6 lists that are not
/// here arrive with the features they control.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
#[non_exhaustive]
pub struct Options {
    /// How 64-bit integer fields are held (`int64=`), unless a field's
    /// `jstype` says otherwise (design §3.4).
    pub int64: Int64,
    /// What a method without a `google.api.http` rule gets
    /// (`unbound_methods=`, design §4).
    pub unbound_methods: UnboundMethods,
    /// Whether descriptors hold their fields and values (`descriptors=`,
    /// design §3.9).
    pub descriptors: Descriptors,
}

impl Options {
    /// The options a protoc plugin parameter sets: comma-separated
    /// `key=value` pairs, such as `int64=int`, each option at most once.
    /// The empty parameter is the defaults. An unknown key or value is an
    /// error saying which.
    pub fn from_parameter(parameter: &str) -> Result<Self, String> {
        let mut options = Options::default();
        let mut seen = BTreeSet::new();
        for pair in parameter
            .split(',')
            .map(str::trim)
            .filter(|p| !p.is_empty())
        {
            let Some((key, value)) = pair.split_once('=') else {
                return Err(format!("expected `key=value`, got `{pair}`"));
            };
            let (key, value) = (key.trim(), value.trim());
            if !seen.insert(key.to_owned()) {
                return Err(format!("`{key}` is given more than once"));
            }
            match key {
                "int64" => options.int64 = value.parse()?,
                "unbound_methods" => options.unbound_methods = value.parse()?,
                "descriptors" => options.descriptors = value.parse()?,
                _ => {
                    return Err(format!(
                        "unknown option `{key}`; the options are: int64, unbound_methods, \
                         descriptors"
                    ));
                }
            }
        }
        Ok(options)
    }
}

/// How 64-bit integers (`int64`, `uint64`, `sint64`, `fixed64`,
/// `sfixed64`) are held in Elm (design §3.4).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Int64 {
    /// `String`, the decimal integer as proto3 JSON writes it: exact for
    /// every value.
    #[default]
    String,
    /// `Int`, exact within ±(2^53 − 1); a value outside that range fails
    /// to decode.
    Int,
}

impl std::str::FromStr for Int64 {
    type Err = String;

    fn from_str(value: &str) -> Result<Self, String> {
        match value {
            "string" => Ok(Int64::String),
            "int" => Ok(Int64::Int),
            _ => Err(format!("`int64` is `string` or `int`, not `{value}`")),
        }
    }
}

/// What a method without a `google.api.http` rule gets (design §4).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum UnboundMethods {
    /// Generated like any other, with no bindings: the runtime calls it
    /// over the implicit route `POST /<package>.<Service>/<Method>`, which
    /// grpc-gateway (`generate_unbound_methods`), Envoy's transcoder
    /// (`auto_mapping`) and Vanguard serve.
    #[default]
    Implicit,
    /// A diagnostic, `services::unbound_method`, for a server that serves
    /// rules alone.
    Error,
}

impl std::str::FromStr for UnboundMethods {
    type Err = String;

    fn from_str(value: &str) -> Result<Self, String> {
        match value {
            "implicit" => Ok(UnboundMethods::Implicit),
            "error" => Ok(UnboundMethods::Error),
            _ => Err(format!(
                "`unbound_methods` is `implicit` or `error`, not `{value}`"
            )),
        }
    }
}

/// Whether the generated descriptors hold the proto's fields and values
/// (design §3.9).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Descriptors {
    /// Every message's descriptor lists its fields and oneofs, and each
    /// package module has a `registry`.
    #[default]
    On,
    /// The message descriptors are empty (`fields = []`, `oneofs = []`,
    /// the full name kept) and no `registry` is generated, for
    /// applications that want smaller modules. Enum records keep their
    /// values, which `Proto.Enum` reads names and numbers through.
    Off,
}

impl std::str::FromStr for Descriptors {
    type Err = String;

    fn from_str(value: &str) -> Result<Self, String> {
        match value {
            "on" => Ok(Descriptors::On),
            "off" => Ok(Descriptors::Off),
            _ => Err(format!("`descriptors` is `on` or `off`, not `{value}`")),
        }
    }
}

/// The Elm module for `package`. Every construct a built IR holds has an
/// emitter, so this does not fail today; the error is the problems found,
/// for constructs to come whose emitters may report some.
pub fn emit(package: &Package, options: &Options) -> Result<Module, Diagnostics> {
    let mut emitter = Emitter::new(&package.module, options);
    let decls = emitter.package(package);
    Ok(emitter.module(package, decls))
}

/// The Elm module of `service`, one of `package`'s: one call per method.
pub fn emit_service(package: &Package, service: &Service, options: &Options) -> Module {
    let mut emitter = Emitter::new(&service.module, options);
    let decls = service
        .methods
        .iter()
        .map(|method| emitter.method(&service.proto_full_name, method))
        .collect();
    emitter.module(package, decls)
}

/// A message whose every field and oneof member has a shape.
struct MessageShape<'m> {
    message: &'m Message,
    fields: Vec<(&'m Field, FieldShape<'m>)>,
    oneofs: Vec<OneofShape<'m>>,
}

impl<'m> MessageShape<'m> {
    /// The record's fields in declaration order: each oneof where its
    /// first member was declared, among the plain fields.
    fn record(&self) -> Vec<RecordField<'_, 'm>> {
        let mut oneofs = self.oneofs.iter().peekable();
        let mut record = Vec::new();
        for (index, &(field, shape)) in self.fields.iter().enumerate() {
            while let Some(oneof) = oneofs.next_if(|oneof| oneof.oneof.position <= index) {
                record.push(RecordField::Oneof(oneof));
            }
            record.push(RecordField::Field(field, shape));
        }
        record.extend(oneofs.map(RecordField::Oneof));
        record
    }
}

/// One field of a message's record: a proto field, or a oneof.
enum RecordField<'s, 'm> {
    Field(&'m Field, FieldShape<'m>),
    Oneof(&'s OneofShape<'m>),
}

/// A oneof whose every member has a shape.
struct OneofShape<'m> {
    oneof: &'m Oneof,
    variants: Vec<(&'m OneofVariant, ValueShape<'m>)>,
}

/// `message` with the shape of each of its fields and oneof members.
/// `by_name` holds every message of the package, for the wrappers of
/// cyclic fields; `int64` is the generator's option.
fn message_shape<'m>(
    message: &'m Message,
    by_name: &HashMap<&str, &'m Message>,
    int64: Int64,
) -> MessageShape<'m> {
    let fields = message
        .fields
        .iter()
        .map(|field| (field, field::field_shape(field, by_name, int64)))
        .collect();
    let oneofs = message
        .oneofs
        .iter()
        .map(|oneof| OneofShape {
            oneof,
            variants: oneof
                .variants
                .iter()
                .map(|variant| {
                    let int64 = field::field_int64(variant.jstype, int64);
                    (variant, field::value_shape(&variant.ty, int64))
                })
                .collect(),
        })
        .collect();
    MessageShape {
        message,
        fields,
        oneofs,
    }
}

/// The state of emitting one module: the modules its code refers to so
/// far.
struct Emitter {
    module: IrModule,
    /// Each module imported, with the types its import exposes.
    imports: BTreeMap<String, BTreeSet<String>>,
    /// How 64-bit integers are held where a field does not say.
    int64: Int64,
    /// Whether descriptors hold their fields and values.
    descriptors: Descriptors,
}

impl Emitter {
    fn new(module: &IrModule, options: &Options) -> Self {
        Emitter {
            module: module.clone(),
            imports: BTreeMap::new(),
            int64: options.int64,
            descriptors: options.descriptors,
        }
    }

    /// The module of `decls`, generated from `package`'s files, importing
    /// what they refer to.
    fn module(self, package: &Package, decls: Vec<Decl>) -> Module {
        Module {
            header: Some(format!(
                "Generated by elm-connect {VERSION} from {}. Do not edit; regenerate instead.",
                package.files.join(", ")
            )),
            name: ModuleName::new(self.module.to_string()),
            doc: None,
            exposing: Exposing::All,
            imports: self
                .imports
                .into_iter()
                .map(|(module, types)| Import {
                    module: ModuleName::new(module),
                    alias: None,
                    exposing: (!types.is_empty()).then(|| {
                        Exposing::Explicit(types.into_iter().map(Exposed::Type).collect())
                    }),
                })
                .collect(),
            decls,
        }
    }

    /// The declarations of `package`, by section.
    fn package(&mut self, package: &Package) -> Vec<Decl> {
        let by_name: HashMap<&str, &Message> = package
            .messages
            .iter()
            .map(|message| (message.elm_name.as_str(), message))
            .collect();
        let messages: Vec<_> = package
            .messages
            .iter()
            .map(|message| message_shape(message, &by_name, self.int64))
            .collect();
        if messages.is_empty() && package.enums.is_empty() {
            return match self.descriptors {
                Descriptors::On => {
                    vec![Decl::Comment("DESCRIPTORS".into()), self.registry(package)]
                }
                Descriptors::Off => Vec::new(),
            };
        }
        let mut types = vec![Decl::Comment("TYPES".into())];
        let mut defaults = vec![Decl::Comment("DEFAULTS".into())];
        let mut descriptors = vec![Decl::Comment("DESCRIPTORS".into())];
        let mut encoders = vec![Decl::Comment("ENCODERS".into())];
        let mut decoders = vec![Decl::Comment("DECODERS".into())];
        for enumeration in &package.enums {
            types.push(self.enum_type(enumeration));
            descriptors.push(self.enum_record(enumeration));
            encoders.push(self.enum_encoder(enumeration));
            decoders.push(self.enum_decoder(enumeration));
        }
        for shape in &messages {
            types.push(self.message_alias(shape));
            defaults.push(self.message_default(shape));
            descriptors.push(self.message_record(shape));
            encoders.push(self.message_encoder(shape));
            decoders.push(self.message_decoder(shape));
            if let Some(wrapper) = &shape.message.wrapper {
                types.push(self.wrapper_type(shape.message, wrapper));
                encoders.push(self.wrapper_encoder(shape.message, wrapper));
                decoders.push(self.wrapper_decoder(shape.message, wrapper));
            }
            for oneof in &shape.oneofs {
                types.push(self.oneof_type(oneof));
                encoders.push(self.oneof_encoder(oneof));
                decoders.push(self.oneof_decoder(oneof));
            }
        }
        if self.descriptors == Descriptors::On {
            descriptors.push(self.registry(package));
        }
        // A package of enums alone has no defaults.
        if messages.is_empty() {
            defaults.clear();
        }
        types
            .into_iter()
            .chain(defaults)
            .chain(descriptors)
            .chain(encoders)
            .chain(decoders)
            .collect()
    }

    /// A generated type, qualified (and its module imported) when it is
    /// defined in another module than the one being emitted.
    fn generated_type(&mut self, name: &TypeName) -> Type {
        if name.module == self.module {
            ty(name.name.clone(), [])
        } else {
            self.imports.entry(name.module.to_string()).or_default();
            ty_qualified(
                ModuleName::new(name.module.to_string()),
                name.name.clone(),
                [],
            )
        }
    }

    /// A generated value, qualified (and its module imported) when it is
    /// defined in another module than the one being emitted.
    fn generated_value(&mut self, module: &IrModule, name: String) -> Expr {
        if *module == self.module {
            var(name)
        } else {
            self.imports.entry(module.to_string()).or_default();
            qualified(ModuleName::new(module.to_string()), name)
        }
    }

    /// A reference to `name` in the library module `module`, which the
    /// module then imports.
    fn reference(&mut self, (module, name): (&'static str, &str)) -> Expr {
        self.imports.entry(module.to_owned()).or_default();
        qualified(module, name)
    }

    /// The library type `name args`, unqualified, exposed by the module's
    /// import of `module`.
    fn exposed_type(
        &mut self,
        module: &'static str,
        name: &str,
        args: impl IntoIterator<Item = Type>,
    ) -> Type {
        self.imports
            .entry(module.to_owned())
            .or_default()
            .insert(name.to_owned());
        ty(name, args)
    }

    /// The library type `module.name args`, which the module then imports.
    fn library_type(
        &mut self,
        module: &'static str,
        name: &str,
        args: impl IntoIterator<Item = Type>,
    ) -> Type {
        self.imports.entry(module.to_owned()).or_default();
        ty_qualified(module, name, args)
    }
}

/// `f args`, where `f` may already be a partial application: the
/// arguments join it (`Json.Encode.list Json.Encode.int` applied to `xs`
/// is `Json.Encode.list Json.Encode.int xs`, not a parenthesized call).
fn call(f: Expr, args: impl IntoIterator<Item = Expr>) -> Expr {
    match f {
        Expr::Apply(f, mut first) => {
            first.extend(args);
            Expr::Apply(f, first)
        }
        f => apply(f, args),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ir::{Cardinality, ScalarKind, TypeRef};

    fn package(messages: Vec<Message>) -> Package {
        Package {
            proto_name: "t.v1".into(),
            module: IrModule::new(vec!["T".into(), "V1".into()]).expect("valid"),
            files: vec!["a.proto".into(), "b.proto".into()],
            messages,
            enums: Vec::new(),
            services: Vec::new(),
        }
    }

    fn message(name: &str, fields: Vec<Field>) -> Message {
        Message {
            proto_full_name: format!("t.v1.{name}"),
            elm_name: name.into(),
            fields,
            oneofs: Vec::new(),
            wrapper: None,
        }
    }

    fn field(name: &str, cardinality: Cardinality, ty: TypeRef) -> Field {
        Field {
            proto_name: name.into(),
            json_name: name.into(),
            number: 1,
            elm_name: name.into(),
            cardinality,
            ty,
            cyclic: false,
            jstype: crate::ir::JsType::Normal,
        }
    }

    #[test]
    fn options_come_from_a_plugin_parameter() {
        assert_eq!(Options::from_parameter(""), Ok(Options::default()));
        assert_eq!(
            Options::from_parameter("int64=int").map(|o| o.int64),
            Ok(Int64::Int)
        );
        assert_eq!(
            Options::from_parameter(" int64 = string ,").map(|o| o.int64),
            Ok(Int64::String)
        );
        let error = |parameter| Options::from_parameter(parameter).unwrap_err();
        assert!(error("int64=long").contains("`string` or `int`"));
        assert!(error("int64").contains("`key=value`"));
        assert!(error("colour=red").contains("unknown option `colour`"));
        assert!(error("int64=int,int64=string").contains("more than once"));
        let unbound = |parameter| Options::from_parameter(parameter).map(|o| o.unbound_methods);
        assert_eq!(unbound(""), Ok(UnboundMethods::Implicit));
        assert_eq!(unbound("unbound_methods=error"), Ok(UnboundMethods::Error));
        assert_eq!(
            unbound("int64=int,unbound_methods=implicit"),
            Ok(UnboundMethods::Implicit)
        );
        assert!(error("unbound_methods=drop").contains("`implicit` or `error`"));
        let descriptors = |parameter| Options::from_parameter(parameter).map(|o| o.descriptors);
        assert_eq!(descriptors(""), Ok(Descriptors::On));
        assert_eq!(descriptors("descriptors=off"), Ok(Descriptors::Off));
        assert!(error("descriptors=empty").contains("`on` or `off`"));
    }

    #[test]
    fn header_names_the_package_files() {
        let module = emit(&package(Vec::new()), &Options::default()).expect("emits");
        assert_eq!(
            module.header.as_deref(),
            Some(&*format!(
                "Generated by elm-connect {VERSION} from a.proto, b.proto. Do not edit; \
                 regenerate instead."
            ))
        );
        assert_eq!(module.name.as_str(), "T.V1");
    }

    #[test]
    fn imports_only_what_the_code_uses() {
        let only_ints = package(vec![message(
            "A",
            vec![field(
                "n",
                Cardinality::Singular,
                TypeRef::Scalar(ScalarKind::Int32),
            )],
        )]);
        let module = emit(&only_ints, &Options::default()).expect("emits");
        let imports: Vec<&str> = module.imports.iter().map(|i| i.module.as_str()).collect();
        assert_eq!(
            imports,
            [
                "Json.Decode",
                "Json.Encode",
                "Proto.Descriptor",
                "Proto.Json",
                "Proto.Message",
                "Proto.Registry"
            ]
        );

        let empty = package(vec![message("E", Vec::new())]);
        let module = emit(&empty, &Options::default()).expect("emits");
        let imports: Vec<&str> = module.imports.iter().map(|i| i.module.as_str()).collect();
        assert_eq!(
            imports,
            [
                "Json.Decode",
                "Json.Encode",
                "Proto.Message",
                "Proto.Registry"
            ]
        );

        let off = Options::from_parameter("descriptors=off").expect("parses");
        let module = emit(&only_ints, &off).expect("emits");
        let imports: Vec<&str> = module.imports.iter().map(|i| i.module.as_str()).collect();
        assert_eq!(
            imports,
            ["Json.Decode", "Json.Encode", "Proto.Json", "Proto.Message"]
        );
    }

    #[test]
    fn descriptors_hold_the_fields_unless_off() {
        let one = package(vec![message(
            "A",
            vec![field(
                "n",
                Cardinality::Map(crate::ir::MapKey::Bool),
                TypeRef::Scalar(ScalarKind::SFixed64),
            )],
        )]);
        let printed = |options: &Options| {
            crate::elm::print::print_module(&emit(&one, options).expect("emits"))
        };
        let on = printed(&Options::default());
        assert!(
            on.contains(
                "fields = [ { name = \"n\", jsonName = \"n\", number = 1, cardinality = \
                 Proto.Descriptor.Map Proto.Descriptor.Bool, kind = Proto.Descriptor.Scalar \
                 Proto.Descriptor.Sfixed64, oneof = Nothing } ]"
            ),
            "{on}"
        );
        assert!(
            on.contains(
                "registry =\n    Proto.Registry.union (Proto.Registry.fromDescriptors \
                 [ messageA.descriptor ] []) Proto.Registry.wellKnown"
            ),
            "{on}"
        );
        let off = printed(&Options::from_parameter("descriptors=off").expect("parses"));
        assert!(off.contains("fields = []"), "{off}");
        assert!(!off.contains("registry"), "{off}");

        let nothing = package(Vec::new());
        let printed =
            crate::elm::print::print_module(&emit(&nothing, &Options::default()).expect("emits"));
        assert!(
            printed.contains("registry =\n    Proto.Registry.wellKnown"),
            "{printed}"
        );
    }

    #[test]
    fn sections_come_in_order_and_defaults_only_with_messages() {
        let sections = |package: &Package| -> Vec<String> {
            emit(package, &Options::default())
                .expect("emits")
                .decls
                .into_iter()
                .filter_map(|decl| match decl {
                    Decl::Comment(text) => Some(text),
                    _ => None,
                })
                .collect()
        };
        let one = package(vec![message("A", Vec::new())]);
        assert_eq!(
            sections(&one),
            ["TYPES", "DEFAULTS", "DESCRIPTORS", "ENCODERS", "DECODERS"]
        );
        let printed = crate::elm::print::print_module(&emit(&one, &Options::default()).unwrap());
        assert!(
            printed.contains("defaultA : A\ndefaultA =\n    {}"),
            "{printed}"
        );

        let mut enums_only = package(Vec::new());
        let value = |name: &str, number| crate::ir::EnumValue {
            proto_name: name.into(),
            number,
            elm_ctor: name.into(),
            aliases: Vec::new(),
        };
        enums_only.enums.push(
            crate::ir::Enum::new(
                "t.v1.E".into(),
                "E".into(),
                "E".into(),
                value("EZero", 0),
                Vec::new(),
            )
            .expect("zero first"),
        );
        assert_eq!(
            sections(&enums_only),
            ["TYPES", "DESCRIPTORS", "ENCODERS", "DECODERS"]
        );
    }

    #[test]
    fn other_modules_are_qualified_and_imported() {
        let elsewhere = TypeName {
            module: IrModule::new(vec!["Other".into(), "V1".into()]).expect("valid"),
            name: "B".into(),
            proto_full_name: "other.v1.B".into(),
        };
        let module = emit(
            &package(vec![message(
                "A",
                vec![field(
                    "b",
                    Cardinality::Singular,
                    TypeRef::Message(elsewhere),
                )],
            )]),
            &Options::default(),
        )
        .expect("emits");
        let imports: Vec<&str> = module.imports.iter().map(|i| i.module.as_str()).collect();
        assert_eq!(
            imports,
            [
                "Json.Decode",
                "Json.Encode",
                "Other.V1",
                "Proto.Descriptor",
                "Proto.Json",
                "Proto.Message",
                "Proto.Registry"
            ]
        );
        let printed = crate::elm::print::print_module(&module);
        assert!(printed.contains("b : Maybe Other.V1.B"), "{printed}");
        assert!(
            printed.contains("kind = Proto.Descriptor.Message \"other.v1.B\""),
            "{printed}"
        );
        assert!(
            printed.contains("(Proto.Registry.union Other.V1.registry Proto.Registry.wellKnown)"),
            "{printed}"
        );
        assert!(
            printed.contains("Proto.Json.encodeMaybe Other.V1.encodeB value.b"),
            "{printed}"
        );
        assert!(
            printed.contains("(Json.Decode.map Just Other.V1.decodeB)"),
            "{printed}"
        );
    }

    #[test]
    fn an_enum_from_another_module_reads_absence_as_its_qualified_zero() {
        let elsewhere = TypeName {
            module: IrModule::new(vec!["Other".into(), "V1".into()]).expect("valid"),
            name: "Level".into(),
            proto_full_name: "other.v1.Level".into(),
        };
        let module = emit(
            &package(vec![message(
                "A",
                vec![field(
                    "level",
                    Cardinality::Singular,
                    TypeRef::Enum {
                        name: elsewhere,
                        zero_ctor: "LevelNone".into(),
                    },
                )],
            )]),
            &Options::default(),
        )
        .expect("emits");
        let printed = crate::elm::print::print_module(&module);
        assert!(printed.contains("level : Other.V1.Level"), "{printed}");
        assert!(
            printed.contains(r#"Proto.Json.field "level" Other.V1.LevelNone Other.V1.decodeLevel"#),
            "{printed}"
        );
    }
}
