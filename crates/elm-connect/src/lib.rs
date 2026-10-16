//! The standalone CLI's logic, kept out of `main` so tests can drive it
//! in-process.

use std::collections::{BTreeSet, HashMap};
use std::fs;
use std::path::{Path, PathBuf};

use elm_connect_gen::diagnostics::Columns;
use elm_connect_gen::{Generated, GeneratedFile, Options, googleapis};
use miette::{IntoDiagnostic, Report, WrapErr};
use protox::prost_reflect::DescriptorPool;

/// What compiling the inputs gives the generator.
#[derive(Debug)]
pub struct Compiled {
    /// Every resolved file, imports included.
    pub pool: DescriptorPool,
    /// The names, as `pool` knows them, of the files named on the command
    /// line: the set to generate.
    pub inputs: Vec<String>,
    /// The text of every resolved file read from disk, by name, for
    /// diagnostics.
    pub sources: HashMap<String, String>,
}

impl Compiled {
    /// Adds to `inputs` every file they import, transitively, that declares
    /// a message, enum or service: what `--include-imports` asks for, the
    /// way `buf generate --include-imports` does. `google/protobuf` files
    /// map to the runtime and the googleapis files elm-connect embeds only
    /// carry `google.api.http`, so neither is added.
    pub fn include_imports(&mut self) {
        let mut seen: BTreeSet<String> = self.inputs.iter().cloned().collect();
        let mut pending: Vec<String> = self.inputs.clone();
        while let Some(name) = pending.pop() {
            let Some(file) = self.pool.get_file_by_name(&name) else {
                continue;
            };
            for import in file.dependencies() {
                let name = import.name();
                if name.starts_with("google/protobuf/")
                    || googleapis::is_embedded(name)
                    || !seen.insert(name.to_owned())
                {
                    continue;
                }
                pending.push(name.to_owned());
                let declares = import.messages().next().is_some()
                    || import.enums().next().is_some()
                    || import.services().next().is_some();
                if declares {
                    self.inputs.push(name.to_owned());
                }
            }
        }
        self.inputs.sort();
    }
}

/// Compiles `files` against the `includes` search path (`.` if empty),
/// then protox's bundled `google/protobuf` files and the googleapis files
/// elm-connect embeds (`google/api/annotations.proto` and
/// `google/api/http.proto`), so `google.api.http` needs no googleapis
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
    let mut compiler =
        protox::Compiler::with_file_resolver(elm_connect_gen::googleapis::resolver(includes));
    compiler.include_source_info(true).include_imports(true);
    compiler.open_files(files)?;
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
        sources,
    })
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
    // protox records columns in bytes.
    match elm_connect_gen::generate(&compiled.pool, &inputs, options) {
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
    /// generated-file notice, but generating does not give it: left over
    /// from a package or service since removed or renamed.
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

/// Compares `files`, as generating gives them, with the tree under `out`:
/// a module whose file is missing, a file whose content differs, and a
/// stale file, one under `out` whose first line is elm-connect's
/// generated-file notice that `files` does not hold. Other `.elm` files
/// under `out` are left alone, since an application may keep its own
/// modules beside the generated ones. A missing `out` is a tree with
/// nothing in it.
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
    let generated: BTreeSet<&str> = files.iter().map(|file| file.path.as_str()).collect();
    for path in elm_files_under(out)? {
        if generated.contains(path.as_str()) {
            continue;
        }
        let full = out.join(&path);
        let text = fs::read_to_string(&full)
            .into_diagnostic()
            .wrap_err_with(|| format!("reading {}", full.display()))?;
        if text.starts_with(&header_start()) {
            drift.push(Drift::Stale { path });
        }
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
                    "stale: {out}/{path} was generated by elm-connect, but generating no longer \
                     gives it\n"
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
                        .header(&format!("{out}/{path}"), &format!("generated/{path}"))
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
