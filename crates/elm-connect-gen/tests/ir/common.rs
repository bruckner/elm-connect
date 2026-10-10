//! Compiling proto sources held in memory, for tests.

use std::collections::HashMap;

use elm_connect_gen::diagnostics::{Columns, Diagnostics};
use elm_connect_gen::ir::{self, Package};
use protox::Compiler;
use protox::file::{ChainFileResolver, File, FileResolver, GoogleFileResolver};
use protox::prost_reflect::DescriptorPool;

/// Proto files by name, resolved before the bundled `google/protobuf` ones.
struct Memory(HashMap<String, String>);

impl FileResolver for Memory {
    fn open_file(&self, name: &str) -> Result<File, protox::Error> {
        match self.0.get(name) {
            Some(source) => File::from_source(name, source),
            None => Err(protox::Error::file_not_found(name)),
        }
    }
}

/// The sources of `files` by name.
pub fn sources(files: &[(&str, &str)]) -> HashMap<String, String> {
    files
        .iter()
        .map(|&(name, source)| (name.to_owned(), source.to_owned()))
        .collect()
}

/// Compiles every file of `files`, with source info.
pub fn pool(files: &[(&str, &str)]) -> DescriptorPool {
    let mut resolver = ChainFileResolver::new();
    resolver.add(Memory(sources(files)));
    resolver.add(GoogleFileResolver::new());
    let mut compiler = Compiler::with_file_resolver(resolver);
    compiler.include_source_info(true).include_imports(true);
    for (name, _) in files {
        compiler
            .open_file(name)
            .unwrap_or_else(|err| panic!("{name} does not compile: {err:?}"));
    }
    compiler.descriptor_pool()
}

/// Builds the IR of `generate` among `files`.
pub fn build(files: &[(&str, &str)], generate: &[&str]) -> Result<Vec<Package>, Diagnostics> {
    ir::build(&pool(files), generate)
}

/// Builds the IR of a single file, which must succeed.
pub fn package(source: &str) -> Package {
    let mut packages = build(&[("test.proto", source)], &["test.proto"])
        .unwrap_or_else(|diagnostics| panic!("{}", render(&diagnostics, &[])));
    assert_eq!(packages.len(), 1);
    packages.remove(0)
}

/// Builds the IR of `generate` among `files`, which must fail, and returns
/// the diagnostics with the sources attached.
pub fn problems(files: &[(&str, &str)], generate: &[&str]) -> Diagnostics {
    let mut diagnostics = match build(files, generate) {
        Ok(packages) => panic!("expected problems, built {packages:#?}"),
        Err(diagnostics) => diagnostics,
    };
    diagnostics.attach_sources(&sources(files), Columns::Bytes);
    diagnostics
}

/// The narrow render of `diagnostics`, sources attached from `files`.
pub fn render(diagnostics: &Diagnostics, files: &[(&str, &str)]) -> String {
    let mut diagnostics = diagnostics.clone();
    diagnostics.attach_sources(&sources(files), Columns::Bytes);
    elm_connect_gen::diagnostics::render_narrow(&diagnostics)
}
