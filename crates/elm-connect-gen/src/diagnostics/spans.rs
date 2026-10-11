//! Source spans for descriptors, from a file's `SourceCodeInfo`.
//!
//! A descriptor is addressed by its *path*: the field numbers and indices
//! leading from the `FileDescriptorProto` to it, as in
//! `SourceCodeInfo.Location.path` (the second field of the first message is
//! `[4, 0, 2, 1]`). [`Spans`] maps a path to the line and column span the
//! compiler recorded; [`LineColSpan::byte_span`] turns that into a byte
//! span of the source text, which miette needs to draw a snippet.

use std::collections::HashMap;

use miette::SourceSpan;
use prost_types::FileDescriptorProto;

/// Field numbers from `google/protobuf/descriptor.proto`, for building
/// descriptor paths.
pub mod tag {
    /// `FileDescriptorProto.package`
    pub const FILE_PACKAGE: i32 = 2;
    /// `FileDescriptorProto.message_type`
    pub const FILE_MESSAGE: i32 = 4;
    /// `FileDescriptorProto.enum_type`
    pub const FILE_ENUM: i32 = 5;
    /// `FileDescriptorProto.service`
    pub const FILE_SERVICE: i32 = 6;
    /// `FileDescriptorProto.syntax`
    pub const FILE_SYNTAX: i32 = 12;
    /// `DescriptorProto.name`
    pub const MESSAGE_NAME: i32 = 1;
    /// `DescriptorProto.field`
    pub const MESSAGE_FIELD: i32 = 2;
    /// `DescriptorProto.nested_type`
    pub const MESSAGE_NESTED: i32 = 3;
    /// `DescriptorProto.enum_type`
    pub const MESSAGE_ENUM: i32 = 4;
    /// `DescriptorProto.oneof_decl`
    pub const MESSAGE_ONEOF: i32 = 8;
    /// `FieldDescriptorProto.name`
    pub const FIELD_NAME: i32 = 1;
    /// `FieldDescriptorProto.type_name`
    pub const FIELD_TYPE_NAME: i32 = 6;
    /// `OneofDescriptorProto.name`
    pub const ONEOF_NAME: i32 = 1;
    /// `EnumDescriptorProto.name`
    pub const ENUM_NAME: i32 = 1;
    /// `EnumDescriptorProto.value`
    pub const ENUM_VALUE: i32 = 2;
    /// `EnumValueDescriptorProto.name`
    pub const ENUM_VALUE_NAME: i32 = 1;
    /// `ServiceDescriptorProto.method`
    pub const SERVICE_METHOD: i32 = 2;
    /// `MethodDescriptorProto.name`
    pub const METHOD_NAME: i32 = 1;
    /// `MethodDescriptorProto.input_type`
    pub const METHOD_INPUT: i32 = 2;
    /// `MethodDescriptorProto.output_type`
    pub const METHOD_OUTPUT: i32 = 3;
    /// `MethodDescriptorProto.options`
    pub const METHOD_OPTIONS: i32 = 4;
    /// `MethodDescriptorProto.client_streaming`
    pub const METHOD_CLIENT_STREAMING: i32 = 5;
    /// `MethodDescriptorProto.server_streaming`
    pub const METHOD_SERVER_STREAMING: i32 = 6;
    /// The `google.api.http` extension of `MethodOptions`
    /// (`google/api/annotations.proto`).
    pub const METHOD_OPTIONS_HTTP: i32 = 72_295_728;
}

/// How a compiler counted the columns in its `SourceCodeInfo`. The two
/// agree on any line without tabs.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Columns {
    /// One column per byte, tabs included: protox.
    #[default]
    Bytes,
    /// One column per byte, but a tab advances to the next multiple of
    /// eight: protoc's tokenizer.
    ProtocTabs,
}

/// A zero-based line and column span, as `SourceCodeInfo` records it. The
/// end is exclusive.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct LineColSpan {
    /// The first line, from 0.
    pub start_line: u32,
    /// The first column, from 0.
    pub start_col: u32,
    /// The last line, from 0.
    pub end_line: u32,
    /// The column just past the end, from 0.
    pub end_col: u32,
}

impl LineColSpan {
    /// Reads a `SourceCodeInfo.Location.span`: three elements on one line
    /// (`[line, start_col, end_col]`) or four (`[start_line, start_col,
    /// end_line, end_col]`). Anything else, or a negative number, is not a
    /// span.
    pub fn from_location(span: &[i32]) -> Option<Self> {
        let n = |i: usize| u32::try_from(span[i]).ok();
        match span.len() {
            3 => Some(LineColSpan {
                start_line: n(0)?,
                start_col: n(1)?,
                end_line: n(0)?,
                end_col: n(2)?,
            }),
            4 => Some(LineColSpan {
                start_line: n(0)?,
                start_col: n(1)?,
                end_line: n(2)?,
                end_col: n(3)?,
            }),
            _ => None,
        }
    }

    /// The byte span of `source` this covers, or `None` when the span does
    /// not fit the source (the source is not the text the descriptor came
    /// from).
    pub fn byte_span(&self, source: &str, columns: Columns) -> Option<SourceSpan> {
        let start = byte_offset(source, self.start_line, self.start_col, columns)?;
        let end = byte_offset(source, self.end_line, self.end_col, columns)?;
        (start <= end).then(|| SourceSpan::new(start.into(), end - start))
    }
}

/// The byte offset of a zero-based line and column in `source`.
fn byte_offset(source: &str, line: u32, col: u32, columns: Columns) -> Option<usize> {
    let line_start = if line == 0 {
        0
    } else {
        source
            .match_indices('\n')
            .nth(usize::try_from(line).ok()? - 1)?
            .0
            + 1
    };
    let line_text = source[line_start..].split('\n').next().unwrap_or_default();
    let col = usize::try_from(col).ok()?;
    let within = match columns {
        Columns::Bytes => col,
        Columns::ProtocTabs => {
            let mut seen = 0;
            let mut index = 0;
            for byte in line_text.bytes() {
                if seen >= col {
                    break;
                }
                seen = if byte == b'\t' {
                    seen + 8 - seen % 8
                } else {
                    seen + 1
                };
                index += 1;
            }
            if seen < col {
                return None;
            }
            index
        }
    };
    (within <= line_text.len() && line_text.is_char_boundary(within)).then_some(line_start + within)
}

/// The recorded spans of one file, by descriptor path.
#[derive(Clone, Debug, Default)]
pub struct Spans {
    by_path: HashMap<Vec<i32>, LineColSpan>,
}

impl Spans {
    /// Indexes the `SourceCodeInfo` of `file`; empty when the compiler was
    /// not asked for source info. Where a path has several locations, the
    /// first wins.
    pub fn new(file: &FileDescriptorProto) -> Self {
        let mut by_path = HashMap::new();
        for location in file.source_code_info.iter().flat_map(|info| &info.location) {
            if let Some(span) = LineColSpan::from_location(&location.span) {
                by_path.entry(location.path.clone()).or_insert(span);
            }
        }
        Spans { by_path }
    }

    /// The span recorded for `path`, if any.
    pub fn get(&self, path: &[i32]) -> Option<LineColSpan> {
        self.by_path.get(path).copied()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn span(start_line: u32, start_col: u32, end_line: u32, end_col: u32) -> LineColSpan {
        LineColSpan {
            start_line,
            start_col,
            end_line,
            end_col,
        }
    }

    #[test]
    fn reads_three_and_four_element_spans() {
        assert_eq!(
            LineColSpan::from_location(&[2, 4, 9]),
            Some(span(2, 4, 2, 9))
        );
        assert_eq!(
            LineColSpan::from_location(&[2, 4, 3, 1]),
            Some(span(2, 4, 3, 1))
        );
        assert_eq!(LineColSpan::from_location(&[2, 4]), None);
        assert_eq!(LineColSpan::from_location(&[-1, 0, 1]), None);
    }

    #[test]
    fn byte_spans_count_bytes() {
        let source = "a\nbc def\n";
        let s = span(1, 3, 1, 6).byte_span(source, Columns::Bytes).unwrap();
        assert_eq!(&source[s.offset()..s.offset() + s.len()], "def");
    }

    #[test]
    fn protoc_columns_expand_tabs() {
        let source = "x\n\tint32 id = 1;\n";
        let protoc = span(1, 14, 1, 16)
            .byte_span(source, Columns::ProtocTabs)
            .unwrap();
        assert_eq!(
            &source[protoc.offset()..protoc.offset() + protoc.len()],
            "id"
        );
        let protox = span(1, 7, 1, 9).byte_span(source, Columns::Bytes).unwrap();
        assert_eq!(protox, protoc);
    }

    #[test]
    fn spans_past_the_source_are_none() {
        assert_eq!(span(5, 0, 5, 1).byte_span("a\n", Columns::Bytes), None);
        assert_eq!(span(0, 0, 0, 9).byte_span("abc", Columns::Bytes), None);
    }
}
