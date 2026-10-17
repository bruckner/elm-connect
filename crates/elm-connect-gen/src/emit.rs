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
//!   release (design §8). A package's module then holds five sections in
//!   order: types, defaults, descriptors,
//!   encoders, decoders. Each section has the enums, then the messages,
//!   each followed by its recursion wrapper and its oneofs; the defaults
//!   section has the messages alone, and is left out when there are none,
//!   and the descriptors section has each enum's and message's typed
//!   value.
//! - A service's module, `Notes.V1.NotesService`, holds one function per
//!   method from its request to an `Rpc.Call`, written point-free as
//!   `Rpc.call` of the method's `Proto.Method.Method`, built by
//!   `Proto.Method.method` from the encoder of its request and the decoder
//!   of its response (`Notes.V1.encodeGetNoteRequest`, or the runtime's
//!   for a well-known type) and its descriptor, holding its
//!   service, name, idempotency, type names and bindings, the bindings
//!   its HTTP rule's own and then its additional ones, as data
//!   (`Proto.Http.binding`). A method without a rule has no
//!   bindings, and the runtime calls it over the implicit route. Every
//!   name the module refers to is qualified, so a method's name cannot
//!   shadow or clash with one.
//! - A message's typed value, `messageFoo : Proto.Message.Message Foo`,
//!   is built by `Proto.Message.message` from its encoder, decoder and
//!   default and its descriptor; an enum's, `enumBar : Proto.Enum.Enum
//!   Bar`, by `Proto.Enum.enum` from its encoder, decoder and zero value
//!   and its descriptor, every declared name with its number. The
//!   message descriptors are written inline, faithful to the proto: each
//!   field's names, number, cardinality, kind (other types by full name)
//!   and oneof. The section ends with the package's `registry`: its own
//!   descriptors, then the registries of the packages its module imports
//!   and the well-known types', so it is transitive.
//! - A message is a record type alias, a default value (`defaultFoo :
//!   Foo`, every field at its proto3 default and every oneof unset), an
//!   encoder (`Foo -> Json.Encode.Value`) and a decoder
//!   (`Json.Decode.Decoder Foo`).
//! - Encoders are `Proto.Json.object` over one `( jsonName, Maybe Value )`
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
//!   as strings under [`Int64::Int`], a field's `jstype` overriding the
//!   option either way.
//! - A map field is a `Dict`, keyed by `String` (string and 64-bit integer
//!   keys) or `Int` (32-bit integer keys), encoded with
//!   `Proto.Json.dict`; absent or `null` decodes as `Dict.empty`. A map
//!   with `bool` keys, which Elm cannot put in a `Dict`, is a
//!   `List ( Bool, v )` read and written by `Proto.Json.boolMap` and
//!   `boolDict`; absent or `null` decodes as `[]`.
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
mod enumeration;
mod field;
mod message;
mod method;
mod oneof;
mod recursion;
mod scalar;

use std::collections::{BTreeMap, BTreeSet, HashMap};

use crate::diagnostics::{Diagnostics, Problem};
use crate::elm::ast::{Decl, Exposed, Exposing, Expr, Import, Module, ModuleName, Type};
use crate::elm::build::{apply, qualified, ty, ty_qualified, var};
use crate::ir::{
    Field, Message, ModuleName as IrModule, Oneof, OneofVariant, Package, Service, TypeName,
};
use crate::naming::VERSION_VALUE;
use crate::options::{EnumUnknown, Int64, Options};
use crate::{HEADER_PREFIX, SENTINEL, VERSION};

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
/// The runtime package's typed message values.
const PROTO_MESSAGE: &str = "Proto.Message";
/// The runtime package's typed method values.
const PROTO_METHOD: &str = "Proto.Method";
/// The runtime package's typed enum values.
const PROTO_ENUM: &str = "Proto.Enum";
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

/// The Elm module for `package`. Every construct a built IR holds has an
/// emitter, so this does not fail today; the error is the problems found,
/// for constructs to come whose emitters may report some.
pub fn emit(package: &Package, options: &Options) -> Result<Module, Diagnostics> {
    let mut emitter = Emitter::new(&package.module, options);
    let decls = emitter.package(package);
    let reserved = emitter.reserved_names(package, options);
    if !reserved.is_empty() {
        return Err(reserved);
    }
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
    /// Every name of a library the code refers to unqualified, a default
    /// import's or an exposed type's, with the module it comes from.
    unqualified: BTreeMap<(Kind, String), &'static str>,
    /// How 64-bit integers are held where a field does not say.
    int64: Int64,
    /// What an unknown enum value name reads as.
    enum_unknown: EnumUnknown,
}

impl Emitter {
    fn new(module: &IrModule, options: &Options) -> Self {
        Emitter {
            module: module.clone(),
            imports: BTreeMap::new(),
            unqualified: BTreeMap::new(),
            int64: options.int64,
            enum_unknown: options.enum_unknown,
        }
    }

    /// The module of `decls`, generated from `package`'s files, importing
    /// what they refer to.
    fn module(mut self, package: &Package, mut decls: Vec<Decl>) -> Module {
        decls.insert(0, self.version_value());
        Module {
            header: Some(format!(
                "{HEADER_PREFIX}{VERSION} from {}. Do not edit; regenerate instead.",
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
            return vec![Decl::Comment("DESCRIPTORS".into()), self.registry(package)];
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
        descriptors.push(self.registry(package));
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

    /// A `naming::reserved_name` problem for every type or constructor
    /// `package` declares under a name its module's code also uses
    /// unqualified for a library's.
    fn reserved_names(&self, package: &Package, options: &Options) -> Diagnostics {
        let mut declared: Vec<(&str, Kind, String, String)> = Vec::new();
        for message in &package.messages {
            let full = &message.proto_full_name;
            let what = format!("message `{full}`");
            declared.push((&message.elm_name, Kind::Type, what.clone(), full.clone()));
            declared.push((
                &message.elm_name,
                Kind::Constructor,
                what.clone(),
                full.clone(),
            ));
            if let Some(wrapper) = &message.wrapper {
                declared.push((&wrapper.elm_name, Kind::Type, what.clone(), full.clone()));
                declared.push((&wrapper.elm_name, Kind::Constructor, what, full.clone()));
            }
            for oneof in &message.oneofs {
                let what = format!("oneof `{}` of `{full}`", oneof.proto_name);
                let proto = format!("{full}.{}", oneof.proto_name);
                declared.push((
                    &oneof.elm_type_name,
                    Kind::Type,
                    what.clone(),
                    proto.clone(),
                ));
                declared.push((&oneof.unset_ctor, Kind::Constructor, what, proto));
                for variant in &oneof.variants {
                    let what = format!("oneof field `{}` of `{full}`", variant.proto_name);
                    let proto = format!("{full}.{}", variant.proto_name);
                    declared.push((&variant.elm_ctor, Kind::Constructor, what, proto));
                }
            }
        }
        for enumeration in &package.enums {
            let full = &enumeration.proto_full_name;
            let what = format!("enum `{full}`");
            declared.push((&enumeration.elm_name, Kind::Type, what, full.clone()));
            for value in enumeration.values() {
                let what = format!("enum value `{}` of `{full}`", value.proto_name);
                let proto = format!("{full}.{}", value.proto_name);
                declared.push((&value.elm_ctor, Kind::Constructor, what, proto));
            }
        }
        let mut problems = Diagnostics::new();
        for (name, kind, what, proto) in declared {
            if let Some(home) = self.unqualified.get(&(kind, name.to_owned())) {
                let rename = options.spelling.rename(&proto);
                problems.push(Problem::reserved_name(
                    &what,
                    kind.as_str(),
                    name,
                    home,
                    &rename,
                ));
            }
        }
        problems
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
    fn every_module_names_its_release_first() {
        let expected = format!(
            "import Proto.Version\n\n\n{{-| {VERSION_VALUE_DOC}\n-}}\nelmConnectVersion_ : \
             Proto.Version.Generated\nelmConnectVersion_ =\n    Proto.Version.{SENTINEL}\n\n\n\n-- TYPES\n"
        );
        let module = emit(
            &package(vec![message("A", Vec::new())]),
            &Options::default(),
        );
        let printed = crate::elm::print::print_module(&module.expect("emits"));
        assert!(printed.contains(&expected), "{printed}");

        let service = Service {
            proto_full_name: "t.v1.S".into(),
            module: IrModule::new(vec!["T".into(), "V1".into(), "S".into()]).expect("valid"),
            methods: Vec::new(),
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
                "Proto.Descriptor",
                "Proto.Json",
                "Proto.Message",
                "Proto.Registry",
                "Proto.Version"
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
                "Proto.Registry",
                "Proto.Version"
            ]
        );
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
                 [ Proto.Message.descriptor messageA ] []) Proto.Registry.wellKnown"
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
                "Proto.Registry",
                "Proto.Version"
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
            idempotent: false,
            http: None,
            routes: Vec::new(),
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
        let printed = crate::elm::print::print_module(&module);
        for expected in [
            "(Proto.Method.method T.V1.encodeA\n            T.V1.decodeA\n",
            // Qualified, or `identity` would be the method itself.
            "(Proto.Method.method Basics.identity\n            Proto.Json.empty\n",
            "(Proto.Method.method Proto.Json.encodeInt64AsInt\n            Proto.Any.jsonDecoder\n",
        ] {
            assert!(printed.contains(expected), "{expected}\n{printed}");
        }
    }
}
