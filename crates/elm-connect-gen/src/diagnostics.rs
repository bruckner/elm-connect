//! Diagnostics shared by both entry points: what the generator reports
//! about a user's protos, and how it renders.
//!
//! Every [`Problem`] has a short [`Code`], a message saying what was found,
//! and a help sentence saying what was expected, in the register of Elm's
//! compiler. A problem points at its proto sources through [`Site`]s:
//! a file name and, when the compiler recorded source info, a line and
//! column span. Turning those into snippets needs the source text, which
//! the protoc plugin does not have; [`Diagnostics::attach_sources`] adds it
//! when it is known, and a problem without it still renders, naming the
//! proto elements by their full names.
//!
//! Most problems are errors, which fail the run. A few are warnings,
//! reported beside a successful run: what an option told the generator to
//! leave out (`streaming=skip`), so the omission is never silent, a
//! module name that compiles but is a risk to the application (one in the
//! runtime's namespaces, or one an elm/* package has), and two HTTP
//! bindings that match the same requests.

mod field_names;
mod spans;

use std::collections::HashMap;
use std::fmt;
use std::sync::Arc;

use crate::options::Spelling;
use miette::{
    Diagnostic, GraphicalReportHandler, GraphicalTheme, LabeledSpan, NamedSource, Severity,
    SourceCode,
};

pub use field_names::{
    FIRST_LABEL as FIELD_NAME_CONFLICT_FIRST, FieldNameConflict,
    SECOND_LABEL as FIELD_NAME_CONFLICT_SECOND, field_name_conflict_names, field_name_conflicts,
};
pub use spans::{Columns, LineColSpan, Spans, tag};

/// Declares [`Code`], its rendering and [`Code::ALL`] from one list, so
/// no code can be added to one and missed by the others.
macro_rules! codes {
    ($($(#[$doc:meta])* $variant:ident => $code:literal,)*) => {
        /// The kinds of problem the generator reports. `docs/diagnostics.md`
        /// lists them, and a test holds that list to this one.
        #[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
        pub enum Code {
            $($(#[$doc])* $variant,)*
        }

        impl Code {
            /// Every code, in the order declared.
            pub const ALL: &'static [Code] = &[$(Code::$variant,)*];

            /// The short code shown with the diagnostic.
            pub fn as_str(self) -> &'static str {
                match self {
                    $(Code::$variant => $code,)*
                }
            }
        }
    };
}

codes! {
    /// A file to generate is not among the compiled files.
    UnknownFile => "input::unknown_file",
    /// A file named to the CLI, or a file it imports, is under none of
    /// the include paths.
    FileNotFound => "input::file_not_found",
    /// A file to generate is not proto3.
    NotProto3 => "input::not_proto3",
    /// A file declares an edition (`edition = "2023";`), which elm-connect
    /// does not support.
    Editions => "input::editions",
    /// A file's name cannot be written into a generated module's header.
    FileName => "input::file_name",
    /// Two fields of a message have names that are the same once
    /// lowercased without underscores (`aB` and `ab`), which the protobuf
    /// front end refuses although protoc accepts them.
    FieldNameConflict => "input::field_name_conflict",
    /// The plugin parameter names an option that does not exist, gives a
    /// known option a value it does not take, or holds a pair without
    /// `=`.
    UnknownOption => "options::unknown_option",
    /// An option other than `rename` is given twice, or `rename` renames
    /// one proto element twice.
    DuplicateOption => "options::duplicate_option",
    /// A `rename` is not `<proto full name>:<Elm name>`, names an enum
    /// value alias, or gives a name the element it renames cannot take.
    InvalidRename => "options::invalid_rename",
    /// A `rename` names nothing that is generated.
    UnknownRename => "options::unknown_rename",
    /// `module_prefix` is not an Elm module name.
    InvalidModulePrefix => "options::invalid_module_prefix",
    /// A package has no Elm module name.
    InvalidModule => "naming::invalid_module",
    /// A message or enum has no valid Elm type name.
    InvalidType => "naming::invalid_type",
    /// A field or oneof has no valid Elm record field name.
    InvalidField => "naming::invalid_field",
    /// A method has no valid Elm value name.
    InvalidMethod => "naming::invalid_method",
    /// A service has no valid Elm module name.
    InvalidService => "naming::invalid_service",
    /// Two fields (or a field and a oneof) of a message become the same
    /// Elm record field.
    FieldCollision => "naming::field_collision",
    /// Two messages, enums or oneofs of a package become the same Elm type.
    TypeCollision => "naming::type_collision",
    /// Two enum values, oneof cases or message record constructors of a
    /// package become the same Elm constructor.
    ConstructorCollision => "naming::constructor_collision",
    /// Two methods of a service get the same Elm value name, a method gets
    /// another method's descriptor's name, or two fields of a message (or
    /// one and the message's descriptor) get the same value name in its
    /// descriptor module.
    ValueCollision => "naming::value_collision",
    /// Under `codec=proto` or `codec=both`, a type named for another
    /// with `Bytes` at the end has JSON codecs that take the names of the
    /// other's binary codecs.
    CodecCollision => "naming::codec_collision",
    /// Two generated modules, each a package's, a service's or a type's
    /// descriptor module, get the same Elm module name.
    ModuleCollision => "naming::module_collision",
    /// A type or constructor of a generated module takes a name the
    /// module's code uses unqualified for a library's.
    ReservedName => "naming::reserved_name",
    /// A generated module takes the name of a module of the runtime
    /// package or of a package it depends on, or has a segment Windows
    /// reserves as a file name.
    ReservedModule => "naming::reserved_module",
    /// Generated modules are named `Rpc` or `Proto` or sit inside one, the
    /// runtime's namespaces, where it may add modules in any release: a
    /// warning.
    RuntimeNamespace => "naming::runtime_namespace",
    /// A generated module takes the name of a module of an elm/* package
    /// an application commonly depends on (`Html`), which that application
    /// then cannot import: a warning.
    ShadowingModule => "naming::shadowing_module",
    /// A field uses a `google.protobuf` type with no Elm mapping.
    UnsupportedWellKnown => "types::unsupported_well_known",
    /// A method streams requests or responses.
    Streaming => "services::streaming",
    /// A method has no `google.api.http` rule, under
    /// `unbound_methods=error`.
    UnboundMethod => "services::unbound_method",
    /// An HTTP rule has no pattern, or nests additional bindings.
    RouteRule => "route::rule",
    /// An HTTP rule's path template does not parse, or has a wildcard
    /// outside a variable.
    RouteTemplate => "route::template",
    /// A path variable names no field a path can hold.
    RoutePathField => "route::path_field",
    /// `body` names no message field of the request.
    RouteBodyField => "route::body_field",
    /// `response_body` names no field of the response.
    RouteResponseBody => "route::response_body",
    /// A request field that would be a query parameter has no query form.
    RouteQueryField => "route::query_field",
    /// Two bindings of the generated methods have one HTTP method and one
    /// path shape, so they match the same requests and no router serves
    /// both: a warning.
    AmbiguousBinding => "route::ambiguous_binding",
    /// A generated package refers to a type in a package not generated.
    NotGenerated => "generate::not_generated",
    /// Generated packages refer to each other in a cycle.
    ImportCycle => "generate::import_cycle",
}

impl fmt::Display for Code {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// What refers to a type, as a problem names it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Referrer {
    /// A field (or oneof member) `field` of the message `message`.
    Field {
        /// The message's full name.
        message: String,
        /// The field's proto name.
        field: String,
    },
    /// The request type of the method `method` (its full name).
    Request(String),
    /// The response type of the method `method` (its full name).
    Response(String),
}

impl fmt::Display for Referrer {
    /// The referrer as the subject of a sentence: "The field `title` of
    /// `notes.v1.Note`", "The request of `notes.v1.Notes.GetNote`".
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Referrer::Field { message, field } => write!(f, "The field `{field}` of `{message}`"),
            Referrer::Request(method) => write!(f, "The request of `{method}`"),
            Referrer::Response(method) => write!(f, "The response of `{method}`"),
        }
    }
}

/// A place in a proto file a problem points at.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Site {
    /// The proto file name, as the compiler knows it.
    pub file: String,
    /// The span the compiler recorded, if it recorded source info.
    pub span: Option<LineColSpan>,
    /// What is at this place, shown beside the snippet.
    pub label: String,
    /// What to underline within the span once the source text is known,
    /// when the compiler recorded a span wider than what the problem is
    /// about: needles found in turn, as [`spans::narrow`] takes them.
    /// Empty for the whole span.
    pub within: Vec<String>,
}

/// One problem in the user's protos.
#[derive(Clone, Debug)]
pub struct Problem {
    code: Code,
    warning: bool,
    message: String,
    help: String,
    sites: Vec<Site>,
    /// Boxed, so a `Problem` stays small enough to return in a `Result`.
    attached: Option<Box<Attached>>,
    /// Whether the problem names its sites' locations in its text, which
    /// it does once [`Diagnostics::locate`] asks and no source is attached.
    located: bool,
}

/// The source snippets of a problem, once its source text is known.
#[derive(Clone, Debug)]
struct Attached {
    source: NamedSource<Arc<str>>,
    labels: Vec<LabeledSpan>,
    elsewhere: Vec<Elsewhere>,
}

/// The sites of a problem that lie in another file than its first one,
/// shown as a related note with that file's snippet.
#[derive(Clone, Debug)]
struct Elsewhere {
    message: String,
    source: NamedSource<Arc<str>>,
    labels: Vec<LabeledSpan>,
}

impl Problem {
    fn new(code: Code, message: String, help: impl Into<String>, sites: Vec<Site>) -> Self {
        Problem {
            code,
            warning: false,
            message,
            help: help.into(),
            sites,
            attached: None,
            located: false,
        }
    }

    /// The problem as a warning: reported, but not failing the run.
    fn warning(self) -> Self {
        Problem {
            warning: true,
            ..self
        }
    }

    /// What kind of problem this is.
    pub fn code(&self) -> Code {
        self.code
    }

    /// Whether this is a warning, which a successful run reports beside its
    /// output, rather than an error, which fails the run.
    pub fn is_warning(&self) -> bool {
        self.warning
    }

    /// What was found.
    pub fn message(&self) -> &str {
        &self.message
    }

    /// What was expected, and what to do about it.
    pub fn help_text(&self) -> &str {
        &self.help
    }

    /// The places the problem points at, the main one first.
    pub fn sites(&self) -> &[Site] {
        &self.sites
    }

    /// Two fields of `message` become the same Elm record field `elm_name`.
    pub fn field_collision(
        message: &str,
        elm_name: &str,
        first: Site,
        second: Site,
        rename: &str,
        renamed: Option<&str>,
    ) -> Self {
        Problem::new(
            Code::FieldCollision,
            format!("The message `{message}` has two fields that both become `{elm_name}` in Elm."),
            format!(
                "Elm record fields are the proto field names in lowerCamelCase, so names that \
                 differ only in underscores, the case of their leading capitals or reserved-word \
                 escaping end up the same (`ID` and `id`), and a record cannot have two fields \
                 with one name. {}",
                rename_escape(
                    renamed,
                    format!("Rename one of them in the proto, or rename one with {rename}.")
                )
            ),
            vec![first, second],
        )
    }

    /// Two definitions of `package` become the same Elm type `elm_name`;
    /// with `records`, both are messages, and so their record
    /// constructors are the same too.
    pub fn type_collision(
        package: &str,
        elm_name: &str,
        first: Site,
        second: Site,
        rename: &str,
        records: bool,
        renamed: Option<&str>,
    ) -> Self {
        let (definitions, becomes, constructors) = if records {
            (
                "messages",
                "the Elm type and record constructor",
                " A message's record constructor takes its type's name, so the two collide as \
                 constructors too, and one rename parts both.",
            )
        } else {
            ("definitions", "the Elm type", "")
        };
        Problem::new(
            Code::TypeCollision,
            format!(
                "The package `{package}` has two {definitions} that both become {becomes} \
                 `{elm_name}`."
            ),
            format!(
                "Every message, enum and oneof of a package becomes a type in one Elm module, \
                 nested names joined (`Outer.Inner` becomes `OuterInner`), and a module cannot \
                 define two types with one name.{constructors} {}",
                rename_escape(
                    renamed,
                    format!("Rename one of them in the proto, or rename one with {rename}.")
                )
            ),
            vec![first, second],
        )
    }

    /// Two definitions of `package` become the same Elm constructor
    /// `elm_name`.
    pub fn constructor_collision(
        package: &str,
        elm_name: &str,
        first: Site,
        second: Site,
        rename: &str,
        renamed: Option<&str>,
    ) -> Self {
        Problem::new(
            Code::ConstructorCollision,
            format!(
                "The package `{package}` has two definitions that both become the Elm \
                 constructor `{elm_name}`."
            ),
            format!(
                "Enum values, oneof cases and the record constructor of every message all share \
                 one constructor namespace in an Elm module, so these cannot both keep this name. \
                 {}",
                rename_escape(
                    renamed,
                    format!("Rename one of them in the proto, or rename one with {rename}.")
                )
            ),
            vec![first, second],
        )
    }

    /// `file` declares no package.
    pub fn missing_package(site: Site) -> Self {
        let file = site.file.clone();
        Problem::new(
            Code::InvalidModule,
            format!("The file `{file}` has no package declaration."),
            "elm-connect generates one Elm module per proto package, so every generated file \
             needs a package, like `package notes.v1;`.",
            vec![site],
        )
    }

    /// `package` has a `segment` that does not start with a letter.
    pub fn invalid_module(package: &str, segment: &str, site: Site, rename: &str) -> Self {
        Problem::new(
            Code::InvalidModule,
            format!(
                "The package `{package}` cannot become an Elm module name: its segment \
                 `{segment}` does not start with a letter."
            ),
            format!(
                "Each package segment becomes a segment of the Elm module name in PascalCase \
                 (`notes.v1` becomes `Notes.V1`), and an Elm module segment must start with a \
                 letter. Rename the package, or rename it with \
                 {rename}."
            ),
            vec![site],
        )
    }

    /// The type `proto_name` becomes `converted`, which is not an Elm type
    /// name.
    pub fn invalid_type(proto_name: &str, converted: &str, site: Site, rename: &str) -> Self {
        Problem::new(
            Code::InvalidType,
            format!(
                "The type `{proto_name}` becomes `{converted}` in Elm, which is not a valid Elm \
                 type name."
            ),
            format!(
                "Elm type names must start with an uppercase letter. Rename the proto type so its \
                 PascalCase form starts with one, or rename it with \
                 {rename}."
            ),
            vec![site],
        )
    }

    /// The field (or oneof) `proto_name` of `message` becomes `converted`,
    /// which is not an Elm record field name.
    pub fn invalid_field(
        message: &str,
        proto_name: &str,
        converted: &str,
        site: Site,
        rename: &str,
    ) -> Self {
        Problem::new(
            Code::InvalidField,
            format!(
                "The field `{proto_name}` of `{message}` becomes `{converted}` in Elm, which is \
                 not a valid record field name."
            ),
            format!(
                "Elm record fields must start with a letter. elm-connect drops a proto field \
                 name's underscores and lowercases its leading capitals, so a name that is only \
                 underscores, or has a digit before its first letter, has no Elm field name. \
                 Rename it in the proto, or rename it with {rename}."
            ),
            vec![site],
        )
    }

    /// The oneof member `proto_name` of `message` has a constructor whose
    /// ending, converted as a field name is, is `converted`, which is not an
    /// Elm value name.
    pub fn invalid_member_value(
        message: &str,
        proto_name: &str,
        converted: &str,
        site: Site,
    ) -> Self {
        Problem::new(
            Code::InvalidField,
            format!(
                "The oneof field `{proto_name}` of `{message}` has the descriptor value \
                 `{converted}` in Elm, which is not a valid value name."
            ),
            "A oneof member's descriptor, in its message's descriptor module, is named for \
             the end of its constructor: the member's name in PascalCase, its leading \
             capitals lowercased (`_legacy` becomes `legacy`, `URL` `url`). That must start \
             with a letter, so a name that is only underscores, or has a digit before its \
             first letter, has none. Rename it in the proto; a `rename` of the member renames \
             its constructor, not this value.",
            vec![site],
        )
    }

    /// `referrer` uses `type_name`, a `google.protobuf` type elm-connect
    /// has no mapping for.
    pub fn unsupported_well_known(referrer: &Referrer, type_name: &str, site: Site) -> Self {
        Problem::new(
            Code::UnsupportedWellKnown,
            format!(
                "{referrer} has type `{type_name}`, a well-known type elm-connect has no Elm \
                 mapping for."
            ),
            "The supported well-known types are Timestamp, Duration, FieldMask, Empty, Any, \
             Struct, Value, ListValue and the wrappers like Int32Value. Use one of those, or a \
             message of your own.",
            vec![site],
        )
    }

    /// `referrer` refers to `type_name`, whose package `package` (declared
    /// in `file`) is not being generated.
    pub fn not_generated(
        referrer: &Referrer,
        type_name: &str,
        package: &str,
        file: &str,
        site: Site,
    ) -> Self {
        Problem::new(
            Code::NotGenerated,
            format!(
                "{referrer} refers to `{type_name}`, but the package `{package}` is not being \
                 generated."
            ),
            format!(
                "Generated Elm modules import the modules of every package they refer to, so \
                 those packages must be generated too, and only packages with a file to \
                 generate are. Add `{file}` to the files to generate: with buf, run `buf \
                 generate --include-imports`; with protoc, name `{file}` on the command line; \
                 with the elm-connect CLI, pass `--include-imports`."
            ),
            vec![site],
        )
    }

    /// The method `method` streams (`which`: "client", "server" or
    /// "bidirectional"). `spelling` writes the option that skips it.
    pub fn streaming(method: &str, which: &str, site: Site, spelling: Spelling) -> Self {
        Problem::new(
            Code::Streaming,
            format!(
                "The method `{method}` is {which} streaming, and streaming methods are not \
                 supported."
            ),
            format!(
                "elm-connect generates unary calls only: Connect streaming and the transcoders' \
                 streaming each frame messages differently, and neither has an Elm design yet. \
                 Pass {} to leave streaming methods out and generate the rest.",
                spelling.option("streaming", "skip")
            ),
            vec![site],
        )
    }

    /// The method `method` streams (`which`, as for [`Problem::streaming`])
    /// and `streaming=skip`, written as `spelling` writes it, leaves it out
    /// of its service's module: a warning.
    pub fn streaming_skipped(method: &str, which: &str, site: Site, spelling: Spelling) -> Self {
        Problem::new(
            Code::Streaming,
            format!(
                "The method `{method}` is {which} streaming, so it is left out of the \
                 generated code."
            ),
            format!(
                "elm-connect generates unary calls only, and {} leaves each streaming method \
                 out of its service's module rather than failing. Calls to this method are not \
                 generated; drop the option to make it an error again.",
                spelling.option("streaming", "skip")
            ),
            vec![site],
        )
        .warning()
    }

    /// The method `method` has no `google.api.http` rule, and
    /// `unbound_methods=error`, written as `spelling` writes it, makes that
    /// a problem.
    pub fn unbound_method(method: &str, site: Site, spelling: Spelling) -> Self {
        Problem::new(
            Code::UnboundMethod,
            format!("The method `{method}` has no `google.api.http` rule."),
            format!(
                "With {}, every method needs a rule. Without one, a call over transcoding takes \
                 the implicit route, `POST /<package>.<Service>/<Method>` with the request as \
                 its body, which grpc-gateway serves with `generate_unbound_methods`, Envoy's \
                 transcoder with `auto_mapping`, and a Connect handler always (Vanguard v0.5 \
                 serves rules alone, and leaves the route to a Connect handler mounted beside \
                 it). Add a rule to the method, or set {} (the default) if the server serves \
                 that route.",
                spelling.option("unbound_methods", "error"),
                spelling.option("unbound_methods", "implicit")
            ),
            vec![site],
        )
    }

    /// Two methods of `service` become the same Elm value `elm_name`.
    pub fn value_collision(
        service: &str,
        elm_name: &str,
        first: Site,
        second: Site,
        rename: &str,
        renamed: Option<&str>,
    ) -> Self {
        Problem::new(
            Code::ValueCollision,
            format!(
                "The service `{service}` has two methods that both become the Elm value \
                 `{elm_name}`."
            ),
            format!(
                "A service's module defines one value per method, its name with its leading \
                 capitals lowercased and underscores dropped, so names that differ only in those \
                 ways end up the same, and a module cannot define two values with one name. {}",
                rename_escape(
                    renamed,
                    format!("Rename one of the methods in the proto, or rename one with {rename}.")
                )
            ),
            vec![first, second],
        )
    }

    /// A method of `service` and another method's descriptor become the
    /// same Elm value `elm_name`.
    pub fn descriptor_collision(
        service: &str,
        elm_name: &str,
        first: Site,
        second: Site,
        rename: &str,
        renamed: Option<&str>,
    ) -> Self {
        Problem::new(
            Code::ValueCollision,
            format!(
                "The service `{service}` has a method that becomes the Elm value \
                 `{elm_name}`, which is another method's descriptor."
            ),
            format!(
                "A service's module defines two values per method: its call, its name with its \
                 leading capitals lowercased and underscores dropped, and its descriptor, \
                 `descriptor` followed by the call's name with the first letter uppercased. So a \
                 method named for another's descriptor (`DescriptorGetNote` beside `GetNote`) \
                 takes that descriptor's name, and a module cannot define two values with one \
                 name. {}",
                rename_escape(
                    renamed,
                    format!("Rename one of the methods in the proto, or rename one with {rename}.")
                )
            ),
            vec![first, second],
        )
    }

    /// A method of `service` and another method's route function become
    /// the same Elm value `elm_name`.
    pub fn route_collision(
        service: &str,
        elm_name: &str,
        first: Site,
        second: Site,
        rename: &str,
        renamed: Option<&str>,
    ) -> Self {
        Problem::new(
            Code::ValueCollision,
            format!(
                "The service `{service}` has a method that becomes the Elm value \
                 `{elm_name}`, which is another method's route function."
            ),
            format!(
                "A service's module defines a route function per HTTP binding of a method: \
                 `route` followed by the call's name with the first letter uppercased and the \
                 binding's number. So a method named for another's route function \
                 (`RouteGetNote0` beside `GetNote`) takes that function's name, and a module \
                 cannot define two values with one name. {}",
                rename_escape(
                    renamed,
                    format!("Rename one of the methods in the proto, or rename one with {rename}.")
                )
            ),
            vec![first, second],
        )
    }

    /// Two types of `package` give codecs the same Elm `values` (`value
    /// `encodeNoteBytes``): one's binary codecs and the JSON codecs of the
    /// other, named for it with `Bytes` at the end.
    pub fn codec_collision(
        package: &str,
        values: &str,
        first: Site,
        second: Site,
        rename: &str,
        renamed: Option<&str>,
    ) -> Self {
        Problem::new(
            Code::CodecCollision,
            format!(
                "The package `{package}` has two definitions whose codecs both become the Elm \
                 {values}."
            ),
            format!(
                "A type's protobuf binary codecs are named for its JSON codecs with `Bytes` at \
                 the end (`encodeNoteBytes` beside `encodeNote`), so the JSON codecs of a type \
                 named for another with `Bytes` at the end (`NoteBytes` beside `Note`) take the \
                 same names, and a module cannot define two values with one name. Enums keep \
                 their JSON codecs under `codec=proto`; messages and oneofs have them under \
                 `codec=both`. {}",
                rename_escape(
                    renamed,
                    format!("Rename one of them in the proto, or rename one with {rename}.")
                )
            ),
            vec![first, second],
        )
    }

    /// Two fields or oneof members of `message` become the same Elm value
    /// `elm_name` in the message's descriptor module.
    pub fn field_value_collision(
        message: &str,
        elm_name: &str,
        first: Site,
        second: Site,
        rename: &str,
        renamed: Option<&str>,
    ) -> Self {
        Problem::new(
            Code::ValueCollision,
            format!(
                "The descriptor module of `{message}` would define the Elm value \
                 `{elm_name}` twice."
            ),
            format!(
                "A message's descriptor module (`Notes.V1.Note` for `notes.v1.Note`) defines \
                 `descriptor`, the message's descriptor, and one value per field, named as its \
                 record field is (a oneof member's for the end of its constructor; a field \
                 named `descriptor` takes `descriptor_`), so two fields whose values meet cannot \
                 both be defined. {}",
                rename_escape(
                    renamed,
                    format!("Rename the field in the proto, or rename it with {rename}.")
                )
            ),
            vec![first, second],
        )
    }

    /// Two generated modules, each a package's, a service's or a message's
    /// or enum's descriptor module, become the same Elm module
    /// `elm_module`.
    pub fn module_collision(
        elm_module: &str,
        first: Site,
        second: Site,
        rename: &str,
        renamed: Option<&str>,
    ) -> Self {
        Problem::new(
            Code::ModuleCollision,
            format!("Two generated modules both become the Elm module `{elm_module}`."),
            format!(
                "Every package becomes an Elm module (`notes.v1` becomes `Notes.V1`), and every \
                 service, message and enum becomes a module inside its package's \
                 (`notes.v1.NotesService` becomes `Notes.V1.NotesService`, the descriptors of \
                 `notes.v1.Note` are in `Notes.V1.Note`), each segment in PascalCase, so one can \
                 take the name of another or of a package nested in its own, and names that \
                 differ only in case or underscores end up the same. {}",
                rename_escape(
                    renamed,
                    format!("Rename one of them in the proto, or rename one with {rename}.")
                )
            ),
            vec![first, second],
        )
    }

    /// Two generated modules, `first` and `second`, differ only in case,
    /// so their files are one file where file names ignore case.
    pub fn module_case_collision(
        first: &str,
        second: &str,
        escapes: &str,
        sites: (Site, Site),
    ) -> Self {
        Problem::new(
            Code::ModuleCollision,
            format!(
                "The generated modules `{first}` and `{second}` differ only in case, so they \
                 are written to the same file on macOS and Windows."
            ),
            format!(
                "Each module is written to a file named for it (`Notes.V1` to \
                 `Notes/V1.elm`), and the default file systems of macOS and Windows ignore \
                 case, so one of these would overwrite the other. Rename one of them in the \
                 proto, or rename one with {escapes}."
            ),
            vec![sites.0, sites.1],
        )
    }

    /// `what` (such as "package `time`") becomes the Elm module `module`,
    /// a module of `owner` (such as "elm/time"), which an application
    /// cannot also define. `escapes` names the options that move it.
    pub fn reserved_module(
        what: &str,
        module: &str,
        owner: &str,
        escapes: &str,
        site: Site,
    ) -> Self {
        Problem::new(
            Code::ReservedModule,
            format!("The {what} becomes the Elm module `{module}`, which is a module of {owner}."),
            format!(
                "An application that depends on {owner} cannot define a module of the same \
                 name: every `import {module}`, in the generated code or the application's, \
                 becomes ambiguous. Move the module with {escapes}."
            ),
            vec![site],
        )
    }

    /// `what` (such as "message `notes.v1.Con`") becomes the Elm module
    /// `module`, whose segment `segment` is a device name Windows reserves
    /// as a file name. `rename` is the option that renames it.
    pub fn windows_device_module(
        what: &str,
        module: &str,
        segment: &str,
        rename: &str,
        site: Site,
    ) -> Self {
        Problem::new(
            Code::ReservedModule,
            format!(
                "The {what} becomes the Elm module `{module}`, and `{segment}` is a reserved \
                 file name on Windows."
            ),
            format!(
                "Each module is written to a file named for it (`Notes.V1.Note` to \
                 `Notes/V1/Note.elm`), and Windows reserves `CON`, `PRN`, `AUX`, `NUL`, \
                 `COM1` to `COM9` and `LPT1` to `LPT9` as file names in any case and with any \
                 extension, so `{segment}.elm` or a directory `{segment}` cannot be created \
                 there and git refuses to check it out. It is refused on every OS so that \
                 generated code can be checked out anywhere. Rename it with {rename}."
            ),
            vec![site],
        )
    }

    /// The generated modules `modules`, sorted, are named for the runtime's
    /// namespaces or sit inside them; `module_prefix` and `rename` are the
    /// options that move them, as their reader writes them. A warning.
    pub fn runtime_namespace(modules: &[String], module_prefix: &str, rename: &str) -> Self {
        let names: Vec<String> = modules.iter().map(|module| format!("`{module}`")).collect();
        let (subject, verb) = match names.as_slice() {
            [_] => ("module", "is"),
            _ => ("modules", "are"),
        };
        Problem::new(
            Code::RuntimeNamespace,
            format!(
                "The generated {subject} {} {verb} in a namespace of the runtime package \
                 {}.",
                join_words(&names),
                crate::naming::RUNTIME_PACKAGE
            ),
            format!(
                "The runtime package's modules are named `Rpc` and `Proto` or sit inside them, \
                 and it may add modules there in any release, a minor or patch one included. \
                 A generated module there compiles today, but one the runtime adds later of the \
                 same name makes every import of it ambiguous. Move them with {module_prefix}, \
                 or rename their packages with {rename}."
            ),
            Vec::new(),
        )
        .warning()
    }

    /// `what` (such as "package `html`") becomes the Elm module `module`,
    /// a module of `owner` (such as "elm/html"), which an application
    /// depending on it then cannot import. `escapes` names the options
    /// that move it. A warning.
    pub fn shadowing_module(
        what: &str,
        module: &str,
        owner: &str,
        escapes: &str,
        site: Site,
    ) -> Self {
        Problem::new(
            Code::ShadowingModule,
            format!("The {what} becomes the Elm module `{module}`, which is a module of {owner}."),
            format!(
                "Generated code does not import {owner}, so this compiles, but an application \
                 that depends on {owner} cannot import `{module}`: the import is ambiguous. \
                 Move the module with {escapes}."
            ),
            vec![site],
        )
        .warning()
    }

    /// `what` (such as "message `notes.v1.Dict`") becomes the Elm `kind`
    /// ("type" or "constructor") `name`, which the generated module also
    /// uses unqualified for `home.name`. `rename` is the option that
    /// renames it, as its reader writes it. `site` is the element's name,
    /// when it is known.
    pub fn reserved_name(
        what: &str,
        kind: &str,
        name: &str,
        home: &str,
        rename: &str,
        site: Option<Site>,
    ) -> Self {
        Problem::new(
            Code::ReservedName,
            format!(
                "The {what} becomes the Elm {kind} `{name}`, but its module also uses \
                 `{home}.{name}` as `{name}`."
            ),
            format!(
                "Generated code refers to some types and constructors of elm/core and of the \
                 runtime unqualified, as Elm code conventionally does, so a {kind} of the same \
                 name in the same module takes their place and the module does not compile. \
                 Rename it with {rename}."
            ),
            site.into_iter().collect(),
        )
    }

    /// The service `service`'s name does not start with a letter once
    /// converted to PascalCase.
    pub fn invalid_service(service: &str, site: Site, rename: &str) -> Self {
        Problem::new(
            Code::InvalidService,
            format!(
                "The service `{service}` cannot become an Elm module name: its name does not \
                 start with a letter."
            ),
            format!(
                "Each service becomes an Elm module inside its package's, named for the service \
                 in PascalCase (`notes.v1.Notes` becomes `Notes.V1.Notes`), and an Elm module \
                 segment must start with a letter. Rename the service, or rename it with \
                 {rename}."
            ),
            vec![site],
        )
    }

    /// `binding` (such as "The HTTP rule of `notes.v1.Notes.GetNote`")
    /// does not resolve, for `error`.
    pub fn route(binding: &str, error: &crate::route::RouteError, site: Site) -> Self {
        use crate::route::RouteError as E;
        let (code, message, help): (Code, String, String) = match error {
            E::NoPattern => (
                Code::RouteRule,
                format!("{binding} has no path."),
                "A rule sets one of `get`, `put`, `post`, `delete` or `patch` to a path \
                 template, or `custom` to a kind and a path."
                    .into(),
            ),
            E::CustomKind { kind, reason } => (
                Code::RouteRule,
                format!(
                    "{binding} has the custom kind `{}`, which {reason}.",
                    kind.escape_debug()
                ),
                "A `custom` rule's kind is the request's HTTP method: a token of letters, \
                 digits and ``!#$%&'*+-.^_`|~`` (RFC 9110), and not `CONNECT`, `TRACE` or \
                 `TRACK`, which browsers refuse."
                    .into(),
            ),
            E::NestedBindings => (
                Code::RouteRule,
                format!("{binding} has additional bindings of its own."),
                "`google/api/http.proto` allows additional bindings one level deep only. Move \
                 the nested bindings up into the rule's own `additional_bindings`."
                    .into(),
            ),
            E::Syntax { template, error } => (
                Code::RouteTemplate,
                format!("{binding} has the path `{template}`, which does not parse: {error}."),
                "A path template is `/` and segments separated by `/`, each a literal, `*`, \
                 `**` (last only) or a variable like `{name}` or `{name=messages/*}`, \
                 optionally followed by a custom verb like `:cancel`."
                    .into(),
            ),
            E::UnboundWildcard { template } => (
                Code::RouteTemplate,
                format!("{binding} has the path `{template}`, with a wildcard outside a variable."),
                "A client fills each path segment from a request field, and a bare `*` or `**` \
                 names none. Bind it to a field, like `{name=*}`."
                    .into(),
            ),
            E::PathField {
                field,
                reason,
                suggestion,
            } => (
                Code::RoutePathField,
                format!("{binding} binds `{{{field}}}` in its path, but {reason}."),
                format!(
                    "{}A path variable names a non-repeated field of the request, possibly \
                     through singular message fields (`{{book.name}}`), that holds a scalar, \
                     an enum, or a Timestamp, Duration, FieldMask or wrapper, whose JSON is \
                     one value.",
                    did_you_mean(suggestion.as_deref())
                ),
            ),
            E::PathFieldTwice { field } => (
                Code::RoutePathField,
                format!("{binding} binds `{{{field}}}` in its path twice."),
                "Each field can fill one path variable. Remove one of them.".into(),
            ),
            E::BodyField {
                field,
                reason,
                suggestion,
            } => (
                Code::RouteBodyField,
                format!("{binding} has `body: \"{field}\"`, but {reason}."),
                format!(
                    "{}`body` is `*` for every field not in the path, or the name of a \
                     top-level singular message field of the request, or left out for no body.",
                    did_you_mean(suggestion.as_deref())
                ),
            ),
            E::ResponseBodyField {
                field,
                reason,
                suggestion,
            } => (
                Code::RouteResponseBody,
                format!("{binding} has `response_body: \"{field}\"`, but {reason}."),
                format!(
                    "{}`response_body` names a top-level field of the response, a generated \
                     message, or is left out for the whole response.",
                    did_you_mean(suggestion.as_deref())
                ),
            ),
            E::QueryField { field, reason } => (
                Code::RouteQueryField,
                format!(
                    "{binding} sends `{field}` as a query parameter, but {reason}, which has no \
                     query form."
                ),
                "Every request field outside the path and the body is a query parameter, and \
                 a parameter holds scalars, enums and well-known types with a string form. \
                 Send the field in the body (`body: \"*\"`, or a body field holding it), or \
                 move it out of the request."
                    .into(),
            ),
        };
        Problem::new(code, message, help, vec![site])
    }

    /// The binding `second` matches the same requests as the binding
    /// `first`: both are `shape`, an HTTP method and a path shape
    /// ([`crate::route::Route::shape`]). Each binding is named in the
    /// middle of a sentence, with its method and path ("additional binding
    /// 2 of `routes.v1.Routes.GetMessage` (`GET /v1/messages/{id}`)").
    /// `site` is the second binding's, if it has one in the protos. A
    /// warning.
    pub fn ambiguous_binding(first: &str, second: &str, shape: &str, site: Option<Site>) -> Self {
        Problem::new(
            Code::AmbiguousBinding,
            format!(
                "{} matches the same requests as {first}: both are `{shape}`.",
                capitalized(second)
            ),
            "`google/api/http.proto` does not say which of two such bindings serves a request, \
             and no router serves both: Envoy's transcoder answers neither (docs/envoy.md), \
             Vanguard refuses the second, and grpc-gateway lets one of them win. The client \
             cannot tell which it faces and sends its method's binding regardless. Give one \
             of them a different path or HTTP method.",
            site.into_iter().collect(),
        )
        .warning()
    }

    /// The method `method`'s name becomes `converted`, which is not an Elm
    /// value name.
    pub fn invalid_method(method: &str, converted: &str, site: Site, rename: &str) -> Self {
        Problem::new(
            Code::InvalidMethod,
            format!(
                "The method `{method}` becomes `{converted}` in Elm, which is not a valid Elm \
                 value name."
            ),
            format!(
                "A method's Elm value is its name with underscores dropped and its leading \
                 capitals lowercased, and must start with a letter, so a name that is only \
                 underscores, or has a digit before its first letter, has none. Rename the \
                 method, or rename it with {rename}."
            ),
            vec![site],
        )
    }

    /// The packages `cycle` (each with the files declaring it) refer to
    /// each other in a cycle; `sites` are references along it.
    pub fn import_cycle(cycle: &[(String, Vec<String>)], sites: Vec<Site>) -> Self {
        let names: Vec<String> = cycle
            .iter()
            .map(|(package, files)| format!("`{package}` ({})", files.join(", ")))
            .collect();
        Problem::new(
            Code::ImportCycle,
            format!(
                "The packages {} refer to each other in a cycle.",
                join_words(&names)
            ),
            "Each proto package becomes one Elm module, and Elm modules cannot import each \
             other in a cycle. Move the types that refer to each other into one package.",
            sites,
        )
    }

    /// The `rename` of `proto` gives `elm`, which `proto`, being `what`
    /// (such as "a message"), cannot take: it becomes `becomes` (such as
    /// "an Elm type"), whose names follow `rule`.
    pub fn invalid_rename(
        proto: &str,
        elm: &str,
        what: &str,
        becomes: &str,
        rule: &str,
        site: Site,
    ) -> Self {
        Problem::new(
            Code::InvalidRename,
            format!("The rename of `{proto}` gives `{elm}`, which {what} cannot be named."),
            format!(
                "`{proto}` is {what}, which becomes {becomes}, and a rename's name is used \
                 as it is, so it must be {rule}."
            ),
            vec![site],
        )
    }

    /// The `rename` of `proto` names an enum value alias, which has no
    /// constructor of its own.
    pub fn rename_alias(proto: &str, site: Site) -> Self {
        Problem::new(
            Code::InvalidRename,
            format!("The rename of `{proto}` names an enum value alias."),
            "An alias shares the constructor of the first value declared with its number, and \
             has no Elm name of its own. Rename that first value instead.",
            vec![site],
        )
    }

    /// The `rename` of `proto` names nothing, and no prefix of it names an
    /// element: `packages` are the generated packages, and `suggestion` the
    /// name it most likely meant, if any is close.
    pub fn unknown_rename(proto: &str, packages: &[String], suggestion: Option<&str>) -> Self {
        let quoted: Vec<String> = packages.iter().map(|p| format!("`{p}`")).collect();
        let generated = match quoted.as_slice() {
            [] => "no package is generated".to_owned(),
            [only] => format!("the generated package is {only}"),
            _ => format!("the generated packages are {}", join_words(&quoted)),
        };
        Problem::new(
            Code::UnknownRename,
            format!("`{proto}` names nothing elm-connect generates; {generated}."),
            format!("{}{RENAME_PATH_HELP}", did_you_mean(suggestion)),
            Vec::new(),
        )
    }

    /// The `rename` of `proto` reaches `element`, which is `what` ("a
    /// message") and has `members` ("method"), but names `missing` under
    /// it, which it does not have; `suggestion` is the full name most
    /// likely meant. `site` is the element's declaration.
    pub fn unknown_rename_member(
        proto: &str,
        element: &str,
        what: &str,
        members: &str,
        missing: &str,
        suggestion: Option<&str>,
        site: Site,
    ) -> Self {
        Problem::new(
            Code::UnknownRename,
            format!(
                "`{element}` is {what}, and has no {members} `{missing}`{}.",
                renaming(proto, &format!("{element}.{missing}"))
            ),
            format!("{}{RENAME_PATH_HELP}", did_you_mean(suggestion)),
            vec![site],
        )
    }

    /// The `rename` of `proto` names something under `element`, which is
    /// `what` ("a field") and has nothing under it. `site` is its
    /// declaration.
    pub fn unknown_rename_leaf(proto: &str, element: &str, what: &str, site: Site) -> Self {
        Problem::new(
            Code::UnknownRename,
            format!(
                "`{element}` is {what}, and nothing under {what} can be renamed{}.",
                renaming(proto, element)
            ),
            RENAME_PATH_HELP,
            vec![site],
        )
    }

    /// The `rename` of `proto` names `element`, or something under it,
    /// which is `what` ("a message") of `package`, declared in `file`, and
    /// `package` is not generated.
    pub fn rename_not_generated(
        proto: &str,
        element: &str,
        what: &str,
        package: &str,
        file: &str,
    ) -> Self {
        let of = if element == package {
            String::new()
        } else {
            format!(" of `{package}`")
        };
        let help = if package == "google.protobuf" {
            "A rename reaches only the generated packages, and elm-connect never generates \
             `google.protobuf`: its well-known types map to the runtime's Elm types, whose \
             names are fixed."
                .to_owned()
        } else {
            format!(
                "A rename reaches only the generated packages, and only packages with a file \
                 to generate are generated. To generate `{package}`, add `{file}` to the \
                 files to generate: with buf, run `buf generate --include-imports`; with \
                 protoc, name `{file}` on the command line; with the elm-connect CLI, pass \
                 `--include-imports`."
            )
        };
        Problem::new(
            Code::UnknownRename,
            format!(
                "`{element}` is {what}{of}, which is not generated{}.",
                renaming(proto, element)
            ),
            help,
            Vec::new(),
        )
    }

    /// The plugin parameter holds `pair`, which has no `=`.
    pub fn option_without_value(pair: &str) -> Self {
        Problem::new(
            Code::UnknownOption,
            format!("The plugin parameter holds `{pair}`, which is not a `key=value` pair."),
            OPTION_KEYS_HELP,
            Vec::new(),
        )
    }

    /// The plugin parameter names `key`, which is none of `keys`, the
    /// options; the help suggests the nearest of them ([`closest`]).
    pub fn unknown_option(key: &str, keys: &[&str]) -> Self {
        let suggestion = closest(key, keys.iter().copied());
        Problem::new(
            Code::UnknownOption,
            format!("There is no option `{key}`."),
            format!("{}{OPTION_KEYS_HELP}", did_you_mean(suggestion.as_deref())),
            Vec::new(),
        )
    }

    /// The option `key` is given `value`, which is not among `values`, the
    /// values it takes, its default first.
    pub fn unknown_option_value(key: &str, value: &str, values: &[&str]) -> Self {
        let quoted: Vec<String> = values.iter().map(|value| format!("`{value}`")).collect();
        let default = quoted.first().cloned().unwrap_or_default();
        Problem::new(
            Code::UnknownOption,
            format!("The option `{key}` is `{value}`, which is not one of its values."),
            format!(
                "`{key}` is {}; left out, it is {default}.",
                join_alternatives(&quoted)
            ),
            Vec::new(),
        )
    }

    /// `codec=binary`, the name the binary codecs alone had before they
    /// were named for the `Rpc.Proto` tag their calls carry.
    pub fn codec_binary() -> Self {
        Problem::new(
            Code::UnknownOption,
            "The option `codec` is `binary`, which is now spelled `proto`.".to_owned(),
            "`codec=proto` generates the protobuf binary codecs alone, as `codec=binary` \
             did, and its calls are `Rpc.Call Rpc.Proto`. `codec` is `json`, `proto` or \
             `both`; left out, it is `json`.",
            Vec::new(),
        )
    }

    /// The option `key`, which takes one value, is given more than once.
    pub fn duplicate_option(key: &str) -> Self {
        Problem::new(
            Code::DuplicateOption,
            format!("The option `{key}` is given more than once."),
            "Every option but `rename` takes one value, and a second would silently replace \
             the first. Keep the one you mean.",
            Vec::new(),
        )
    }

    /// The rename map renames `proto` more than once.
    pub fn duplicate_rename(proto: &str) -> Self {
        Problem::new(
            Code::DuplicateOption,
            format!("The options rename `{proto}` more than once."),
            "A proto element has one Elm name, so it takes one rename. Keep the one you mean.",
            Vec::new(),
        )
    }

    /// The rename map entry `entry` is not `<proto full name>:<Elm name>`
    /// with neither side empty.
    pub fn rename_form(entry: &str) -> Self {
        Problem::new(
            Code::InvalidRename,
            format!("The rename `{entry}` is not `<proto full name>:<Elm name>`."),
            "A rename names a proto element by its full name and gives its Elm name, the two \
             separated by `:`, such as `notes.v1.Note:Memo`; neither may be empty.",
            Vec::new(),
        )
    }

    /// `module_prefix` is `value`, which is not an Elm module name.
    pub fn invalid_module_prefix(value: &str) -> Self {
        Problem::new(
            Code::InvalidModulePrefix,
            format!("The module prefix `{value}` is not an Elm module name."),
            "A module prefix is dot-separated Elm module segments, such as `Api.Notes`, each \
             an uppercase letter followed by letters, digits or underscores.",
            Vec::new(),
        )
    }

    /// `file` was asked for but is not in the descriptor set.
    pub fn unknown_file(file: &str) -> Self {
        Problem::new(
            Code::UnknownFile,
            format!("The file `{file}` is to be generated, but no such file was compiled."),
            "Every file to generate must be among the compiled files. Check its name against \
             the include paths.",
            Vec::new(),
        )
    }

    /// `file` uses `syntax`, not proto3; `None` when it declares no
    /// syntax, which makes it proto2.
    pub fn not_proto3(file: &str, syntax: Option<&str>, site: Site) -> Self {
        let (message, add) = match syntax {
            Some(syntax) => (
                format!(
                    "The file `{file}` uses {syntax} syntax, but elm-connect generates proto3."
                ),
                "Use `syntax = \"proto3\";`.",
            ),
            None => (
                format!(
                    "The file `{file}` has no `syntax` statement, which makes it proto2, but \
                     elm-connect generates proto3."
                ),
                "A file without a `syntax` statement is proto2. Add `syntax = \"proto3\";` as \
                 its first statement.",
            ),
        };
        Problem::new(
            Code::NotProto3,
            message,
            format!(
                "elm-connect implements the proto3 JSON mapping; proto2 features like \
                 `required` and default values have no Elm mapping. {add}"
            ),
            vec![site],
        )
    }

    /// `file`, named on the command line, or imported at `imported` (a
    /// site in the importing file), is under none of the include paths
    /// `searched`, as written; `absent` is each of those that is not a
    /// directory, with why: `does not exist` or `is not a directory`.
    pub fn file_not_found(
        file: &str,
        imported: Option<Site>,
        searched: &[String],
        absent: &[(String, &str)],
    ) -> Self {
        let (message, site) = match imported {
            Some(site) => (
                format!(
                    "The file `{}` imports `{file}`, which is under none of the include paths.",
                    site.file
                ),
                site,
            ),
            None => (
                format!("The file `{file}` is under none of the include paths."),
                Site {
                    file: file.to_owned(),
                    span: None,
                    label: "not found".into(),
                    within: Vec::new(),
                },
            ),
        };
        let searched: Vec<String> = searched.iter().map(|path| format!("`{path}`")).collect();
        let absent: String = absent
            .iter()
            .map(|(path, why)| format!(" `{path}` {why}."))
            .collect();
        Problem::new(
            Code::FileNotFound,
            message,
            format!(
                "The include paths searched were {} (`-I`, `.` when none is given), then the \
                 `google/protobuf` files and the `google/api` annotations elm-connect bundles.\
                 {absent} Add the directory the file is under with `-I`, and name it relative \
                 to that directory.",
                searched.join(", ")
            ),
            vec![site],
        )
    }

    /// `file` declares an edition, `edition` when it is known (`"2023"`).
    pub fn editions(file: &str, edition: Option<&str>, site: Site) -> Self {
        let declares = match edition {
            Some(edition) => format!("declares `edition = \"{edition}\"`"),
            None => "declares an edition".to_owned(),
        };
        Problem::new(
            Code::Editions,
            format!("The file `{file}` {declares}, but elm-connect generates proto3 only."),
            "This release of elm-connect does not support editions: it implements the proto3 \
             JSON mapping, and an edition's features (closed enums, required fields, \
             explicit presence by default) have no Elm form here yet. Declare \
             `syntax = \"proto3\";` instead, if the file uses no feature beyond proto3's.",
            vec![site],
        )
    }

    /// The name of `file` holds a control character, which would break
    /// the generated header comment that names it.
    pub fn file_name(file: &str) -> Self {
        Problem::new(
            Code::FileName,
            format!(
                "The file name `{}` holds a control character.",
                file.escape_debug()
            ),
            "The first line of a generated module is a comment naming the files it was \
             generated from, which a newline or another control character in a name would \
             break. Rename the file.",
            Vec::new(),
        )
    }

    /// The fields `first` and `second` of `message` (its full name, when
    /// it is known), in `file`, have names that are the same once
    /// lowercased without underscores, which the descriptor library
    /// refuses. `spelling` writes the `rename` option as the front end
    /// takes it.
    pub fn field_name_conflict(
        file: &str,
        message: Option<&str>,
        first: &str,
        second: &str,
        spelling: Spelling,
        sites: Vec<Site>,
    ) -> Self {
        let of = match message {
            Some(message) => format!("the message `{message}`"),
            None => format!("a message in `{file}`"),
        };
        Problem::new(
            Code::FieldNameConflict,
            format!(
                "The fields `{first}` and `{second}` of {of} have names that are the same once \
                 lowercased without underscores, and elm-connect cannot read the file."
            ),
            format!(
                "Fields of one message whose names differ only in case and underscores are \
                 refused in any file but a proto2 one, when elm-connect reads the file and \
                 before any option applies, so {} cannot help: rename one of them in the \
                 proto. protoc accepts the file, since it compares the fields' exact JSON \
                 names, which differ.",
                spelling.rename_key()
            ),
            sites,
        )
    }

    fn attach(&mut self, sources: &HashMap<&str, Arc<str>>, columns: Columns) {
        let Some(primary) = self.sites.first().map(|site| site.file.clone()) else {
            return;
        };
        let Some(text) = sources.get(primary.as_str()) else {
            return;
        };
        let labels = self.labels_in(&primary, text, columns);
        let mut elsewhere = Vec::new();
        let mut other_files: Vec<&str> = Vec::new();
        for site in &self.sites {
            if site.file != primary && !other_files.contains(&site.file.as_str()) {
                other_files.push(&site.file);
            }
        }
        for file in other_files {
            if let Some(text) = sources.get(file) {
                elsewhere.push(Elsewhere {
                    message: format!("and in `{file}`:"),
                    source: NamedSource::new(file, text.clone()),
                    labels: self.labels_in(file, text, columns),
                });
            }
        }
        self.attached = Some(Box::new(Attached {
            source: NamedSource::new(&primary, text.clone()),
            labels,
            elsewhere,
        }));
    }

    fn labels_in(&self, file: &str, text: &str, columns: Columns) -> Vec<LabeledSpan> {
        self.sites
            .iter()
            .filter(|site| site.file == file)
            .filter_map(|site| {
                let span = site.span?.byte_span(text, columns)?;
                let span = spans::narrow(text, span, &site.within);
                Some(LabeledSpan::new_with_span(Some(site.label.clone()), span))
            })
            .collect()
    }
}

/// The end of a collision's help: `default`, which names the escape, or,
/// when `renamed` is the option (written with its Elm name) that gave one
/// claimant the name, a pointer at that option instead.
fn rename_escape(renamed: Option<&str>, default: String) -> String {
    match renamed {
        Some(option) => format!(
            "That name comes from {option}: give it another there, or rename the other one in \
             the proto."
        ),
        None => default,
    }
}

/// The options of the plugin parameter, as an option problem's help
/// lists them.
const OPTION_KEYS_HELP: &str = "The plugin parameter is comma-separated `key=value` pairs, and \
     its options are `int64`, `bytes`, `unbound_methods`, `streaming`, `enum_unknown`, `codec`, \
     `rename` and `module_prefix`.";

/// How a rename writes the element it names, as a rename problem's help
/// ends.
const RENAME_PATH_HELP: &str = "A rename names an element by its proto full name, as declared \
     (`notes.v1.Note.page_count`, not `pageCount`), nested names dotted, an enum value under \
     its enum (`notes.v1.Visibility.VISIBILITY_PUBLIC`).";

/// " (in the rename of `proto`)", naming the rename a problem is about when its
/// message names only `named`, a part of it; empty when `named` is all of
/// it.
fn renaming(proto: &str, named: &str) -> String {
    if proto == named {
        String::new()
    } else {
        format!(" (in the rename of `{proto}`)")
    }
}

/// `a`, `a or b`, `a, b or c`.
fn join_alternatives(words: &[String]) -> String {
    match words {
        [] => String::new(),
        [only] => only.clone(),
        [init @ .., last] => format!("{} or {last}", init.join(", ")),
    }
}

/// `text` with its first letter capitalized, to begin a sentence.
fn capitalized(text: &str) -> String {
    let mut chars = text.chars();
    match chars.next() {
        Some(first) => first.to_uppercase().chain(chars).collect(),
        None => String::new(),
    }
}

/// `a`, `a and b`, `a, b and c`.
fn join_words(words: &[String]) -> String {
    match words {
        [] => String::new(),
        [only] => only.clone(),
        [init @ .., last] => format!("{} and {last}", init.join(", ")),
    }
}

impl Site {
    /// Where the site is, as compilers write it: `notes.proto:3:9`, line
    /// and column from 1, or the file alone when no span was recorded.
    pub fn location(&self) -> String {
        match self.span {
            Some(span) => format!(
                "{}:{}:{}",
                self.file,
                u64::from(span.start_line) + 1,
                u64::from(span.start_col) + 1
            ),
            None => self.file.clone(),
        }
    }
}

impl fmt::Display for Problem {
    /// The message; once located without a source, after its first site's
    /// location, and, when it has several sites, followed by each one's
    /// location and label.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let Some(first) = self.sites.first().filter(|_| self.located) else {
            return f.write_str(&self.message);
        };
        write!(f, "{}: {}", first.location(), self.message)?;
        if self.sites.len() > 1 {
            for site in &self.sites {
                write!(f, "\n{}: {}", site.location(), site.label)?;
            }
        }
        Ok(())
    }
}

impl std::error::Error for Problem {}

impl Diagnostic for Problem {
    fn code<'a>(&'a self) -> Option<Box<dyn fmt::Display + 'a>> {
        Some(Box::new(self.code.as_str()))
    }

    fn severity(&self) -> Option<Severity> {
        Some(if self.warning {
            Severity::Warning
        } else {
            Severity::Error
        })
    }

    fn help<'a>(&'a self) -> Option<Box<dyn fmt::Display + 'a>> {
        Some(Box::new(&self.help))
    }

    fn source_code(&self) -> Option<&dyn SourceCode> {
        self.attached
            .as_ref()
            .map(|attached| &attached.source as &dyn SourceCode)
    }

    fn labels(&self) -> Option<Box<dyn Iterator<Item = LabeledSpan> + '_>> {
        let attached = self.attached.as_ref()?;
        Some(Box::new(attached.labels.iter().cloned()))
    }

    fn related<'a>(&'a self) -> Option<Box<dyn Iterator<Item = &'a dyn Diagnostic> + 'a>> {
        let attached = self.attached.as_ref()?;
        if attached.elsewhere.is_empty() {
            return None;
        }
        Some(Box::new(
            attached
                .elsewhere
                .iter()
                .map(|elsewhere| elsewhere as &dyn Diagnostic),
        ))
    }
}

impl fmt::Display for Elsewhere {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for Elsewhere {}

impl Diagnostic for Elsewhere {
    fn severity(&self) -> Option<Severity> {
        Some(Severity::Advice)
    }

    fn source_code(&self) -> Option<&dyn SourceCode> {
        Some(&self.source)
    }

    fn labels(&self) -> Option<Box<dyn Iterator<Item = LabeledSpan> + '_>> {
        Some(Box::new(self.labels.iter().cloned()))
    }
}

/// Every problem a run found, in the order found. A run that returns
/// `Diagnostics` as its error has at least one, and only errors; the
/// warnings of a successful run come back as `Diagnostics` of warnings
/// alone.
#[derive(Clone, Debug, Default)]
pub struct Diagnostics {
    problems: Vec<Problem>,
}

impl Diagnostics {
    /// No problems yet.
    pub fn new() -> Self {
        Diagnostics::default()
    }

    /// Records a problem.
    pub fn push(&mut self, problem: Problem) {
        self.problems.push(problem);
    }

    /// Whether no problem was recorded.
    pub fn is_empty(&self) -> bool {
        self.problems.is_empty()
    }

    /// How many problems were recorded.
    pub fn len(&self) -> usize {
        self.problems.len()
    }

    /// The problems, in the order found.
    pub fn iter(&self) -> impl ExactSizeIterator<Item = &Problem> {
        self.problems.iter()
    }

    /// The errors and the warnings, each in the order found.
    pub fn split_warnings(self) -> (Diagnostics, Diagnostics) {
        let (warnings, errors) = self.problems.into_iter().partition(Problem::is_warning);
        (
            Diagnostics { problems: errors },
            Diagnostics { problems: warnings },
        )
    }

    /// Whether every problem is a warning (and so does any vacuously).
    fn all_warnings(&self) -> bool {
        self.problems.iter().all(Problem::is_warning)
    }

    /// What the problems are in, for the header: the protos, the options,
    /// or both.
    fn subject(&self) -> &'static str {
        let options = |problem: &Problem| problem.code.as_str().starts_with("options::");
        match (
            self.problems.iter().any(options),
            self.problems.iter().all(options),
        ) {
            (true, true) => "the options",
            (true, false) => "the protos and the options",
            (false, _) => "the protos",
        }
    }

    /// Has every problem without source text name its sites'
    /// locations, `file:line:col`, in its text, so it can be found without
    /// a snippet: what the protoc plugin, which is sent no source, renders.
    /// A problem with a snippet is unchanged.
    pub fn locate(&mut self) {
        for problem in &mut self.problems {
            problem.located = problem.attached.is_none();
        }
    }

    /// Gives every problem the source text of its files, so it renders
    /// with snippets. `sources` maps proto file names to their text;
    /// `columns` says how the compiler counted columns. A file missing from
    /// `sources`, or a span that does not fit its text, renders without a
    /// snippet.
    pub fn attach_sources(&mut self, sources: &HashMap<String, String>, columns: Columns) {
        // Problems share each file's text: with one per rule, copies of
        // a large file took gigabytes.
        let shared: HashMap<&str, Arc<str>> = sources
            .iter()
            .map(|(file, text)| (file.as_str(), Arc::from(text.as_str())))
            .collect();
        for problem in &mut self.problems {
            problem.attach(&shared, columns);
        }
    }
}

impl From<Problem> for Diagnostics {
    fn from(problem: Problem) -> Self {
        Diagnostics {
            problems: vec![problem],
        }
    }
}

impl<'a> IntoIterator for &'a Diagnostics {
    type Item = &'a Problem;
    type IntoIter = std::slice::Iter<'a, Problem>;

    fn into_iter(self) -> Self::IntoIter {
        self.problems.iter()
    }
}

impl fmt::Display for Diagnostics {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let subject = self.subject();
        match (self.all_warnings(), self.problems.len()) {
            (true, 1) => write!(f, "elm-connect has a warning about {subject}"),
            (true, n) => write!(f, "elm-connect has {n} warnings about {subject}"),
            (false, 1) => write!(f, "elm-connect found a problem in {subject}"),
            (false, n) => write!(f, "elm-connect found {n} problems in {subject}"),
        }
    }
}

impl std::error::Error for Diagnostics {}

impl Diagnostic for Diagnostics {
    fn severity(&self) -> Option<Severity> {
        Some(if self.all_warnings() {
            Severity::Warning
        } else {
            Severity::Error
        })
    }

    fn related<'a>(&'a self) -> Option<Box<dyn Iterator<Item = &'a dyn Diagnostic> + 'a>> {
        Some(Box::new(
            self.problems
                .iter()
                .map(|problem| problem as &dyn Diagnostic),
        ))
    }
}

/// The candidate a name was most likely meant to be, for a "did you
/// mean" hint: one that differs from `name` only in case and underscores,
/// or else the nearest within three single-character edits, the first in
/// `candidates`' order on a tie. `None` when nothing is that close, or
/// when `name` is itself a candidate.
pub fn closest<'a>(name: &str, candidates: impl IntoIterator<Item = &'a str>) -> Option<String> {
    const MAX_EDITS: usize = 3;
    let folded = |text: &str| -> String {
        text.chars()
            .filter(|c| *c != '_')
            .flat_map(char::to_lowercase)
            .collect()
    };
    let target = folded(name);
    let mut best: Option<(usize, &str)> = None;
    for candidate in candidates {
        if candidate == name {
            return None;
        }
        let distance = if folded(candidate) == target {
            0
        } else {
            edit_distance(name, candidate)
        };
        if distance <= MAX_EDITS && best.is_none_or(|(least, _)| distance < least) {
            best = Some((distance, candidate));
        }
    }
    best.map(|(_, candidate)| candidate.to_owned())
}

/// The Levenshtein distance between `a` and `b`, by characters.
fn edit_distance(a: &str, b: &str) -> usize {
    let b: Vec<char> = b.chars().collect();
    let mut previous: Vec<usize> = (0..=b.len()).collect();
    for (i, ca) in a.chars().enumerate() {
        let mut current = vec![i + 1];
        for (j, cb) in b.iter().enumerate() {
            let substitute = previous[j] + usize::from(ca != *cb);
            current.push(substitute.min(previous[j + 1] + 1).min(current[j] + 1));
        }
        previous = current;
    }
    previous[b.len()]
}

/// "Did you mean `x`? ", the start of a help, for a suggestion; empty for
/// none.
fn did_you_mean(suggestion: Option<&str>) -> String {
    suggestion.map_or_else(String::new, |s| format!("Did you mean `{s}`? "))
}

/// The width [`render_narrow`] wraps at.
pub const NARROW_WIDTH: usize = 80;

/// Renders every problem with miette's graphical handler, without colour
/// or links, wrapped at [`NARROW_WIDTH`] columns, without trailing
/// whitespace, separated by blank lines. The output depends only on the
/// diagnostics, not on the terminal, so tests can pin it.
pub fn render_narrow(diagnostics: &Diagnostics) -> String {
    let handler = GraphicalReportHandler::new_themed(GraphicalTheme::unicode_nocolor())
        .with_width(NARROW_WIDTH)
        .with_links(false)
        .with_urls(false);
    let rendered: Vec<String> = diagnostics
        .iter()
        .map(|problem| {
            let mut out = String::new();
            handler
                .render_report(&mut out, problem)
                .expect("rendering into a String cannot fail");
            // miette pads some lines (a related note's `Advice: ` header)
            // with trailing spaces, which are noise in a pinned file.
            let lines: Vec<&str> = out.trim_end().lines().map(str::trim_end).collect();
            lines.join("\n") + "\n"
        })
        .collect();
    rendered.join("\n")
}
