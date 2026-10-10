//! Descriptors to Elm. Generation is not implemented yet; today this crate
//! holds only what the plugin and the CLI already share.

pub mod diagnostics;
pub mod elm;

/// The version of the generator, stamped into everything it emits.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");
