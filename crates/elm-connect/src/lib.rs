//! The standalone CLI's logic, kept out of `main` so tests can drive it
//! in-process.

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

use elm_connect_gen::diagnostics::Columns;
use elm_connect_gen::{GeneratedFile, Options};
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

/// Compiles `files` against the `includes` search path (`.` if empty).
///
/// A compile error comes back as a `Report` carrying the proto source and the
/// span at fault, so it renders with the offending line underlined.
pub fn compile(files: &[PathBuf], includes: &[PathBuf]) -> Result<Compiled, Report> {
    let includes: Vec<&Path> = if includes.is_empty() {
        vec![Path::new(".")]
    } else {
        includes.iter().map(PathBuf::as_path).collect()
    };
    let mut compiler = protox::Compiler::new(includes)?;
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

/// Compiles `files` against `includes` and generates Elm from them.
///
/// Problems in the protos come back as one `Report` whose snippets point
/// into the proto sources.
pub fn generate(files: &[PathBuf], includes: &[PathBuf]) -> Result<Vec<GeneratedFile>, Report> {
    let compiled = compile(files, includes)?;
    let inputs: Vec<&str> = compiled.inputs.iter().map(String::as_str).collect();
    elm_connect_gen::generate(&compiled.pool, &inputs, &Options::default()).map_err(
        |mut diagnostics| {
            // protox records columns in bytes.
            diagnostics.attach_sources(&compiled.sources, Columns::Bytes);
            Report::new(diagnostics)
        },
    )
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
