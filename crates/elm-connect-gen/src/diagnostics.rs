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
//! Most problems are errors, which fail the run. A few are warnings: what
//! an option told the generator to leave out (`streaming=skip`), reported
//! beside a successful run so the omission is never silent.

mod spans;

use std::collections::HashMap;
use std::fmt;

use miette::{
    Diagnostic, GraphicalReportHandler, GraphicalTheme, LabeledSpan, NamedSource, Severity,
    SourceCode,
};

pub use spans::{Columns, LineColSpan, Spans, tag};

/// The kinds of problem the generator reports.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Code {
    /// Two fields (or a field and a oneof) of a message become the same
    /// Elm record field.
    FieldCollision,
    /// Two messages, enums or oneofs of a package become the same Elm type.
    TypeCollision,
    /// Two enum values, oneof cases or message record constructors of a
    /// package become the same Elm constructor.
    ConstructorCollision,
    /// A package has no Elm module name.
    InvalidModule,
    /// A message or enum has no valid Elm type name.
    InvalidType,
    /// A field or oneof has no valid Elm record field name.
    InvalidField,
    /// A field uses a `google.protobuf` type with no Elm mapping.
    UnsupportedWellKnown,
    /// A generated package refers to a type in a package not generated.
    NotGenerated,
    /// Generated packages refer to each other in a cycle.
    ImportCycle,
    /// A file to generate is not in the descriptor set.
    UnknownFile,
    /// A `rename` gives a name the element it renames cannot take.
    InvalidRename,
    /// A `rename` names nothing that is generated.
    UnknownRename,
    /// A file to generate is not proto3.
    NotProto3,
    /// The protos use a construct the generator does not emit yet.
    Unimplemented,
    /// A method streams requests or responses.
    Streaming,
    /// A method has no `google.api.http` rule, under
    /// `unbound_methods=error`.
    UnboundMethod,
    /// Two methods of a service get the same Elm value name, or a method
    /// gets the name of the value every generated module defines.
    ValueCollision,
    /// A method has no valid Elm value name.
    InvalidMethod,
    /// Two generated modules, each a package's or a service's, get the
    /// same Elm module name.
    ModuleCollision,
    /// A service has no valid Elm module name.
    InvalidService,
    /// An HTTP rule has no pattern, or nests additional bindings.
    RouteRule,
    /// An HTTP rule's path template does not parse, or has a wildcard
    /// outside a variable.
    RouteTemplate,
    /// A path variable names no field a path can hold.
    RoutePathField,
    /// `body` names no message field of the request.
    RouteBodyField,
    /// `response_body` names no field of the response.
    RouteResponseBody,
    /// A request field that would be a query parameter has no query form.
    RouteQueryField,
}

impl Code {
    /// The short code shown with the diagnostic.
    pub fn as_str(self) -> &'static str {
        match self {
            Code::FieldCollision => "naming::field_collision",
            Code::TypeCollision => "naming::type_collision",
            Code::ConstructorCollision => "naming::constructor_collision",
            Code::InvalidModule => "naming::invalid_module",
            Code::InvalidType => "naming::invalid_type",
            Code::InvalidField => "naming::invalid_field",
            Code::UnsupportedWellKnown => "types::unsupported_well_known",
            Code::NotGenerated => "generate::not_generated",
            Code::ImportCycle => "generate::import_cycle",
            Code::UnknownFile => "generate::unknown_file",
            Code::InvalidRename => "options::invalid_rename",
            Code::UnknownRename => "options::unknown_rename",
            Code::NotProto3 => "generate::not_proto3",
            Code::Unimplemented => "generate::unimplemented",
            Code::Streaming => "services::streaming",
            Code::UnboundMethod => "services::unbound_method",
            Code::ValueCollision => "naming::value_collision",
            Code::InvalidMethod => "naming::invalid_method",
            Code::ModuleCollision => "naming::module_collision",
            Code::InvalidService => "naming::invalid_service",
            Code::RouteRule => "route::rule",
            Code::RouteTemplate => "route::template",
            Code::RoutePathField => "route::path_field",
            Code::RouteBodyField => "route::body_field",
            Code::RouteResponseBody => "route::response_body",
            Code::RouteQueryField => "route::query_field",
        }
    }
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
}

/// One problem in the user's protos.
#[derive(Clone, Debug)]
pub struct Problem {
    code: Code,
    warning: bool,
    message: String,
    help: String,
    sites: Vec<Site>,
    attached: Option<Attached>,
}

/// The source snippets of a problem, once its source text is known.
#[derive(Clone, Debug)]
struct Attached {
    source: NamedSource<String>,
    labels: Vec<LabeledSpan>,
    elsewhere: Vec<Elsewhere>,
}

/// The sites of a problem that lie in another file than its first one,
/// shown as a related note with that file's snippet.
#[derive(Clone, Debug)]
struct Elsewhere {
    message: String,
    source: NamedSource<String>,
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
    pub fn field_collision(message: &str, elm_name: &str, first: Site, second: Site) -> Self {
        Problem::new(
            Code::FieldCollision,
            format!("The message `{message}` has two fields that both become `{elm_name}` in Elm."),
            "Elm record fields are the proto field names in lowerCamelCase, so names that \
             differ only in underscores or reserved-word escaping end up the same, and a record \
             cannot have two fields with one name. Rename one of them in the proto, or \
             rename one with `rename=<proto full name>:<Elm name>`.",
            vec![first, second],
        )
    }

    /// Two definitions of `package` become the same Elm type `elm_name`.
    pub fn type_collision(package: &str, elm_name: &str, first: Site, second: Site) -> Self {
        Problem::new(
            Code::TypeCollision,
            format!(
                "The package `{package}` has two definitions that both become the Elm type \
                 `{elm_name}`."
            ),
            "Every message, enum and oneof of a package becomes a type in one Elm module, \
             nested names joined (`Outer.Inner` becomes `OuterInner`), and a module cannot \
             define two types with one name. Rename one of them in the proto, or rename one \
             with `rename=<proto full name>:<Elm name>`.",
            vec![first, second],
        )
    }

    /// Two definitions of `package` become the same Elm constructor
    /// `elm_name`.
    pub fn constructor_collision(package: &str, elm_name: &str, first: Site, second: Site) -> Self {
        Problem::new(
            Code::ConstructorCollision,
            format!(
                "The package `{package}` has two definitions that both become the Elm \
                 constructor `{elm_name}`."
            ),
            "Enum values, oneof cases and the record constructor of every message all share \
             one constructor namespace in an Elm module, so these cannot both keep this name. \
             Rename one of them in the proto, or rename one with \
             `rename=<proto full name>:<Elm name>`.",
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
    pub fn invalid_module(package: &str, segment: &str, site: Site) -> Self {
        Problem::new(
            Code::InvalidModule,
            format!(
                "The package `{package}` cannot become an Elm module name: its segment \
                 `{segment}` does not start with a letter."
            ),
            "Each package segment becomes a segment of the Elm module name in PascalCase \
             (`notes.v1` becomes `Notes.V1`), and an Elm module segment must start with a \
             letter. Rename the package, or rename it with \
             `rename=<proto full name>:<Elm name>`.",
            vec![site],
        )
    }

    /// The type `proto_name` becomes `converted`, which is not an Elm type
    /// name.
    pub fn invalid_type(proto_name: &str, converted: &str, site: Site) -> Self {
        Problem::new(
            Code::InvalidType,
            format!(
                "The type `{proto_name}` becomes `{converted}` in Elm, which is not a valid Elm \
                 type name."
            ),
            "Elm type names must start with an uppercase letter. Rename the proto type so its \
             PascalCase form starts with one, or rename it with \
             `rename=<proto full name>:<Elm name>`.",
            vec![site],
        )
    }

    /// The field (or oneof) `proto_name` of `message` becomes `converted`,
    /// which is not an Elm record field name.
    pub fn invalid_field(message: &str, proto_name: &str, converted: &str, site: Site) -> Self {
        Problem::new(
            Code::InvalidField,
            format!(
                "The field `{proto_name}` of `{message}` becomes `{converted}` in Elm, which is \
                 not a valid record field name."
            ),
            "Elm record fields must start with a lowercase letter. elm-connect converts proto \
             field names to lowerCamelCase without changing their first letter, so the proto \
             name should be lower_snake_case, starting with a letter. Rename it in the \
             proto, or rename it with `rename=<proto full name>:<Elm name>`.",
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
    /// "bidirectional").
    pub fn streaming(method: &str, which: &str, site: Site) -> Self {
        Problem::new(
            Code::Streaming,
            format!(
                "The method `{method}` is {which} streaming, and streaming methods are not \
                 supported."
            ),
            "elm-connect generates unary calls only: Connect streaming and the transcoders' \
             streaming each frame messages differently, and neither has an Elm design yet. \
             Pass `streaming=skip` to leave streaming methods out and generate the rest.",
            vec![site],
        )
    }

    /// The method `method` streams (`which`, as for [`Problem::streaming`])
    /// and `streaming=skip` leaves it out of its service's module: a
    /// warning.
    pub fn streaming_skipped(method: &str, which: &str, site: Site) -> Self {
        Problem::new(
            Code::Streaming,
            format!(
                "The method `{method}` is {which} streaming, so it is left out of the \
                 generated code."
            ),
            "elm-connect generates unary calls only, and `streaming=skip` leaves each \
             streaming method out of its service's module rather than failing. Calls to this \
             method are not generated; drop the option to make it an error again.",
            vec![site],
        )
        .warning()
    }

    /// The method `method` has no `google.api.http` rule, and
    /// `unbound_methods=error` makes that a problem.
    pub fn unbound_method(method: &str, site: Site) -> Self {
        Problem::new(
            Code::UnboundMethod,
            format!("The method `{method}` has no `google.api.http` rule."),
            "With `unbound_methods=error`, every method needs a rule. Without one, a call over \
             transcoding takes the implicit route, `POST /<package>.<Service>/<Method>` with \
             the request as its body, which grpc-gateway serves with \
             `generate_unbound_methods`, Envoy's transcoder with `auto_mapping`, and Vanguard \
             always. Add a rule to the method, or set `unbound_methods=implicit` (the \
             default) if the server serves that route.",
            vec![site],
        )
    }

    /// Two methods of `service` become the same Elm value `elm_name`.
    pub fn value_collision(service: &str, elm_name: &str, first: Site, second: Site) -> Self {
        Problem::new(
            Code::ValueCollision,
            format!(
                "The service `{service}` has two methods that both become the Elm value \
                 `{elm_name}`."
            ),
            "A service's module defines one value per method, its name with the first letter \
             lowercased and underscores dropped, so names that differ only in those ways end \
             up the same, and a module cannot define two values with one name. Rename one of \
             the methods in the proto, or rename one with \
             `rename=<proto full name>:<Elm name>`.",
            vec![first, second],
        )
    }

    /// A `rename` gives the method `method` the name `elm_name`, the value
    /// every generated module defines to name the release it was generated
    /// for. No proto name derives to it.
    pub fn reserved_value(method: &str, elm_name: &str, site: Site) -> Self {
        Problem::new(
            Code::ValueCollision,
            format!(
                "The method `{method}` is renamed to the Elm value `{elm_name}`, which every \
                 generated module defines already."
            ),
            "Every generated module defines `elmConnectVersion_`, which names the release of \
             the generator it came from, so a module cannot have a method of that name too. \
             Give the method another name in its `rename=<proto full name>:<Elm name>`.",
            vec![site],
        )
    }

    /// Two generated modules, each a package's or a service's, become the
    /// same Elm module `elm_module`.
    pub fn module_collision(elm_module: &str, first: Site, second: Site) -> Self {
        Problem::new(
            Code::ModuleCollision,
            format!("Two generated modules both become the Elm module `{elm_module}`."),
            "Every package becomes an Elm module (`notes.v1` becomes `Notes.V1`), and every \
             service becomes a module inside its package's (`notes.v1.NotesService` becomes \
             `Notes.V1.NotesService`), each segment in PascalCase, so a service can take the \
             name of a package nested in its own, and names that differ only in case or \
             underscores end up the same. Rename the service or the package, or rename one \
             with `rename=<proto full name>:<Elm name>`.",
            vec![first, second],
        )
    }

    /// The service `service`'s name does not start with a letter once
    /// converted to PascalCase.
    pub fn invalid_service(service: &str, site: Site) -> Self {
        Problem::new(
            Code::InvalidService,
            format!(
                "The service `{service}` cannot become an Elm module name: its name does not \
                 start with a letter."
            ),
            "Each service becomes an Elm module inside its package's, named for the service \
             in PascalCase (`notes.v1.Notes` becomes `Notes.V1.Notes`), and an Elm module \
             segment must start with a letter. Rename the service, or rename it with \
             `rename=<proto full name>:<Elm name>`.",
            vec![site],
        )
    }

    /// `binding` (such as "The HTTP rule of `notes.v1.Notes.GetNote`")
    /// does not resolve, for `error`.
    pub fn route(binding: &str, error: &crate::route::RouteError, site: Site) -> Self {
        use crate::route::RouteError as E;
        let (code, message, help): (Code, String, &str) = match error {
            E::NoPattern => (
                Code::RouteRule,
                format!("{binding} has no path."),
                "A rule sets one of `get`, `put`, `post`, `delete` or `patch` to a path \
                 template, or `custom` to a kind and a path.",
            ),
            E::NestedBindings => (
                Code::RouteRule,
                format!("{binding} has additional bindings of its own."),
                "`google/api/http.proto` allows additional bindings one level deep only. Move \
                 the nested bindings up into the rule's own `additional_bindings`.",
            ),
            E::Syntax { template, error } => (
                Code::RouteTemplate,
                format!("{binding} has the path `{template}`, which does not parse: {error}."),
                "A path template is `/` and segments separated by `/`, each a literal, `*`, \
                 `**` (last only) or a variable like `{name}` or `{name=messages/*}`, \
                 optionally followed by a custom verb like `:cancel`.",
            ),
            E::UnboundWildcard { template } => (
                Code::RouteTemplate,
                format!("{binding} has the path `{template}`, with a wildcard outside a variable."),
                "A client fills each path segment from a request field, and a bare `*` or `**` \
                 names none. Bind it to a field, like `{name=*}`.",
            ),
            E::PathField { field, reason } => (
                Code::RoutePathField,
                format!("{binding} binds `{{{field}}}` in its path, but {reason}."),
                "A path variable names a non-repeated scalar or enum field of the request, \
                 possibly through singular message fields (`{book.name}`).",
            ),
            E::PathFieldTwice { field } => (
                Code::RoutePathField,
                format!("{binding} binds `{{{field}}}` in its path twice."),
                "Each field can fill one path variable. Remove one of them.",
            ),
            E::BodyField { field, reason } => (
                Code::RouteBodyField,
                format!("{binding} has `body: \"{field}\"`, but {reason}."),
                "`body` is `*` for every field not in the path, or the name of a top-level \
                 singular message field of the request, or left out for no body.",
            ),
            E::ResponseBodyField { field } => (
                Code::RouteResponseBody,
                format!(
                    "{binding} has `response_body: \"{field}\"`, but the response has no such \
                     field."
                ),
                "`response_body` names a top-level field of the response, or is left out for \
                 the whole response.",
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
                 move it out of the request.",
            ),
        };
        Problem::new(code, message, help, vec![site])
    }

    /// The method `method`'s name becomes `converted`, which is not an Elm
    /// value name.
    pub fn invalid_method(method: &str, converted: &str, site: Site) -> Self {
        Problem::new(
            Code::InvalidMethod,
            format!(
                "The method `{method}` becomes `{converted}` in Elm, which is not a valid Elm \
                 value name."
            ),
            "A method's Elm value is its name with the first letter lowercased and \
             underscores dropped, and must start with a letter. Rename the method, or rename \
             it with `rename=<proto full name>:<Elm name>`.",
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

    /// The `rename` of `proto` names nothing that is generated.
    pub fn unknown_rename(proto: &str) -> Self {
        Problem::new(
            Code::UnknownRename,
            format!("The rename of `{proto}` names nothing elm-connect generates."),
            "A rename names a package, service, method, message, enum, field, oneof or enum \
             value of a generated package by its proto full name: nested names dotted \
             (`notes.v1.Note.Revision`, `notes.v1.Note.title`), an enum value under its enum \
             (`notes.v1.Visibility.VISIBILITY_PUBLIC`). Check the name against the protos.",
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

    /// `file` uses `syntax`, not proto3.
    pub fn not_proto3(file: &str, syntax: &str, site: Site) -> Self {
        Problem::new(
            Code::NotProto3,
            format!("The file `{file}` uses {syntax} syntax, but elm-connect generates proto3."),
            "elm-connect implements the proto3 JSON mapping; proto2 features like `required` \
             and default values have no Elm mapping. Use `syntax = \"proto3\";`.",
            vec![site],
        )
    }

    /// `element` (a proto full name, such as `notes.v1.Note.tags`) is
    /// `construct` (such as "a repeated field"), which elm-connect has no
    /// emitter for yet. The problem names the element rather than pointing
    /// at it: the emitter works from the IR, which keeps no source spans.
    pub fn unimplemented(element: &str, construct: &str) -> Self {
        Problem::new(
            Code::Unimplemented,
            format!("`{element}` is {construct}, which elm-connect cannot generate yet."),
            "This version of elm-connect generates only part of proto3. Leave this element out \
             of the files to generate, or use a later version.",
            Vec::new(),
        )
    }

    fn attach(&mut self, sources: &HashMap<String, String>, columns: Columns) {
        let Some(primary) = self.sites.first().map(|site| site.file.clone()) else {
            return;
        };
        let Some(text) = sources.get(&primary) else {
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
        self.attached = Some(Attached {
            source: NamedSource::new(&primary, text.clone()),
            labels,
            elsewhere,
        });
    }

    fn labels_in(&self, file: &str, text: &str, columns: Columns) -> Vec<LabeledSpan> {
        self.sites
            .iter()
            .filter(|site| site.file == file)
            .filter_map(|site| {
                let span = site.span?.byte_span(text, columns)?;
                Some(LabeledSpan::new_with_span(Some(site.label.clone()), span))
            })
            .collect()
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

impl fmt::Display for Problem {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
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

    /// Gives every problem the source text of its files, so it renders
    /// with snippets. `sources` maps proto file names to their text;
    /// `columns` says how the compiler counted columns. A file missing from
    /// `sources`, or a span that does not fit its text, renders without a
    /// snippet.
    pub fn attach_sources(&mut self, sources: &HashMap<String, String>, columns: Columns) {
        for problem in &mut self.problems {
            problem.attach(sources, columns);
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
        match (self.all_warnings(), self.problems.len()) {
            (true, 1) => f.write_str("elm-connect has a warning about the protos"),
            (true, n) => write!(f, "elm-connect has {n} warnings about the protos"),
            (false, 1) => f.write_str("elm-connect found a problem in the protos"),
            (false, n) => write!(f, "elm-connect found {n} problems in the protos"),
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
