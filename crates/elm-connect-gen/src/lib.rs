//! Descriptors to Elm. Today this crate turns a descriptor pool into a
//! typed intermediate representation ([`ir`]) under the Elm naming rules
//! ([`naming`]), reporting what has no Elm form ([`diagnostics`]), and holds
//! a typed Elm AST with its printer ([`elm`]); joining the two is not
//! implemented yet.

pub mod diagnostics;
pub mod elm;
pub mod ir;
pub mod naming;

/// The version of the generator, stamped into everything it emits.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");
