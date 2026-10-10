//! Descriptors to Elm. Today this crate holds the typed intermediate
//! representation ([`ir`]), the Elm naming rules ([`naming`]) and what the
//! plugin and the CLI share; emitting Elm is not implemented yet.

pub mod diagnostics;
pub mod ir;
pub mod naming;

/// The version of the generator, stamped into everything it emits.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");
