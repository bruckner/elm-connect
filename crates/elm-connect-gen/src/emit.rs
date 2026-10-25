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
//! - A module opens with a generated-file notice naming the generator's
//!   version, imports exactly the modules its code refers to (beyond those
//!   Elm imports by default), and defines `elmConnectVersion_`, the
//!   `Proto.Version` value of the release it was generated for, which the
//!   compiler refuses unless the runtime package is of a compatible
//!   release (design §8). A package's module then holds six sections in
//!   order: types, defaults, typed values, registry, encoders, decoders.
//!   Each section has the enums, then the messages, each followed by its
//!   recursion wrapper and its oneofs; the defaults section has the
//!   messages alone, and is left out when there are none, and the typed
//!   values section has each enum's and message's typed value. A package
//!   without types has the registry alone.
//! - Each message and enum has a descriptor module of its own inside its
//!   package's, `Notes.V1.Note` (design §3.1): what the proto says about
//!   it, while the package's module holds the values a program sends and
//!   receives. It imports the runtime and the descriptor modules of the
//!   enums its fields hold, never a package's module, so the package's
//!   module can import it.
//! - A service's module, `Notes.V1.NotesService`, holds two sections:
//!   descriptors, then calls. Each method's descriptor,
//!   `descriptorGetNote : Proto.Method.Descriptor`, is built by
//!   `Proto.Method.descriptor` from its service, name, idempotency, type
//!   names and bindings, the bindings its HTTP rule's own and then its
//!   additional ones, as data (`Proto.Http.binding`), each path variable
//!   and query parameter the path of field descriptors from the request
//!   down to its field (`[ Notes.V1.GetNoteRequest.name ]`), from the
//!   descriptor modules the service's module then imports. A method without a
//!   rule has no bindings, and the runtime calls it over the implicit
//!   route. Its call is a function from its request to an `Rpc.Call`,
//!   written point-free as `Rpc.call` of the method's
//!   `Proto.Method.Method`, built by `Proto.Method.method` from the
//!   encoder of its request and the decoder of its response
//!   (`Notes.V1.encodeGetNoteRequest`, or the runtime's for a well-known
//!   type) and its descriptor value. Both applications put one argument
//!   per line however short, so every method reads alike. Elm's dead-code
//!   elimination keeps a top-level value whole and the call refers to the
//!   descriptor, so a program that calls a method keeps what it would
//!   with the descriptor inline, and one that does not keeps neither.
//!   Every library name the module refers to is qualified, so a method's
//!   name cannot shadow or clash with one.
//! - A message's descriptor, `descriptor : Proto.Message.Descriptor` in
//!   its descriptor module, is built with `Proto.Message.descriptor` from
//!   its full name and the module's field values, one
//!   `Proto.Field.descriptor` per field named as its record field
//!   (`title`), faithful to the proto: its
//!   names, number, cardinality and kind (an enum by its descriptor
//!   value, a message by its full name), then
//!   a modifier only for what it has beyond those (`inOneof`,
//!   `withBehavior`, `withDeprecated`); the builder derives the oneofs.
//!   An enum's, `descriptor : Proto.Enum.Descriptor`, holds every
//!   declared name with its number (`Proto.EnumValue.descriptor`), each
//!   deprecated one marked (`withDeprecated`). Each type's typed value,
//!   in the package's module, is
//!   `messageFoo : Proto.Message.Message Foo`, built by
//!   `Proto.Message.message` from its encoder, decoder, default and
//!   descriptor, and `enumBar : Proto.Enum.Enum Bar` likewise with its
//!   zero value. The package's `registry` holds its own descriptors (the
//!   descriptor modules' values, so a program using it keeps no codecs),
//!   then the registries of the packages its module imports and the
//!   well-known types', so it is transitive.
//! - A declaration a proto element becomes is documented with what the
//!   proto says about it: its comment and its one-line declaration, as
//!   [`docs`] lays them out; a method's call with its Connect path and
//!   HTTP bindings too, a service's in its module's documentation; codecs,
//!   defaults, typed values and method descriptors with one sentence.
//! - A message is a record type alias, a default value (`defaultFoo :
//!   Foo`, every field at its proto3 default and every oneof unset), an
//!   encoder (`Foo -> Json.Encode.Value`) and a decoder
//!   (`Json.Decode.Decoder Foo`).
//! - Encoders are `Proto.Json.objectOfFields` over one `( jsonName, Maybe Value )`
//!   pair per field, and leave out every field at its default, as
//!   protobuf-go's `protojson` does: a field without presence at its zero
//!   value, a `Maybe` when `Nothing`, a list or map when empty (design
//!   §3.4). A parser reads a missing field as its default.
//! - Decoders are a pipeline of `Proto.Json.field` steps from
//!   `Json.Decode.succeed`, so they read the same at any field count
//!   (design §8). A missing or `null` field reads as its proto3 zero value.
//!   A field whose JSON name differs from its proto name uses
//!   `Proto.Json.fieldEither`, which accepts both keys (design §3.4).
//! - A field with presence (proto3 `optional`, or message-typed) is a
//!   `Maybe`: `Nothing` is left out, and an absent or `null` field
//!   decodes as `Nothing`. A repeated field is a `List`, encoded as an
//!   array unless empty; absent or `null` decodes as `[]`. Both reuse the one
//!   `Proto.Json.field` step with `Nothing` or `[]` as its zero value.
//! - Scalars follow design §3.4: 32-bit integers are range-checked `Int`s;
//!   64-bit integers are decimal `String`s, or range-checked `Int`s encoded
//!   as strings under [`Int64::Int`](crate::options::Int64::Int), a
//!   field's `jstype` overriding the option either way. `bytes` is a
//!   `String` of base64, or elm/bytes' `Bytes` under
//!   [`Bytes::Bytes`](crate::options::Bytes::Bytes), whose default is left
//!   out by its width (`Proto.Json.implicitBytesField`) since Elm's `==` finds
//!   any two `Bytes` equal.
//! - A map field is a `Dict`, keyed by `String` (string and 64-bit integer
//!   keys) or `Int` (32-bit integer keys), encoded with
//!   `Proto.Json.dictField` and decoded by the key's kind
//!   (`Json.Decode.dict`, `Proto.Json.int32Dict`, `uint32Dict`,
//!   `int64Dict`, `uint64Dict`); absent or `null` decodes as `Dict.empty`. A map
//!   with `bool` keys, which Elm cannot put in a `Dict`, is a
//!   `List ( Bool, v )` read and written by `Proto.Json.boolMap` and
//!   `boolMapField`; absent or `null` decodes as `[]`.
//! - An enum is a custom type, its zero value first, with an encoder that
//!   writes each constructor's proto name and a `Proto.Json.enum`
//!   decoder that reads a name or a number, an unknown number as the zero
//!   value and an unknown name as a failure; under [`EnumUnknown::Zero`]
//!   the decoder is `Proto.Json.enumOrZero`, which reads an unknown name
//!   as the zero value too (design §3.3).
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
mod docs;
mod enumeration;
mod field;
mod message;
mod method;
mod oneof;
mod recursion;
mod scalar;

use std::collections::{BTreeMap, BTreeSet, HashMap};

use crate::diagnostics::{Problem, Site};
use crate::elm::ast::{Decl, Exposed, Exposing, Expr, Import, Module, ModuleName, Type};
use crate::elm::build::{apply, qualified, ty, ty_qualified, var};
use crate::ir::{
    Element, Field, Message, ModuleName as IrModule, Oneof, OneofVariant, Package, Service,
    TypeName,
};
use crate::naming::VERSION_VALUE;
use crate::options::{EnumUnknown, Options};
use crate::{DEFAULT_OPTIONS, HEADER_PREFIX, OPTIONS_PREFIX, SENTINEL, VERSION};

use self::field::{FieldShape, ValueShape};
use self::scalar::Holding;

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
/// elm/bytes' `Bytes`, for `Bytes.Bytes` under `bytes=bytes`.
const ELM_BYTES: &str = "Bytes";
/// The runtime package's bytes conversions, home of `Proto.Bytes.empty`.
const PROTO_BYTES: &str = "Proto.Bytes";
/// The runtime package's `Duration`, imported as
/// `import Proto.Duration exposing (Duration)`.
const PROTO_DURATION: &str = "Proto.Duration";
/// The runtime package's calls, home of `Rpc.Call`.
const RPC: &str = "Rpc";
/// The runtime package's server-streaming calls, home of `StreamCall`.
const RPC_STREAM: &str = "Rpc.Stream";
/// The runtime package's HTTP bindings, which a method's descriptor holds.
const PROTO_HTTP: &str = "Proto.Http";
/// The runtime package's messages: typed values and descriptors.
const PROTO_MESSAGE: &str = "Proto.Message";
/// The runtime package's fields: descriptors and the unions they hold.
const PROTO_FIELD: &str = "Proto.Field";
/// The runtime package's methods: typed values and descriptors.
const PROTO_METHOD: &str = "Proto.Method";
/// The runtime package's enums: typed values and descriptors.
const PROTO_ENUM: &str = "Proto.Enum";
/// The runtime package's enum values' descriptors.
const PROTO_ENUM_VALUE: &str = "Proto.EnumValue";
/// The runtime package's registry of descriptors.
const PROTO_REGISTRY: &str = "Proto.Registry";
/// The runtime package's `google.protobuf.Any`.
const PROTO_ANY: &str = "Proto.Any";
/// The runtime package's release names, which `elmConnectVersion_` uses.
const PROTO_VERSION: &str = "Proto.Version";

/// The names of elm/core's default imports that generated code uses
/// unqualified, each with its module and its kind: a type or constructor
/// of the same name and kind in a generated module would take its place.
const DEFAULT_IMPORTS: [(&str, &str, Kind); 9] = [
    ("Int", "Basics", Kind::Type),
    ("Float", "Basics", Kind::Type),
    ("Bool", "Basics", Kind::Type),
    ("False", "Basics", Kind::Constructor),
    ("String", "String", Kind::Type),
    ("List", "List", Kind::Type),
    ("Maybe", "Maybe", Kind::Type),
    ("Just", "Maybe", Kind::Constructor),
    ("Nothing", "Maybe", Kind::Constructor),
];

/// Elm's two namespaces of capitalized names, which do not meet: a type
/// `Just` would not hide `Maybe.Just`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
enum Kind {
    Type,
    Constructor,
}

impl Kind {
    fn as_str(self) -> &'static str {
        match self {
            Kind::Type => "type",
            Kind::Constructor => "constructor",
        }
    }
}

/// The documentation of `elmConnectVersion_`, for a reader who meets the
/// compile error without the runtime's source at hand.
const VERSION_VALUE_DOC: &str = "The elm-connect release this module was generated for: a compile \
                                 error here means the runtime package is from another release.";

/// The Elm module for `package`, or, when it declares a type or
/// constructor under a name its code also uses unqualified for a
/// library's, every such name.
pub fn emit(package: &Package, options: &Options) -> Result<Module, Vec<ReservedName>> {
    let mut emitter = Emitter::new(&package.module, options);
    let decls = emitter.package(package);
    let reserved = emitter.reserved_names(package, options);
    if !reserved.is_empty() {
        return Err(reserved);
    }
    let mut module = emitter.module(package, decls);
    module.doc = docs::package(package);
    Ok(module)
}

/// A type or constructor a package declares under a name its module's
/// code also uses unqualified for a library's. The emitter finds these
/// only once it has written the code, after the IR is built; the IR keeps
/// no source positions, so the caller, which holds the descriptor pool,
/// finds the site of [`ReservedName::element`] and makes the problem.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ReservedName {
    /// The proto element that declares it.
    pub element: Element,
    /// The element, as a problem names it: "message `notes.v1.Dict`".
    pub what: String,
    /// "type" or "constructor".
    pub kind: &'static str,
    /// The Elm name.
    pub name: String,
    /// The library module whose name it takes.
    pub home: &'static str,
    /// The `rename` option that would rename the element, as its reader
    /// writes it.
    pub rename: String,
    /// The `rename` option's name, as its reader writes it, when a rename
    /// gave the element this name.
    pub renamed_by: Option<&'static str>,
}

impl ReservedName {
    /// The label of the element's name: "message `notes.v1.Dict` becomes
    /// `Dict`", or "... is renamed to `String` by `rename`".
    pub fn label(&self) -> String {
        let name = &self.name;
        match self.renamed_by {
            Some(option) => format!("{} is renamed to `{name}` by {option}", self.what),
            None => format!("{} becomes `{name}`", self.what),
        }
    }

    /// The `naming::reserved_name` problem, at `site` when it is known.
    pub fn problem(&self, site: Option<Site>) -> Problem {
        Problem::reserved_name(
            &self.what,
            self.kind,
            &self.name,
            self.home,
            &self.rename,
            site,
        )
    }
}

/// The descriptor modules of `package`: one per enum, then one per
/// message, each in declaration order.
pub fn emit_descriptor_modules(package: &Package, options: &Options) -> Vec<Module> {
    let by_name = messages_by_name(package);
    let mut modules = Vec::new();
    for enumeration in &package.enums {
        let mut emitter = Emitter::new(&enumeration.descriptor_module(&package.module), options);
        let decls = emitter.enum_descriptor_module(&package.module, enumeration);
        let mut module = emitter.module(package, decls);
        module.doc = Some(docs::enum_descriptor_module(enumeration));
        modules.push(module);
    }
    for message in &package.messages {
        let shape = message_shape(message, &by_name, Holding::of(options));
        let mut emitter = Emitter::new(&message.descriptor_module(&package.module), options);
        let decls = emitter.message_descriptor_module(&package.module, &shape);
        let mut module = emitter.module(package, decls);
        module.doc = Some(docs::message_descriptor_module(
            message,
            !shape.record().is_empty(),
        ));
        modules.push(module);
    }
    modules
}

/// Every message of `package` by its Elm name, for the wrappers of cyclic
/// fields.
fn messages_by_name(package: &Package) -> HashMap<&str, &Message> {
    package
        .messages
        .iter()
        .map(|message| (message.elm_name.as_str(), message))
        .collect()
}

/// The Elm module of `service`, one of `package`'s: a call and a
/// descriptor per method, in two sections, the calls a program uses
/// first.
pub fn emit_service(package: &Package, service: &Service, options: &Options) -> Module {
    let mut emitter = Emitter::new(&service.module, options);
    let mut decls = Vec::new();
    if !service.methods.is_empty() {
        decls.push(Decl::Comment("CALLS".into()));
        for method in &service.methods {
            decls.push(emitter.method(&service.proto_full_name, method));
        }
        decls.push(Decl::Comment("DESCRIPTORS".into()));
        for method in &service.methods {
            decls.push(emitter.method_descriptor(&service.proto_full_name, method));
        }
    }
    let mut module = emitter.module(package, decls);
    module.doc = Some(docs::service(service));
    module
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
/// cyclic fields; `holding` is what the generator's options say.
fn message_shape<'m>(
    message: &'m Message,
    by_name: &HashMap<&str, &'m Message>,
    holding: Holding,
) -> MessageShape<'m> {
    let fields = message
        .fields
        .iter()
        .map(|field| (field, field::field_shape(field, by_name, holding)))
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
                    let holding = field::field_holding(variant.jstype, holding);
                    (variant, field::value_shape(&variant.ty, holding))
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
    /// Every name of a library the code refers to unqualified, a default
    /// import's or an exposed type's, with the module it comes from.
    unqualified: BTreeMap<(Kind, String), &'static str>,
    /// How the scalars the options govern are held where a field does not
    /// say.
    holding: Holding,
    /// What an unknown enum value name reads as.
    enum_unknown: EnumUnknown,
    /// The options as the header's second line records them.
    recorded: String,
}

impl Emitter {
    fn new(module: &IrModule, options: &Options) -> Self {
        Emitter {
            module: module.clone(),
            imports: BTreeMap::new(),
            unqualified: BTreeMap::new(),
            holding: Holding::of(options),
            enum_unknown: options.enum_unknown,
            recorded: match options.recorded() {
                pairs if pairs.is_empty() => DEFAULT_OPTIONS.to_owned(),
                pairs => pairs.join(", "),
            },
        }
    }

    /// The module of `decls`, generated from `package`'s files, importing
    /// what they refer to.
    fn module(mut self, package: &Package, mut decls: Vec<Decl>) -> Module {
        decls.insert(0, self.version_value());
        Module {
            header: Some(format!(
                "{HEADER_PREFIX}{VERSION} from {}. Do not edit; regenerate instead.\n\
                 {OPTIONS_PREFIX}{}",
                package.files.join(", "),
                self.recorded,
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

    /// `elmConnectVersion_`, naming the `Proto.Version` value of this
    /// release.
    fn version_value(&mut self) -> Decl {
        Decl::Value {
            doc: Some(VERSION_VALUE_DOC.to_owned()),
            name: VERSION_VALUE.to_owned(),
            annotation: self.library_type(PROTO_VERSION, "Generated", []),
            params: Vec::new(),
            body: self.reference((PROTO_VERSION, SENTINEL)),
        }
    }

    /// The declarations of `package`, by section.
    fn package(&mut self, package: &Package) -> Vec<Decl> {
        let by_name = messages_by_name(package);
        let messages: Vec<_> = package
            .messages
            .iter()
            .map(|message| message_shape(message, &by_name, self.holding))
            .collect();
        let registry = vec![Decl::Comment("REGISTRY".into()), self.registry(package)];
        if messages.is_empty() && package.enums.is_empty() {
            return registry;
        }
        let mut types = vec![Decl::Comment("TYPES".into())];
        let mut defaults = vec![Decl::Comment("DEFAULTS".into())];
        let mut values = vec![Decl::Comment("TYPED VALUES".into())];
        let mut encoders = vec![Decl::Comment("ENCODERS".into())];
        let mut decoders = vec![Decl::Comment("DECODERS".into())];
        for enumeration in &package.enums {
            types.push(self.enum_type(&package.module, enumeration));
            values.push(self.enum_record(&package.module, enumeration));
            encoders.push(self.enum_encoder(enumeration));
            decoders.push(self.enum_decoder(enumeration));
        }
        for shape in &messages {
            types.push(self.message_alias(&package.module, shape));
            defaults.push(self.message_default(shape));
            values.push(self.message_record(&package.module, shape));
            encoders.push(self.message_encoder(shape));
            decoders.push(self.message_decoder(shape));
            if let Some(wrapper) = &shape.message.wrapper {
                types.push(self.wrapper_type(shape.message, wrapper));
                encoders.push(self.wrapper_encoder(shape.message, wrapper));
                decoders.push(self.wrapper_decoder(shape.message, wrapper));
            }
            for oneof in &shape.oneofs {
                types.push(self.oneof_type(&package.module, shape.message, oneof));
                encoders.push(self.oneof_encoder(oneof));
                decoders.push(self.oneof_decoder(oneof));
            }
        }
        // A package of enums alone has no defaults.
        if messages.is_empty() {
            defaults.clear();
        }
        types
            .into_iter()
            .chain(defaults)
            .chain(values)
            .chain(registry)
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
        self.unqualified
            .insert((Kind::Type, name.to_owned()), module);
        ty(name, args)
    }

    /// `name`, one of elm/core's [`DEFAULT_IMPORTS`], which the code then
    /// refers to unqualified.
    fn core(&mut self, name: &'static str) -> &'static str {
        let (_, module, kind) = DEFAULT_IMPORTS
            .iter()
            .find(|(default, ..)| *default == name)
            .expect("a default import");
        self.unqualified.insert((*kind, name.to_owned()), module);
        name
    }

    /// Every type or constructor `package` declares under a name its
    /// module's code also uses unqualified for a library's.
    fn reserved_names(&self, package: &Package, options: &Options) -> Vec<ReservedName> {
        // Each declaration: its Elm name and kind, how a problem names it,
        // the proto full name a rename takes, and the element.
        let mut declared: Vec<(&str, Kind, String, String, Element)> = Vec::new();
        for message in &package.messages {
            let full = &message.proto_full_name;
            let what = format!("message `{full}`");
            let element = Element::Message(full.clone());
            let mut names = vec![&message.elm_name];
            names.extend(message.wrapper.as_ref().map(|wrapper| &wrapper.elm_name));
            for name in names {
                for kind in [Kind::Type, Kind::Constructor] {
                    declared.push((name, kind, what.clone(), full.clone(), element.clone()));
                }
            }
            for oneof in &message.oneofs {
                let what = format!("oneof `{}` of `{full}`", oneof.proto_name);
                let proto = format!("{full}.{}", oneof.proto_name);
                let element = Element::Oneof {
                    message: full.clone(),
                    name: oneof.proto_name.clone(),
                };
                declared.push((
                    &oneof.elm_type_name,
                    Kind::Type,
                    what.clone(),
                    proto.clone(),
                    element.clone(),
                ));
                declared.push((&oneof.unset_ctor, Kind::Constructor, what, proto, element));
                for variant in &oneof.variants {
                    let what = format!("oneof field `{}` of `{full}`", variant.proto_name);
                    let proto = format!("{full}.{}", variant.proto_name);
                    let element = Element::Field {
                        message: full.clone(),
                        name: variant.proto_name.clone(),
                    };
                    declared.push((&variant.elm_ctor, Kind::Constructor, what, proto, element));
                }
            }
        }
        for enumeration in &package.enums {
            let full = &enumeration.proto_full_name;
            let what = format!("enum `{full}`");
            let element = Element::Enum(full.clone());
            declared.push((
                &enumeration.elm_name,
                Kind::Type,
                what,
                full.clone(),
                element,
            ));
            for value in enumeration.values() {
                let what = format!("enum value `{}` of `{full}`", value.proto_name);
                let proto = format!("{full}.{}", value.proto_name);
                let element = Element::EnumValue {
                    enumeration: full.clone(),
                    name: value.proto_name.clone(),
                };
                declared.push((&value.elm_ctor, Kind::Constructor, what, proto, element));
            }
        }
        let mut reserved = Vec::new();
        for (name, kind, what, proto, element) in declared {
            if let Some(home) = self.unqualified.get(&(kind, name.to_owned())) {
                let renamed = options
                    .rename
                    .get(&proto)
                    .is_some_and(|given| given == name);
                reserved.push(ReservedName {
                    element,
                    what,
                    kind: kind.as_str(),
                    name: name.to_owned(),
                    home,
                    rename: options.spelling.rename(&proto),
                    renamed_by: renamed.then(|| options.spelling.rename_key()),
                });
            }
        }
        reserved
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
    use crate::ir::{Cardinality, ScalarKind, TypeRef, WellKnown};
    use crate::options::Int64;

    fn package(messages: Vec<Message>) -> Package {
        Package {
            proto_name: "t.v1".into(),
            module: IrModule::new(vec!["T".into(), "V1".into()]).expect("valid"),
            files: vec!["a.proto".into(), "b.proto".into()],
            comments: Vec::new(),
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
            doc: crate::ir::Doc::default(),
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
            annotations: crate::ir::Annotations::default(),
            doc: crate::ir::Doc::default(),
        }
    }

    #[test]
    fn header_names_the_package_files_and_the_options() {
        let module = emit(&package(Vec::new()), &Options::default()).expect("emits");
        assert_eq!(
            module.header.as_deref(),
            Some(&*format!(
                "Generated by elm-connect {VERSION} from a.proto, b.proto. Do not edit; \
                 regenerate instead.\nOptions: defaults"
            ))
        );
        assert_eq!(module.name.as_str(), "T.V1");
        let options = Options::from_parameter("streaming=skip,int64=int").expect("valid");
        let module = emit(&package(Vec::new()), &options).expect("emits");
        assert_eq!(
            module
                .header
                .as_deref()
                .and_then(|header| header.lines().nth(1)),
            Some("Options: int64=int, streaming=skip")
        );
    }

    #[test]
    fn every_module_names_its_release_first() {
        let expected = format!(
            "\n\n\n{{-| {VERSION_VALUE_DOC}\n-}}\nelmConnectVersion_ : \
             Proto.Version.Generated\nelmConnectVersion_ =\n    Proto.Version.{SENTINEL}\n\n\n\n-- TYPES\n"
        );
        let one = package(vec![message("A", Vec::new())]);
        let module = emit(&one, &Options::default());
        let printed = crate::elm::print::print_module(&module.expect("emits"));
        assert!(printed.contains(&expected), "{printed}");
        let descriptors = emit_descriptor_modules(&one, &Options::default());
        assert!(matches!(
            descriptors[0].decls.as_slice(),
            [Decl::Value { name, .. }, ..] if name == VERSION_VALUE
        ));

        let service = Service {
            proto_full_name: "t.v1.S".into(),
            module: IrModule::new(vec!["T".into(), "V1".into(), "S".into()]).expect("valid"),
            methods: Vec::new(),
            doc: crate::ir::Doc::default(),
        };
        let module = emit_service(&package(Vec::new()), &service, &Options::default());
        assert!(matches!(
            module.decls.as_slice(),
            [Decl::Value { name, .. }] if name == VERSION_VALUE
        ));
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
                "Proto.Json",
                "Proto.Message",
                "Proto.Registry",
                "Proto.Version",
                "T.V1.A"
            ]
        );
        let descriptors = emit_descriptor_modules(&only_ints, &Options::default());
        let imports: Vec<&str> = descriptors[0]
            .imports
            .iter()
            .map(|i| i.module.as_str())
            .collect();
        assert_eq!(imports, ["Proto.Field", "Proto.Message", "Proto.Version"]);

        // An empty message's decoder is `Proto.Json.emptyMessage`; it has
        // no fields to describe, so no `Proto.Field`.
        let empty = package(vec![message("E", Vec::new())]);
        let module = emit(&empty, &Options::default()).expect("emits");
        let imports: Vec<&str> = module.imports.iter().map(|i| i.module.as_str()).collect();
        assert_eq!(
            imports,
            [
                "Json.Decode",
                "Json.Encode",
                "Proto.Json",
                "Proto.Message",
                "Proto.Registry",
                "Proto.Version",
                "T.V1.E"
            ]
        );
        let descriptors = emit_descriptor_modules(&empty, &Options::default());
        let imports: Vec<&str> = descriptors[0]
            .imports
            .iter()
            .map(|i| i.module.as_str())
            .collect();
        assert_eq!(imports, ["Proto.Message", "Proto.Version"]);
    }

    #[test]
    fn descriptors_hold_the_fields_and_the_registry() {
        let one = package(vec![message(
            "A",
            vec![field(
                "n",
                Cardinality::Map(crate::ir::MapKey::Bool),
                TypeRef::Scalar(ScalarKind::SFixed64),
            )],
        )]);
        let descriptors = emit_descriptor_modules(&one, &Options::default());
        assert_eq!(descriptors[0].name.as_str(), "T.V1.A");
        let a = crate::elm::print::print_module(&descriptors[0]);
        assert!(
            a.contains(
                "descriptor =\n    Proto.Message.descriptor \"t.v1.A\"\n        [ n\n        ]"
            ),
            "{a}"
        );
        assert!(
            a.contains(
                "n : Proto.Field.Descriptor\nn =\n    Proto.Field.descriptor \"n\" \"n\" 1 \
                 (Proto.Field.CardinalityMap Proto.Field.ScalarBool) \
                 (Proto.Field.KindScalar Proto.Field.ScalarSfixed64)"
            ),
            "{a}"
        );
        let on = crate::elm::print::print_module(&emit(&one, &Options::default()).expect("emits"));
        assert!(
            on.contains(
                "registry =\n    Proto.Registry.union\n        \
                 (Proto.Registry.fromDescriptors\n            \
                 [ T.V1.A.descriptor\n            ]\n            []\n        \
                 )\n        Proto.Registry.wellKnown"
            ),
            "{on}"
        );
        assert!(
            on.contains(
                "messageA =\n    Proto.Message.message encodeA decodeA defaultA T.V1.A.descriptor"
            ),
            "{on}"
        );
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
            [
                "TYPES",
                "DEFAULTS",
                "TYPED VALUES",
                "REGISTRY",
                "ENCODERS",
                "DECODERS"
            ]
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
            ["TYPES", "TYPED VALUES", "REGISTRY", "ENCODERS", "DECODERS"]
        );
        assert_eq!(sections(&package(Vec::new())), ["REGISTRY"]);
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
                "Proto.Json",
                "Proto.Message",
                "Proto.Registry",
                "Proto.Version",
                "T.V1.A"
            ]
        );
        let printed = crate::elm::print::print_module(&module);
        assert!(printed.contains("b : Maybe Other.V1.B"), "{printed}");
        assert!(
            printed.contains("(Proto.Registry.union Other.V1.registry Proto.Registry.wellKnown)"),
            "{printed}"
        );
        assert!(
            printed.contains("Maybe.map Other.V1.encodeB value.b"),
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
        let one = package(vec![message(
            "A",
            vec![field(
                "level",
                Cardinality::Singular,
                TypeRef::Enum {
                    name: elsewhere,
                    zero_ctor: "LevelNone".into(),
                },
            )],
        )]);
        let module = emit(&one, &Options::default()).expect("emits");
        let printed = crate::elm::print::print_module(&module);
        assert!(printed.contains("level : Other.V1.Level"), "{printed}");
        assert!(
            printed.contains(r#"Proto.Json.field "level" Other.V1.LevelNone Other.V1.decodeLevel"#),
            "{printed}"
        );
        let descriptors = emit_descriptor_modules(&one, &Options::default());
        let printed = crate::elm::print::print_module(&descriptors[0]);
        assert!(
            printed.contains("(Proto.Field.KindEnum Other.V1.Level.descriptor)"),
            "{printed}"
        );
        assert!(printed.contains("import Other.V1.Level\n"), "{printed}");
    }

    #[test]
    fn a_method_carries_codecs_not_typed_records() {
        let a = TypeName {
            module: IrModule::new(vec!["T".into(), "V1".into()]).expect("valid"),
            name: "A".into(),
            proto_full_name: "t.v1.A".into(),
        };
        let method = |name: &str, input: TypeRef, output: TypeRef| crate::ir::Method {
            proto_name: name.into(),
            elm_name: name.to_lowercase(),
            input,
            output,
            idempotency: crate::ir::Idempotency::Unknown,
            http: None,
            routes: Vec::new(),
            doc: crate::ir::Doc::default(),
            server_streaming: false,
        };
        let service = Service {
            proto_full_name: "t.v1.S".into(),
            module: IrModule::new(vec!["T".into(), "V1".into(), "S".into()]).expect("valid"),
            methods: vec![
                method(
                    "Get",
                    TypeRef::Message(a.clone()),
                    TypeRef::Message(a.clone()),
                ),
                method(
                    "Identity",
                    TypeRef::WellKnown(WellKnown::Value),
                    TypeRef::WellKnown(WellKnown::Empty),
                ),
                method(
                    "Ticks",
                    TypeRef::WellKnown(WellKnown::Int64Value),
                    TypeRef::WellKnown(WellKnown::Any),
                ),
            ],
            doc: crate::ir::Doc::default(),
        };
        let options = Options {
            int64: Int64::Int,
            ..Options::default()
        };
        let module = emit_service(&package(Vec::new()), &service, &options);
        let imports: Vec<&str> = module.imports.iter().map(|i| i.module.as_str()).collect();
        assert_eq!(
            imports,
            [
                "Json.Encode",
                "Proto.Any",
                "Proto.Json",
                "Proto.Method",
                "Proto.Version",
                "Rpc",
                "T.V1"
            ]
        );
        let sections: Vec<&str> = module
            .decls
            .iter()
            .filter_map(|decl| match decl {
                Decl::Comment(section) => Some(section.as_str()),
                _ => None,
            })
            .collect();
        assert_eq!(sections, ["CALLS", "DESCRIPTORS"]);
        let printed = crate::elm::print::print_module(&module);
        for expected in [
            "(Proto.Method.method T.V1.encodeA\n            T.V1.decodeA\n            descriptorGet\n",
            // Qualified, or `identity` would be the method itself.
            "(Proto.Method.method Basics.identity\n            Proto.Json.empty\n            \
             descriptorIdentity\n",
            "(Proto.Method.method Proto.Json.encodeInt64AsInt\n            \
             Proto.Json.any\n            descriptorTicks\n",
            "descriptorGet : Proto.Method.Descriptor\ndescriptorGet =\n    \
             Proto.Method.descriptor \"t.v1.S\"\n        \"Get\"\n        \
             Proto.Method.IdempotencyUnknown\n        \
             \"t.v1.A\"\n        \"t.v1.A\"\n        []\n",
        ] {
            assert!(printed.contains(expected), "{expected}\n{printed}");
        }
    }
}
