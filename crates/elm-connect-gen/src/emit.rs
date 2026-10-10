//! The emitter: one IR [`Package`] to one Elm [`Module`] of record types
//! and their proto3 JSON codecs (design §2 layer 1, §3).
//!
//! Invariant: every name comes from the IR, every layout from the printer.
//! The emitter chooses which declarations exist and what their bodies say;
//! the Elm names of types, fields and codecs come from [`crate::ir`] (which
//! takes them from [`crate::naming`]), and the text is
//! [`crate::elm::print`]'s. The only names written here are those of the
//! libraries generated code calls: elm/json and the runtime package.
//!
//! The rules the emitter applies today:
//!
//! - A module opens with a generated-file notice, imports exactly the
//!   modules its code refers to (beyond those Elm imports by default),
//!   and holds three sections in order: types, encoders, decoders. Each section has the enums, then the messages,
//!   each followed by its oneofs.
//! - A message is a record type alias, an encoder
//!   (`Foo -> Json.Encode.Value`) and a decoder (`Json.Decode.Decoder Foo`).
//! - Encoders emit every field, default values included. proto3 JSON lets
//!   a writer omit or include them; always including them keeps the
//!   encoder one expression per field. This is the current rule, not yet
//!   reviewed (design §3.4).
//! - Decoders are a pipeline of `Connect.Json.field` steps from
//!   `Json.Decode.succeed`, so they read the same at any field count
//!   (design §8). A missing or `null` field reads as its proto3 zero value.
//!   A field whose JSON name differs from its proto name uses
//!   `Connect.Json.fieldEither`, which accepts both keys (design §3.4).
//! - A field with presence (proto3 `optional`, or message-typed) is a
//!   `Maybe`: `Nothing` encodes as `null`, and an absent or `null` field
//!   decodes as `Nothing`. A repeated field is a `List`, encoded as an
//!   array; absent or `null` decodes as `[]`. Both reuse the one
//!   `Connect.Json.field` step with `Nothing` or `[]` as its zero value.
//!
//! - An enum is a custom type, its zero value first, with an encoder that
//!   writes each constructor's proto name and a `Connect.Json.enum`
//!   decoder that reads a name or a number, an unknown one as the zero
//!   value (design §3.3).
//!
//! - A oneof is a custom type whose first constructor is the unset case,
//!   held in one record field where its first member was declared. Its
//!   encoder gives the set member's key and value for the message's
//!   object; its decoder tries each member with `Json.Decode.oneOf` and
//!   falls back to unset (design §3.6).
//!
//! - A map field is a `Dict`, keyed by `String` (string and 64-bit integer
//!   keys) or `Int` (32-bit integer keys), encoded with
//!   `Json.Encode.dict`; absent or `null` decodes as `Dict.empty`.
//!
//! - The well-known types map to `Time.Posix`, the runtime's `Duration`,
//!   `List String` (field masks), `()` (`Empty`), `Json.Encode.Value`
//!   (`Struct`, `Value`, `ListValue`) and the wrappers' scalars (design
//!   §3.5). The first four and the wrappers are messages, held with
//!   presence; JSON is held directly, `null` when absent.
//!
//! Everything but recursive messages is emitted so far. Every other construct
//! is reported as [`Code::Unimplemented`](crate::diagnostics::Code) through
//! [`crate::diagnostics`], never a panic, so a user meets an ordinary
//! diagnostic until its emitter lands.

mod enumeration;
mod field;
mod message;
mod oneof;
mod scalar;

use std::collections::{BTreeMap, BTreeSet};

use crate::VERSION;
use crate::diagnostics::{Diagnostics, Problem};
use crate::elm::ast::{Decl, Exposed, Exposing, Expr, Import, Module, ModuleName, Type};
use crate::elm::build::{apply, qualified, ty, ty_qualified, var};
use crate::ir::{Field, Message, ModuleName as IrModule, Oneof, OneofVariant, Package, TypeName};

use self::field::{FieldShape, ValueShape};

/// elm/json's decoders.
const JSON_DECODE: &str = "Json.Decode";
/// elm/json's encoders.
const JSON_ENCODE: &str = "Json.Encode";
/// The runtime package's proto3 JSON helpers.
const CONNECT_JSON: &str = "Connect.Json";
/// elm/core's `Dict`, imported as `import Dict exposing (Dict)` so the
/// type reads `Dict String V`, as Elm code conventionally writes it.
const CORE_DICT: &str = "Dict";
/// elm/core's `String`, which every Elm module imports by default.
const CORE_STRING: &str = "String";
/// elm/time's `Time`, for `Time.Posix`.
const TIME: &str = "Time";
/// The runtime package's `Duration`, imported as
/// `import Connect.Duration exposing (Duration)`.
const CONNECT_DURATION: &str = "Connect.Duration";

/// How to generate. Nothing is configurable yet; the options design §6
/// lists arrive with the features they control.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
#[non_exhaustive]
pub struct Options {}

/// The Elm module for `package`, or every construct in it that has no
/// emitter yet.
pub fn emit(package: &Package, _options: &Options) -> Result<Module, Diagnostics> {
    let mut emitter = Emitter {
        module: package.module.clone(),
        imports: BTreeMap::new(),
        diagnostics: Diagnostics::new(),
    };
    let decls = emitter.package(package);
    if !emitter.diagnostics.is_empty() {
        return Err(emitter.diagnostics);
    }
    Ok(Module {
        header: Some(format!(
            "Generated by elm-connect {VERSION} from {}. Do not edit; regenerate instead.",
            package.files.join(", ")
        )),
        name: ModuleName::new(package.module.to_string()),
        doc: None,
        exposing: Exposing::All,
        imports: emitter
            .imports
            .into_iter()
            .map(|(module, types)| Import {
                module: ModuleName::new(module),
                alias: None,
                exposing: (!types.is_empty())
                    .then(|| Exposing::Explicit(types.into_iter().map(Exposed::Type).collect())),
            })
            .collect(),
        decls,
    })
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

/// The state of emitting one module: the library modules its code refers
/// to so far, and the problems found.
struct Emitter {
    module: IrModule,
    /// Each module imported, with the types its import exposes.
    imports: BTreeMap<String, BTreeSet<String>>,
    diagnostics: Diagnostics,
}

impl Emitter {
    /// The declarations of `package`, by section.
    fn package(&mut self, package: &Package) -> Vec<Decl> {
        let messages: Vec<_> = package
            .messages
            .iter()
            .filter_map(|message| self.message_shape(message))
            .collect();
        if messages.is_empty() && package.enums.is_empty() {
            return Vec::new();
        }
        let mut types = vec![Decl::Comment("TYPES".into())];
        let mut encoders = vec![Decl::Comment("ENCODERS".into())];
        let mut decoders = vec![Decl::Comment("DECODERS".into())];
        for enumeration in &package.enums {
            types.push(self.enum_type(enumeration));
            encoders.push(self.enum_encoder(enumeration));
            decoders.push(self.enum_decoder(enumeration));
        }
        for shape in &messages {
            types.push(self.message_alias(shape));
            encoders.push(self.message_encoder(shape));
            decoders.push(self.message_decoder(shape));
            for oneof in &shape.oneofs {
                types.push(self.oneof_type(oneof));
                encoders.push(self.oneof_encoder(oneof));
                decoders.push(self.oneof_decoder(oneof));
            }
        }
        types.into_iter().chain(encoders).chain(decoders).collect()
    }

    /// `message` with the shape of each of its fields and oneof members, or
    /// `None` once every unsupported construct in it is reported.
    fn message_shape<'m>(&mut self, message: &'m Message) -> Option<MessageShape<'m>> {
        let before = self.diagnostics.len();
        if message.recursive {
            self.unimplemented(&message.proto_full_name, "a recursive message");
        }
        let fields: Vec<_> = message
            .fields
            .iter()
            .map(|field| (field, field::field_shape(field)))
            .collect();
        let oneofs = message
            .oneofs
            .iter()
            .map(|oneof| OneofShape {
                oneof,
                variants: oneof
                    .variants
                    .iter()
                    .map(|variant| (variant, field::value_shape(&variant.ty)))
                    .collect(),
            })
            .collect();
        (self.diagnostics.len() == before).then_some(MessageShape {
            message,
            fields,
            oneofs,
        })
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

    fn unimplemented(&mut self, element: &str, construct: &str) {
        self.diagnostics
            .push(Problem::unimplemented(element, construct));
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
    use crate::diagnostics::Code;
    use crate::ir::{Cardinality, ScalarKind, TypeRef};

    fn package(messages: Vec<Message>) -> Package {
        Package {
            proto_name: "t.v1".into(),
            module: IrModule::new(vec!["T".into(), "V1".into()]).expect("valid"),
            files: vec!["a.proto".into(), "b.proto".into()],
            messages,
            enums: Vec::new(),
        }
    }

    fn message(name: &str, fields: Vec<Field>) -> Message {
        Message {
            proto_full_name: format!("t.v1.{name}"),
            elm_name: name.into(),
            fields,
            oneofs: Vec::new(),
            recursive: false,
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
        }
    }

    fn problems(package: &Package) -> Vec<(Code, String)> {
        let diagnostics = emit(package, &Options::default()).expect_err("unsupported");
        diagnostics
            .iter()
            .map(|p| (p.code(), p.message().to_owned()))
            .collect()
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
        assert_eq!(imports, ["Connect.Json", "Json.Decode", "Json.Encode"]);

        let empty = package(vec![message("E", Vec::new())]);
        let module = emit(&empty, &Options::default()).expect("emits");
        let imports: Vec<&str> = module.imports.iter().map(|i| i.module.as_str()).collect();
        assert_eq!(imports, ["Json.Decode", "Json.Encode"]);
    }

    #[test]
    fn unsupported_constructs_are_diagnostics() {
        let mut recursive = message("R", Vec::new());
        recursive.recursive = true;
        let problems = problems(&package(vec![recursive]));
        assert_eq!(
            problems,
            [(
                Code::Unimplemented,
                "`t.v1.R` is a recursive message, which elm-connect cannot generate yet.".into()
            )]
        );
    }

    #[test]
    fn other_modules_are_qualified_and_imported() {
        let elsewhere = TypeName {
            module: IrModule::new(vec!["Other".into(), "V1".into()]).expect("valid"),
            name: "B".into(),
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
            ["Connect.Json", "Json.Decode", "Json.Encode", "Other.V1"]
        );
        let printed = crate::elm::print::print_module(&module);
        assert!(printed.contains("b : Maybe Other.V1.B"), "{printed}");
        assert!(
            printed.contains("Connect.Json.encodeMaybe Other.V1.encodeB value.b"),
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
            printed
                .contains(r#"Connect.Json.field "level" Other.V1.LevelNone Other.V1.decodeLevel"#),
            "{printed}"
        );
    }
}
