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

mod spans;

use std::collections::HashMap;
use std::fmt;

use miette::{
    Diagnostic, GraphicalReportHandler, GraphicalTheme, LabeledSpan, NamedSource, Severity,
    SourceCode,
};

pub use spans::{Columns, LineColSpan, Spans, tag};

/// The message every entry point reports until generation exists.
pub const NOT_IMPLEMENTED: &str = "elm-connect: type generation is not implemented yet";

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
    /// A field uses `google.protobuf.Any`.
    Any,
    /// A field uses a `google.protobuf` type with no Elm mapping.
    UnsupportedWellKnown,
    /// A generated package refers to a type in a package not generated.
    NotGenerated,
    /// Generated packages refer to each other in a cycle.
    ImportCycle,
    /// A file to generate is not in the descriptor set.
    UnknownFile,
    /// A file to generate is not proto3.
    NotProto3,
    /// The protos use a construct the generator does not emit yet.
    Unimplemented,
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
            Code::Any => "types::any",
            Code::UnsupportedWellKnown => "types::unsupported_well_known",
            Code::NotGenerated => "generate::not_generated",
            Code::ImportCycle => "generate::import_cycle",
            Code::UnknownFile => "generate::unknown_file",
            Code::NotProto3 => "generate::not_proto3",
            Code::Unimplemented => "generate::unimplemented",
        }
    }
}

impl fmt::Display for Code {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
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
            message,
            help: help.into(),
            sites,
            attached: None,
        }
    }

    /// What kind of problem this is.
    pub fn code(&self) -> Code {
        self.code
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
             cannot have two fields with one name. Rename one of them in the proto.",
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
             define two types with one name. Rename one of them in the proto.",
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
             Rename one of them in the proto.",
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
             letter. Rename the package.",
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
             PascalCase form starts with one.",
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
             name should be lower_snake_case, starting with a letter.",
            vec![site],
        )
    }

    /// The field `field` of `message` is a `google.protobuf.Any`.
    pub fn any(message: &str, field: &str, site: Site) -> Self {
        Problem::new(
            Code::Any,
            format!(
                "The field `{field}` of `{message}` has type `google.protobuf.Any`, which \
                 elm-connect does not support."
            ),
            "Decoding an `Any` needs a registry of every type it might hold, and generated Elm \
             code has none. Use a oneof of the concrete messages instead, or \
             `google.protobuf.Struct` for free-form JSON.",
            vec![site],
        )
    }

    /// The field `field` of `message` uses `type_name`, a `google.protobuf`
    /// type elm-connect has no mapping for.
    pub fn unsupported_well_known(message: &str, field: &str, type_name: &str, site: Site) -> Self {
        Problem::new(
            Code::UnsupportedWellKnown,
            format!(
                "The field `{field}` of `{message}` has type `{type_name}`, a well-known type \
                 elm-connect has no Elm mapping for."
            ),
            "The supported well-known types are Timestamp, Duration, FieldMask, Empty, Struct, \
             Value, ListValue and the wrappers like Int32Value. Use one of those, or a message \
             of your own.",
            vec![site],
        )
    }

    /// The field `field` of `message` refers to `type_name`, whose package
    /// `package` (declared in `file`) is not being generated.
    pub fn not_generated(
        message: &str,
        field: &str,
        type_name: &str,
        package: &str,
        file: &str,
        site: Site,
    ) -> Self {
        Problem::new(
            Code::NotGenerated,
            format!(
                "The field `{field}` of `{message}` refers to `{type_name}`, but the package \
                 `{package}` is not being generated."
            ),
            format!(
                "Generated Elm modules import the modules of every package they refer to, so \
                 those packages must be generated too. Add `{file}` to the files to generate."
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
        Some(Severity::Error)
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
/// `Diagnostics` as its error has at least one.
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
        match self.problems.len() {
            1 => f.write_str("elm-connect found a problem in the protos"),
            n => write!(f, "elm-connect found {n} problems in the protos"),
        }
    }
}

impl std::error::Error for Diagnostics {}

impl Diagnostic for Diagnostics {
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
/// or links, wrapped at [`NARROW_WIDTH`] columns, separated by blank lines. The
/// output depends only on the diagnostics, not on the terminal, so tests
/// can pin it.
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
            out.trim_end().to_owned() + "\n"
        })
        .collect();
    rendered.join("\n")
}
