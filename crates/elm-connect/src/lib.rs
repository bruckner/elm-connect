//! The standalone CLI's logic, kept out of `main` so tests can drive it
//! in-process.

use std::path::{Path, PathBuf};

use miette::Report;

/// Compiles `files` against the `includes` search path and returns the name
/// of every resolved file, imports included, dependencies first.
///
/// A compile error comes back as a `Report` carrying the proto source and the
/// span at fault, so it renders with the offending line underlined.
pub fn compile(files: &[PathBuf], includes: &[PathBuf]) -> Result<Vec<String>, Report> {
    let includes: Vec<&Path> = if includes.is_empty() {
        vec![Path::new(".")]
    } else {
        includes.iter().map(PathBuf::as_path).collect()
    };
    let mut compiler = protox::Compiler::new(includes)?;
    compiler.include_source_info(true).include_imports(true);
    compiler.open_files(files)?;
    Ok(compiler
        .file_descriptor_set()
        .file
        .into_iter()
        .map(|file| file.name().to_owned())
        .collect())
}
