//! Descriptors to Elm: a descriptor pool becomes a typed intermediate
//! representation ([`ir`]) under the Elm naming rules ([`naming`]), the
//! emitter ([`emit`]) turns each package of it into an Elm syntax tree
//! ([`elm`]), and the printer turns that into source. What has no Elm form
//! is reported instead ([`diagnostics`]). [`generate`] runs the whole way.

pub mod diagnostics;
pub mod elm;
pub mod emit;
pub mod googleapis;
pub mod ir;
pub mod naming;
pub mod options;
pub mod route;

use prost_reflect::DescriptorPool;

use crate::diagnostics::Diagnostics;
pub use crate::options::{EnumUnknown, Int64, Options, Streaming, UnboundMethods, parse_rename};

/// The version of the generator, stamped into everything it emits.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// One generated Elm source file.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct GeneratedFile {
    /// The path relative to the output directory, from the module name:
    /// `Notes/V1.elm` for `Notes.V1`. Always `/`-separated.
    pub path: String,
    /// The Elm source, in elm-format's layout.
    pub content: String,
}

/// What a successful run gives: the files, and what the run warned about.
#[derive(Clone, Debug)]
pub struct Generated {
    /// One file per module, sorted by path.
    pub files: Vec<GeneratedFile>,
    /// The warnings, in the order found: what the options left out, such
    /// as the streaming methods `streaming=skip` skips. Empty under the
    /// default options. Rendering them is the caller's business; both
    /// binaries print them to stderr.
    pub warnings: Diagnostics,
}

/// Generates one Elm module per proto package declared by the files in
/// `generate` (names as `pool` knows them) or referred to from them,
/// transitively, each in full from every file of `pool` that declares it
/// (the closure, design §3.1; `google.protobuf` excepted), and one per
/// service of each that has a method, sorted by path. A package of services alone still
/// gets a package module, holding its registry. A service without methods,
/// declared so or left so by `streaming=skip`, gets no module: Elm rejects
/// a module that declares nothing.
///
/// On any error, returns every error found instead: those of building
/// the IR, or else the methods `options` reject, or else those of emitting
/// every package. Warnings come back only with the files.
pub fn generate(
    pool: &DescriptorPool,
    generate: &[&str],
    options: &Options,
) -> Result<Generated, Diagnostics> {
    let ir::Built { packages, warnings } = ir::build_with(pool, generate, options)?;
    if options.unbound_methods == UnboundMethods::Error {
        let unbound = ir::unbound_methods(pool, &packages);
        if !unbound.is_empty() {
            return Err(unbound);
        }
    }
    let mut files = Vec::new();
    let mut diagnostics = Diagnostics::new();
    for package in &packages {
        match emit::emit(package, options) {
            Ok(module) => {
                files.push(file(&module));
                for service in package.services.iter().filter(|s| !s.methods.is_empty()) {
                    files.push(file(&emit::emit_service(package, service, options)));
                }
            }
            Err(problems) => {
                for problem in &problems {
                    diagnostics.push(problem.clone());
                }
            }
        }
    }
    if !diagnostics.is_empty() {
        return Err(diagnostics);
    }
    files.sort_by(|a, b| a.path.cmp(&b.path));
    Ok(Generated { files, warnings })
}

/// The file of `module`: `Notes/V1/NotesService.elm` for
/// `Notes.V1.NotesService`.
fn file(module: &elm::ast::Module) -> GeneratedFile {
    GeneratedFile {
        path: format!("{}.elm", module.name.as_str().replace('.', "/")),
        content: elm::print::print_module(module),
    }
}
