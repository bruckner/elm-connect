//! Parsing of protobuf source files.
//!
//! See the documentation for [`parse()`] for details.
#![warn(missing_debug_implementations, missing_docs)]
#![deny(unsafe_code)]

use logos::Span;
use prost_types::FileDescriptorProto;

pub use self::error::ParseError;

mod ast;
mod case;
mod error;
mod generate;
mod lex;
mod parse;
mod tag;
#[cfg(test)]
mod tests;

const MAX_MESSAGE_FIELD_NUMBER: i32 = 536_870_911;

/// `google.protobuf.Edition.EDITION_2023`.
const EDITION_2023: i32 = 1000;

/// Parses a single protobuf source file into a [`FileDescriptorProto`].
///
/// This function only looks at the syntax of the file, without resolving type names or reading
/// imported files.
///
/// A file that begins with an `edition` statement parses to a descriptor with `syntax` set to
/// `"editions"`; use [`parse_with_edition()`] to get its edition too.
///
/// # Examples
///
/// ```
/// # use protox_parse::parse;
/// # use prost_types::{DescriptorProto, FieldDescriptorProto, FileDescriptorProto, SourceCodeInfo, source_code_info::Location, field_descriptor_proto::Label};
/// #
/// let source = r#"
///     syntax = "proto3";
///     import "dep.proto";
///
///     message Foo {
///         Bar bar = 1;
///     }
/// "#;
/// let file_descriptor = parse("foo.proto", source).unwrap();
/// assert_eq!(file_descriptor, FileDescriptorProto {
///     name: Some("foo.proto".to_owned()),
///     syntax: Some("proto3".to_owned()),
///     dependency: vec!["dep.proto".to_owned()],
///     message_type: vec![DescriptorProto {
///         name: Some("Foo".to_owned()),
///         field: vec![FieldDescriptorProto {
///             label: Some(Label::Optional as _),
///             name: Some("bar".to_owned()),
///             number: Some(1),
///             type_name: Some("Bar".to_owned()),
///             ..Default::default()
///         }],
///         ..Default::default()
///     }],
///     source_code_info: Some(SourceCodeInfo {
///         location: vec![
///             Location { path: vec![], span: vec![1, 4, 6, 5], ..Default::default() },
///             Location { path: vec![3, 0], span: vec![2, 4, 23], ..Default::default() },
///             Location { path: vec![4, 0], span: vec![4, 4, 6, 5], ..Default::default() },
///             Location { path: vec![4, 0, 1], span: vec![4, 12, 15], ..Default::default() },
///             Location { path: vec![4, 0, 2, 0], span: vec![5, 8, 20], ..Default::default() },
///             Location { path: vec![4, 0, 2, 0, 1], span: vec![5, 12, 15], ..Default::default() },
///             Location { path: vec![4, 0, 2, 0, 3], span: vec![5, 18, 19], ..Default::default() },
///             Location { path: vec![4, 0, 2, 0, 6], span: vec![5, 8, 11], ..Default::default() },
///             Location { path: vec![12], span: vec![1, 4, 22], ..Default::default() },
///         ],
///     }),
///     ..Default::default()
/// })
/// ```
pub fn parse(name: &str, source: &str) -> Result<FileDescriptorProto, ParseError> {
    parse_with_edition(name, source).map(|(file, _)| file)
}

/// Parses a single protobuf source file, as [`parse()`] does, and also returns the file's edition
/// when it begins with an `edition` statement.
///
/// The edition is a value of the `google.protobuf.Edition` enum (`1000` for
/// `edition = "2023";`). It is returned separately because [`FileDescriptorProto`] has no field
/// for it: an editions file parses to a descriptor with `syntax` set to `"editions"`, and a
/// descriptor pool needs the edition beside it.
///
/// # Examples
///
/// ```
/// # use protox_parse::parse_with_edition;
/// let (file, edition) = parse_with_edition("foo.proto", "edition = \"2023\";").unwrap();
/// assert_eq!(file.syntax(), "editions");
/// assert_eq!(edition, Some(1000));
///
/// let (_, edition) = parse_with_edition("bar.proto", "syntax = \"proto3\";").unwrap();
/// assert_eq!(edition, None);
/// ```
pub fn parse_with_edition(
    name: &str,
    source: &str,
) -> Result<(FileDescriptorProto, Option<i32>), ParseError> {
    if source.len() > MAX_FILE_LEN {
        return Err(ParseError::new(
            vec![error::ParseErrorKind::FileTooLarge],
            name,
            String::default(),
        ));
    }

    let ast = parse::parse_file(source)
        .map_err(|errors| ParseError::new(errors, name, source.to_owned()))?;

    generate::generate_file(ast, name, source)
        .map_err(|errors| ParseError::new(errors, name, source.to_owned()))
}

const MAX_FILE_LEN: usize = i32::MAX as usize;

fn index_to_i32(index: usize) -> i32 {
    // We enforce that all files parsed are at most i32::MAX bytes long. Therefore the indices of any
    // definitions in a single file must fit into an i32.
    index.try_into().unwrap()
}

fn join_span(start: Span, end: Span) -> Span {
    start.start..end.end
}
