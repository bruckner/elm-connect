//! The standalone CLI's logic, kept out of `main` so tests can drive it
//! in-process.

use std::collections::{BTreeSet, HashMap};
use std::fs;
use std::path::{Path, PathBuf};

use elm_connect_gen::diagnostics::{
    Code, Columns, Diagnostics, LineColSpan, Problem, Site, field_name_conflict_names,
    field_name_conflicts,
};
use elm_connect_gen::{Generated, GeneratedFile, Options, Spelling};
use miette::{Diagnostic, IntoDiagnostic, Report, WrapErr};
use protox::prost_reflect::{DescriptorPool, FileDescriptor, Kind, MessageDescriptor};

/// What compiling the inputs gives the generator.
#[derive(Debug)]
pub struct Compiled {
    /// Every resolved file, imports included.
    pub pool: DescriptorPool,
    /// The names, as `pool` knows them, of the files named on the command
    /// line: the set to generate, each of its packages whole.
    pub inputs: Vec<String>,
    /// The names of the imported files to generate as well, each of its
    /// package alone: empty unless [`Compiled::include_imports`] filled it.
    pub imports: Vec<String>,
    /// The text of every resolved file read from disk, by name, for
    /// diagnostics.
    pub sources: HashMap<String, String>,
}

impl Compiled {
    /// Sets `imports` to what `--include-imports` asks for: every imported
    /// file that declares a message or enum the requested packages refer
    /// to, through fields and methods, transitively, since such a file is
    /// generated whole and its own references count too. A file imported
    /// only for its options, such as `google/api/annotations.proto` or
    /// `google/api/client.proto`, declares nothing referred to and is left
    /// out, as are `google/protobuf` files, which map to the runtime, and
    /// files of the requested packages, which are generated whole anyway.
    pub fn include_imports(&mut self) {
        let requested: BTreeSet<String> = self
            .inputs
            .iter()
            .filter_map(|name| self.pool.get_file_by_name(name))
            .map(|file| file.package_name().to_owned())
            .collect();
        let mut pending: Vec<FileDescriptor> = self
            .pool
            .files()
            .filter(|file| requested.contains(file.package_name()))
            .collect();
        let mut imports = BTreeSet::new();
        while let Some(file) = pending.pop() {
            for referenced in referenced_files(&file) {
                let name = referenced.name();
                if name.starts_with("google/protobuf/")
                    || requested.contains(referenced.package_name())
                    || !imports.insert(name.to_owned())
                {
                    continue;
                }
                pending.push(referenced);
            }
        }
        self.imports = imports.into_iter().collect();
    }
}

/// The files declaring the messages and enums `file`'s messages and
/// methods refer to, its own among them.
fn referenced_files(file: &FileDescriptor) -> Vec<FileDescriptor> {
    let mut messages: Vec<MessageDescriptor> = file.messages().collect();
    let mut referenced = Vec::new();
    while let Some(message) = messages.pop() {
        messages.extend(message.child_messages());
        for field in message.fields() {
            match field.kind() {
                Kind::Message(target) => referenced.push(target.parent_file()),
                Kind::Enum(target) => referenced.push(target.parent_file()),
                _ => {}
            }
        }
    }
    for service in file.services() {
        for method in service.methods() {
            referenced.push(method.input().parent_file());
            referenced.push(method.output().parent_file());
        }
    }
    referenced
}

/// Compiles `files` against the `includes` search path (`.` if empty),
/// then protox's bundled `google/protobuf` files and the googleapis files
/// elm-connect embeds (`google/api/annotations.proto`,
/// `google/api/http.proto` and `google/api/field_behavior.proto`), so
/// `google.api.http` and `google.api.field_behavior` need no googleapis
/// checkout.
///
/// A compile error comes back as a `Report` carrying the proto source and the
/// span at fault, so it renders with the offending line underlined.
pub fn compile(files: &[PathBuf], includes: &[PathBuf]) -> Result<Compiled, Report> {
    let includes: Vec<PathBuf> = if includes.is_empty() {
        vec![PathBuf::from(".")]
    } else {
        includes.to_vec()
    };
    let mut compiler = protox::Compiler::with_file_resolver(elm_connect_gen::googleapis::resolver(
        includes.iter().cloned(),
    ));
    compiler.include_source_info(true).include_imports(true);
    if let Err(error) = compiler.open_files(files) {
        if let Some(report) = editions_problem(&error, &includes) {
            return Err(report);
        }
        if let Some(report) = proto2_problem(&error, files, &includes) {
            return Err(report);
        }
        let error = match field_name_conflict(error, &includes) {
            Ok(report) => return Err(report),
            Err(error) => error,
        };
        if error.is_file_not_found() {
            return Err(Report::new(NotFound {
                error,
                includes: includes.clone(),
            }));
        }
        return Err(error.into());
    }
    let mut inputs = Vec::new();
    let mut sources = HashMap::new();
    for file in compiler.files() {
        if !file.is_import() {
            inputs.push(file.name().to_owned());
        }
        if let Some(text) = file.path().and_then(|path| fs::read_to_string(path).ok()) {
            sources.insert(file.name().to_owned(), text);
        }
    }
    inputs.sort();
    Ok(Compiled {
        pool: compiler.descriptor_pool(),
        inputs,
        imports: Vec::new(),
        sources,
    })
}

/// protox's error for a file or import found on no include path, as protox
/// renders it, with a help naming the include paths it searched.
#[derive(Debug)]
struct NotFound {
    error: protox::Error,
    includes: Vec<PathBuf>,
}

impl std::fmt::Display for NotFound {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        std::fmt::Display::fmt(&self.error, f)
    }
}

impl std::error::Error for NotFound {}

impl Diagnostic for NotFound {
    fn code<'a>(&'a self) -> Option<Box<dyn std::fmt::Display + 'a>> {
        Some(Box::new(Code::FileNotFound.as_str()))
    }

    fn help<'a>(&'a self) -> Option<Box<dyn std::fmt::Display + 'a>> {
        let searched: Vec<String> = self
            .includes
            .iter()
            .map(|include| format!("`{}`", include.display()))
            .collect();
        // An include path that is no directory is the likelier mistake.
        let missing: String = self
            .includes
            .iter()
            .filter(|include| !include.is_dir())
            .map(|include| {
                let what = if include.exists() {
                    "is not a directory"
                } else {
                    "does not exist"
                };
                format!(" `{}` {what}.", include.display())
            })
            .collect();
        Some(Box::new(format!(
            "The include paths searched were {} (`-I`, `.` when none is given), then the \
             `google/protobuf` files and the `google/api` annotations elm-connect bundles.\
             {missing} Add the directory the file is under with `-I`, and name it relative to \
             that directory.",
            searched.join(", ")
        )))
    }

    fn source_code(&self) -> Option<&dyn miette::SourceCode> {
        self.error.source_code()
    }

    fn labels(&self) -> Option<Box<dyn Iterator<Item = miette::LabeledSpan> + '_>> {
        self.error.labels()
    }
}

/// protox's refusal of two fields of a message whose names are the same
/// once lowercased without underscores, which protoc accepts, as
/// `input::field_name_conflict` at the two fields, or `error` back for any
/// other error. protox exposes neither the descriptor library's error nor
/// its kind, only its text, so the error is recognised by that; the
/// message is found by parsing the file again from `includes`, at the
/// field the error points to.
fn field_name_conflict(
    error: protox::Error,
    includes: &[PathBuf],
) -> Result<Report, protox::Error> {
    if error.is_parse() || error.is_io() || error.is_file_not_found() {
        return Err(error);
    }
    let text = error.to_string();
    let Some((first, second)) = field_name_conflict_names(&text) else {
        return Err(error);
    };
    let name = error.file().unwrap_or_default().to_owned();
    let source = includes
        .iter()
        .find_map(|include| fs::read_to_string(include.join(&name)).ok());
    let parsed = source
        .as_deref()
        .and_then(|source| protox::file::File::from_source(&name, source).ok());
    let conflicts = parsed
        .as_ref()
        .map(|file| field_name_conflicts(file.file_descriptor_proto(), first, second))
        .unwrap_or_default();
    // The label offsets of the error, to tell apart two messages with
    // fields of the same two names.
    let offsets: Vec<usize> = error
        .labels()
        .map(|labels| labels.map(|label| label.offset()).collect())
        .unwrap_or_default();
    let at = |conflict: &&elm_connect_gen::diagnostics::FieldNameConflict| {
        let start = |site: &Site| {
            let span = site.span?;
            Some(span.byte_span(source.as_deref()?, Columns::Bytes)?.offset())
        };
        conflict
            .sites
            .iter()
            .all(|site| start(site).is_some_and(|offset| offsets.contains(&offset)))
    };
    let conflict = conflicts.iter().find(at).or(conflicts.first());
    let problem = Problem::field_name_conflict(
        &name,
        conflict.map(|conflict| conflict.message.as_str()),
        first,
        second,
        Spelling::Flags,
        conflict
            .map(|conflict| conflict.sites.clone())
            .unwrap_or_default(),
    );
    Ok(match source {
        Some(source) => report(problem, &name, source),
        None => Report::new(Diagnostics::from(problem)),
    })
}

/// The `input::editions` problem for a parse `error` in a file that
/// declares an edition, which protox cannot parse: the file is found
/// again on `includes` and its first statement read. `None` for any other
/// error.
fn editions_problem(error: &protox::Error, includes: &[PathBuf]) -> Option<Report> {
    if !error.is_parse() {
        return None;
    }
    let name = error.file()?;
    let source = includes
        .iter()
        .find_map(|include| fs::read_to_string(include.join(name)).ok())?;
    let (edition, span) = first_statement(&source, "edition")?;
    let site = Site {
        file: name.to_owned(),
        span: Some(span),
        label: "the edition".into(),
        within: Vec::new(),
    };
    Some(report(
        Problem::editions(name, Some(&edition), site),
        name,
        source,
    ))
}

/// The `input::not_proto3` problem for a parse `error` in one of `files`
/// that is proto2, by `syntax = "proto2";` or by declaring no syntax or
/// edition at all. A proto3 file turned proto2 fails to parse (its fields
/// have no labels), and the parser's errors would hide that the file is
/// refused anyway. An imported proto2 file is left to the parser: proto2
/// imports are allowed. `None` for any other error.
fn proto2_problem(
    error: &protox::Error,
    files: &[PathBuf],
    includes: &[PathBuf],
) -> Option<Report> {
    if !error.is_parse() {
        return None;
    }
    let name = error.file()?;
    if !files.iter().any(|file| file.ends_with(name)) {
        return None;
    }
    let source = includes
        .iter()
        .find_map(|include| fs::read_to_string(include.join(name)).ok())?;
    let (syntax, span, label) = match first_statement(&source, "syntax") {
        Some((syntax, span)) if syntax == "proto2" => (Some("proto2"), span, "proto2 here"),
        Some(_) => return None,
        None if first_statement(&source, "edition").is_some() => return None,
        None => (
            None,
            LineColSpan {
                start_line: 0,
                start_col: 0,
                end_line: 0,
                end_col: 0,
            },
            "no `syntax` statement before this",
        ),
    };
    let site = Site {
        file: name.to_owned(),
        span: Some(span),
        label: label.into(),
        within: Vec::new(),
    };
    Some(report(
        Problem::not_proto3(name, syntax, site),
        name,
        source,
    ))
}

/// `problem`, sited in `name` whose text is `source`, as the one problem
/// of a report.
fn report(problem: Problem, name: &str, source: String) -> Report {
    let mut diagnostics = Diagnostics::new();
    diagnostics.push(problem);
    let sources = HashMap::from([(name.to_owned(), source)]);
    diagnostics.attach_sources(&sources, Columns::Bytes);
    Report::new(diagnostics)
}

/// The value `source`'s first statement gives `keyword`, `2023` of
/// `edition = "2023";` for `edition`, and the span of that statement, when
/// its first statement is one.
fn first_statement(source: &str, keyword: &str) -> Option<(String, LineColSpan)> {
    let bytes = source.as_bytes();
    // Past whitespace and comments from `at`.
    let skip = |mut at: usize| loop {
        let rest = &source[at..];
        let trimmed = rest.trim_start();
        at += rest.len() - trimmed.len();
        if trimmed.starts_with("//") {
            at += trimmed.find('\n').unwrap_or(trimmed.len());
        } else if let Some(comment) = trimmed.strip_prefix("/*") {
            at += 2 + comment.find("*/").map_or(comment.len(), |end| end + 2);
        } else {
            return at;
        }
    };
    let start = skip(0);
    let after = start + keyword.len();
    let declares = source.get(start..after)? == keyword
        && !bytes
            .get(after)
            .is_some_and(|b| b.is_ascii_alphanumeric() || *b == b'_');
    if !declares {
        return None;
    }
    let at = skip(after);
    let at = skip(at + source[at..].strip_prefix('=').map(|_| 1)?);
    let quote = *bytes.get(at).filter(|b| matches!(b, b'"' | b'\''))?;
    let len = source[at + 1..].find(char::from(quote))?;
    let value = source[at + 1..at + 1 + len].to_owned();
    let mut end = at + len + 2;
    let semicolon = skip(end);
    if source[semicolon..].starts_with(';') {
        end = semicolon + 1;
    }
    let position = |offset: usize| {
        let before = &source[..offset];
        let line = before.matches('\n').count();
        let col = offset - before.rfind('\n').map_or(0, |newline| newline + 1);
        (u32::try_from(line).ok(), u32::try_from(col).ok())
    };
    let (start_line, start_col) = position(start);
    let (end_line, end_col) = position(end);
    let span = LineColSpan {
        start_line: start_line?,
        start_col: start_col?,
        end_line: end_line?,
        end_col: end_col?,
    };
    Some((value, span))
}

/// Compiles `files` against `includes` and generates Elm from them as
/// `options` say: from the packages of `files` alone, or, with
/// `include_imports`, from those of every file they import too (see
/// [`Compiled::include_imports`]).
///
/// Problems in the protos come back as one `Report` whose snippets point
/// into the proto sources; the warnings of a successful run carry their
/// snippets too.
pub fn generate(
    files: &[PathBuf],
    includes: &[PathBuf],
    include_imports: bool,
    options: &Options,
) -> Result<Generated, Report> {
    let mut compiled = compile(files, includes)?;
    if include_imports {
        compiled.include_imports();
    }
    let inputs: Vec<&str> = compiled.inputs.iter().map(String::as_str).collect();
    let imports: Vec<&str> = compiled.imports.iter().map(String::as_str).collect();
    // protox records columns in bytes.
    match elm_connect_gen::generate_with_imports(&compiled.pool, &inputs, &imports, options) {
        Ok(mut generated) => {
            generated
                .warnings
                .attach_sources(&compiled.sources, Columns::Bytes);
            Ok(generated)
        }
        Err(mut diagnostics) => {
            diagnostics.attach_sources(&compiled.sources, Columns::Bytes);
            Err(Report::new(diagnostics))
        }
    }
}

/// Writes each generated file under `out`, creating directories as
/// needed, and returns the paths written.
pub fn write(files: &[GeneratedFile], out: &Path) -> Result<Vec<PathBuf>, Report> {
    files
        .iter()
        .map(|file| {
            let path = out.join(&file.path);
            if let Some(parent) = path.parent() {
                fs::create_dir_all(parent)
                    .into_diagnostic()
                    .wrap_err_with(|| format!("creating {}", parent.display()))?;
            }
            fs::write(&path, &file.content)
                .into_diagnostic()
                .wrap_err_with(|| format!("writing {}", path.display()))?;
            Ok(path)
        })
        .collect()
}

/// How a tree of generated modules differs from what generating gives now.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Drift {
    /// A module generating gives has no file under the output directory.
    Missing {
        /// The module's path under the output directory.
        path: String,
    },
    /// A module's file differs from what generating gives.
    Differs {
        /// The module's path under the output directory.
        path: String,
        /// The file as it is.
        on_disk: String,
        /// The file as generating gives it.
        generated: String,
    },
    /// A file under the output directory opens with elm-connect's
    /// generated-file notice naming a proto file generating read, but
    /// generating does not give it: left over from a package or service
    /// since removed or renamed.
    Stale {
        /// The file's path under the output directory.
        path: String,
    },
}

/// What [`check`] found: every module of the tree that drifted, by path.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Check {
    /// The output directory checked.
    pub out: PathBuf,
    /// How many modules generating gives.
    pub modules: usize,
    /// Each module or file that drifted, sorted by path; empty when the
    /// tree is current.
    pub drift: Vec<Drift>,
}

/// The line comment that opens every module elm-connect generates.
fn header_start() -> String {
    format!("-- {}", elm_connect_gen::HEADER_PREFIX)
}

/// The stale files under `out`, as `/`-separated paths relative to it,
/// sorted: each `.elm` file whose first line is elm-connect's
/// generated-file notice naming a proto file one of `files` was generated
/// from, but which `files` does not hold. So a module another `gen`
/// writes to the same directory from other protos is not stale, while one
/// of a package or service since removed from these protos is. Other
/// `.elm` files are left alone, since an application may keep its own
/// modules beside the generated ones. A missing `out` has none.
pub fn stale(files: &[GeneratedFile], out: &Path) -> Result<Vec<String>, Report> {
    let generated: BTreeSet<&str> = files.iter().map(|file| file.path.as_str()).collect();
    let sources: BTreeSet<&str> = files
        .iter()
        .flat_map(|file| header_files(&file.content))
        .collect();
    let mut stale = Vec::new();
    for path in elm_files_under(out)? {
        if generated.contains(path.as_str()) {
            continue;
        }
        let full = out.join(&path);
        let text = fs::read_to_string(&full)
            .into_diagnostic()
            .wrap_err_with(|| format!("reading {}", full.display()))?;
        if header_files(&text).any(|file| sources.contains(file)) {
            stale.push(path);
        }
    }
    stale.sort();
    Ok(stale)
}

/// The proto files the header line of `content` names, `a.proto` and
/// `b.proto` of `-- Generated by elm-connect 0.1.0 from a.proto, b.proto.
/// Do not edit; regenerate instead.`; none if it has no such line.
fn header_files(content: &str) -> impl Iterator<Item = &str> {
    let first = content.lines().next().unwrap_or_default();
    first
        .strip_prefix(&header_start())
        .and_then(|rest| rest.split_once(" from "))
        .and_then(|(_, rest)| rest.strip_suffix(". Do not edit; regenerate instead."))
        .into_iter()
        .flat_map(|files| files.split(", "))
}

/// Compares `files`, as generating gives them, with the tree under `out`:
/// a module whose file is missing, a file whose content differs, and a
/// [`stale`] file. A missing `out` is a tree with nothing in it.
pub fn check(files: &[GeneratedFile], out: &Path) -> Result<Check, Report> {
    let mut drift = Vec::new();
    for file in files {
        let path = out.join(&file.path);
        match fs::read_to_string(&path) {
            Ok(on_disk) if on_disk == file.content => {}
            Ok(on_disk) => drift.push(Drift::Differs {
                path: file.path.clone(),
                on_disk,
                generated: file.content.clone(),
            }),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                drift.push(Drift::Missing {
                    path: file.path.clone(),
                });
            }
            Err(error) => {
                return Err(error)
                    .into_diagnostic()
                    .wrap_err_with(|| format!("reading {}", path.display()));
            }
        }
    }
    for path in stale(files, out)? {
        drift.push(Drift::Stale { path });
    }
    drift.sort_by(|a, b| a.path().cmp(b.path()));
    Ok(Check {
        out: out.to_owned(),
        modules: files.len(),
        drift,
    })
}

impl Drift {
    /// The path under the output directory this is about.
    pub fn path(&self) -> &str {
        match self {
            Drift::Missing { path } | Drift::Differs { path, .. } | Drift::Stale { path } => path,
        }
    }
}

impl Check {
    /// Whether the tree is what generating gives.
    pub fn is_current(&self) -> bool {
        self.drift.is_empty()
    }

    /// When the tree differs only in the version it names, the version or
    /// versions that generated it: every drifted module is one whose file
    /// differs only on its header line and its `elmConnectVersion_` line,
    /// and none is missing or stale. `None` otherwise.
    pub fn version_only(&self) -> Option<Vec<String>> {
        let mut versions = BTreeSet::new();
        for drift in &self.drift {
            let Drift::Differs {
                on_disk, generated, ..
            } = drift
            else {
                return None;
            };
            if without_version(on_disk) != without_version(generated) {
                return None;
            }
            versions.insert(header_version(on_disk)?.to_owned());
        }
        (!versions.is_empty()).then(|| versions.into_iter().collect())
    }

    /// The report a person reads: nothing to say when current, the
    /// versions when only they differ, and otherwise each missing and
    /// stale file and a unified diff of each that differs.
    pub fn render(&self) -> String {
        let out = self.out.display();
        if self.is_current() {
            return format!(
                "{} generated modules under {out} are current.\n",
                self.modules
            );
        }
        let mut report = String::new();
        if let Some(versions) = self.version_only() {
            let by = versions.join(", ");
            report.push_str(&format!(
                "The modules under {out} were generated by elm-connect {by}; this is \
                 elm-connect {}. They differ from its output only in the version they name. \
                 Regenerate them with `elm-connect gen` and the same arguments, and use the \
                 runtime package of the same version (`bruckner/elm-connect` {}).\n",
                elm_connect_gen::VERSION,
                elm_connect_gen::VERSION,
            ));
            return report;
        }
        for drift in &self.drift {
            match drift {
                Drift::Missing { path } => {
                    report.push_str(&format!("missing: {out}/{path} is not there\n"));
                }
                Drift::Stale { path } => report.push_str(&format!(
                    "stale: {out}/{path} was generated by elm-connect from these protos, but \
                     generating no longer gives it\n"
                )),
                Drift::Differs {
                    path,
                    on_disk,
                    generated,
                } => report.push_str(&format!(
                    "differs: {out}/{path}\n{}",
                    similar::TextDiff::from_lines(on_disk, generated)
                        .unified_diff()
                        .context_radius(3)
                        .header(
                            &format!("{out}/{path} (on disk)"),
                            &format!("{out}/{path} (generated)")
                        )
                )),
            }
        }
        report.push_str(&format!(
            "The generated modules under {out} are out of date; run `elm-connect gen` with the \
             same arguments to regenerate them, and delete any stale file.\n"
        ));
        report
    }
}

/// The version on `content`'s header line: `0.1.0` of `-- Generated by
/// elm-connect 0.1.0 from ...`.
fn header_version(content: &str) -> Option<&str> {
    let rest = content.strip_prefix(&header_start())?;
    rest.split_once(' ').map(|(version, _)| version)
}

/// `content` with the version on its header line and the `Proto.Version`
/// value its `elmConnectVersion_` names both blanked, so two modules that
/// differ only in the release that generated them compare equal.
fn without_version(content: &str) -> String {
    content
        .lines()
        .enumerate()
        .map(|(index, line)| {
            if index == 0
                && let Some(version) = header_version(content)
            {
                return line.replacen(version, "", 1);
            }
            match line.strip_prefix("    Proto.Version.") {
                Some(name) if is_sentinel(name) => "    Proto.Version.".to_owned(),
                _ => line.to_owned(),
            }
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// Whether `name` has the form of a `Proto.Version` value, `v{major}_{minor}`.
fn is_sentinel(name: &str) -> bool {
    let digits = |s: &str| !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit());
    name.strip_prefix('v')
        .and_then(|rest| rest.split_once('_'))
        .is_some_and(|(major, minor)| digits(major) && digits(minor))
}

/// Every `.elm` file under `dir`, as `/`-separated paths relative to it;
/// none if `dir` does not exist.
fn elm_files_under(dir: &Path) -> Result<Vec<String>, Report> {
    fn walk(dir: &Path, prefix: &str, out: &mut Vec<String>) -> Result<(), Report> {
        let entries = match fs::read_dir(dir) {
            Ok(entries) => entries,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
            Err(error) => {
                return Err(error)
                    .into_diagnostic()
                    .wrap_err_with(|| format!("reading {}", dir.display()));
            }
        };
        for entry in entries {
            let entry = entry
                .into_diagnostic()
                .wrap_err_with(|| format!("reading {}", dir.display()))?;
            let name = entry.file_name().to_string_lossy().into_owned();
            let path = format!("{prefix}{name}");
            let kind = entry
                .file_type()
                .into_diagnostic()
                .wrap_err_with(|| format!("reading {}", entry.path().display()))?;
            if kind.is_dir() {
                walk(&entry.path(), &format!("{path}/"), out)?;
            } else if name.ends_with(".elm") {
                out.push(path);
            }
        }
        Ok(())
    }
    let mut out = Vec::new();
    walk(dir, "", &mut out)?;
    Ok(out)
}
