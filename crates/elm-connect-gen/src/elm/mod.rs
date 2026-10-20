//! Elm source as data: a typed syntax tree ([`ast`]), constructors that
//! keep emitter code readable ([`build`]), and a printer ([`mod@print`]) whose
//! output is canonical elm-format 0.8.8 layout, doc comments included
//! ([`markdown`]).
//!
//! The emitters build trees; only the printer produces text. Formatting
//! decisions therefore live in one place, and the conformance suite's
//! `elm-format --validate` check holds by construction rather than by
//! post-processing.

pub mod ast;
pub mod build;
pub mod markdown;
pub mod print;
