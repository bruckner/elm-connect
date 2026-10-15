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
