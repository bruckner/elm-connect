use std::fmt;

use prost::Message;

/// A protobuf edition: the language revision a file is written in.
///
/// Files with `syntax = "proto2"` and `syntax = "proto3"` have the editions
/// [`Proto2`](Edition::Proto2) and [`Proto3`](Edition::Proto3); files that begin with
/// `edition = "2023";` have [`Edition2023`](Edition::Edition2023).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
#[non_exhaustive]
pub enum Edition {
    /// A file with `syntax = "proto2"`, or with no syntax statement.
    Proto2,
    /// A file with `syntax = "proto3"`.
    Proto3,
    /// A file with `edition = "2023"`.
    Edition2023,
}

/// The resolved [features](https://protobuf.dev/editions/features/) of a descriptor.
///
/// Features are resolved as protoc resolves them: the defaults of the file's edition, overridden
/// by the `features` options set on the file and then on each enclosing element down to this
/// one. For proto2 and proto3 files, which cannot set features, they are the features the file's
/// syntax implies (for example, a proto2 `required` field has
/// [`FieldPresence::LegacyRequired`]).
///
/// Features that extend `google.protobuf.FeatureSet` (such as the language-specific `pb.cpp`)
/// are not resolved; they remain in the descriptor's options.
#[derive(Clone, Copy, PartialEq, Eq, Hash)]
pub struct Features {
    pub(crate) field_presence: FieldPresence,
    pub(crate) enum_type: EnumType,
    pub(crate) repeated_field_encoding: RepeatedFieldEncoding,
    pub(crate) utf8_validation: Utf8Validation,
    pub(crate) message_encoding: MessageEncoding,
    pub(crate) json_format: JsonFormat,
}

/// The `field_presence` feature: whether a singular field tracks presence.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum FieldPresence {
    /// The field tracks whether it is set (proto2 `optional`, editions' default).
    Explicit,
    /// The field is unset when it holds its default value (proto3 without `optional`).
    Implicit,
    /// The field must be set (proto2 `required`).
    LegacyRequired,
}

/// The `enum_type` feature: whether an enum accepts unknown values.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum EnumType {
    /// Unknown values are stored in the field (proto3, editions' default).
    Open,
    /// Unknown values are treated as unknown fields (proto2).
    Closed,
}

/// The `repeated_field_encoding` feature: how repeated scalar fields are written.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum RepeatedFieldEncoding {
    /// All elements in one length-delimited record (proto3, editions' default).
    Packed,
    /// One record per element (proto2).
    Expanded,
}

/// The `utf8_validation` feature: whether string fields are checked for valid UTF-8.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Utf8Validation {
    /// Invalid UTF-8 is a parse error (proto3, editions' default).
    Verify,
    /// No check is required.
    None,
}

/// The `message_encoding` feature: how message fields are written.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum MessageEncoding {
    /// A length-delimited record (the default).
    LengthPrefixed,
    /// Start and end group tags, as proto2 groups are written.
    Delimited,
}

/// The `json_format` feature: whether a message or enum must have a valid JSON mapping.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum JsonFormat {
    /// The JSON mapping is checked (for example, no two fields share a JSON name).
    Allow,
    /// The JSON mapping is not checked (proto2).
    LegacyBestEffort,
}

impl Edition {
    pub(crate) const PROTO2_NUMBER: i32 = 998;
    pub(crate) const PROTO3_NUMBER: i32 = 999;
    pub(crate) const EDITION_2023_NUMBER: i32 = 1000;

    /// The edition's number in the `google.protobuf.Edition` enum.
    pub fn number(self) -> i32 {
        match self {
            Edition::Proto2 => Edition::PROTO2_NUMBER,
            Edition::Proto3 => Edition::PROTO3_NUMBER,
            Edition::Edition2023 => Edition::EDITION_2023_NUMBER,
        }
    }

    pub(crate) fn is_legacy(self) -> bool {
        matches!(self, Edition::Proto2 | Edition::Proto3)
    }

    /// The name protoc uses in messages, e.g. `2023` for `EDITION_2023`.
    pub(crate) fn fmt_number(number: i32) -> String {
        match number {
            Edition::PROTO2_NUMBER => "proto2".to_owned(),
            Edition::PROTO3_NUMBER => "proto3".to_owned(),
            Edition::EDITION_2023_NUMBER => "2023".to_owned(),
            1001 => "2024".to_owned(),
            n => n.to_string(),
        }
    }
}

impl fmt::Display for Edition {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&Edition::fmt_number(self.number()))
    }
}

impl Features {
    /// The defaults for `edition`, from `google.protobuf.FeatureSet`'s `edition_defaults`.
    pub(crate) const fn defaults(edition: Edition) -> Features {
        match edition {
            Edition::Proto2 => Features {
                field_presence: FieldPresence::Explicit,
                enum_type: EnumType::Closed,
                repeated_field_encoding: RepeatedFieldEncoding::Expanded,
                utf8_validation: Utf8Validation::None,
                message_encoding: MessageEncoding::LengthPrefixed,
                json_format: JsonFormat::LegacyBestEffort,
            },
            Edition::Proto3 => Features {
                field_presence: FieldPresence::Implicit,
                enum_type: EnumType::Open,
                repeated_field_encoding: RepeatedFieldEncoding::Packed,
                utf8_validation: Utf8Validation::Verify,
                message_encoding: MessageEncoding::LengthPrefixed,
                json_format: JsonFormat::Allow,
            },
            Edition::Edition2023 => Features {
                field_presence: FieldPresence::Explicit,
                enum_type: EnumType::Open,
                repeated_field_encoding: RepeatedFieldEncoding::Packed,
                utf8_validation: Utf8Validation::Verify,
                message_encoding: MessageEncoding::LengthPrefixed,
                json_format: JsonFormat::Allow,
            },
        }
    }

    /// The `field_presence` feature.
    pub fn field_presence(&self) -> FieldPresence {
        self.field_presence
    }

    /// The `enum_type` feature.
    pub fn enum_type(&self) -> EnumType {
        self.enum_type
    }

    /// The `repeated_field_encoding` feature.
    pub fn repeated_field_encoding(&self) -> RepeatedFieldEncoding {
        self.repeated_field_encoding
    }

    /// The `utf8_validation` feature.
    pub fn utf8_validation(&self) -> Utf8Validation {
        self.utf8_validation
    }

    /// The `message_encoding` feature.
    pub fn message_encoding(&self) -> MessageEncoding {
        self.message_encoding
    }

    /// The `json_format` feature.
    pub fn json_format(&self) -> JsonFormat {
        self.json_format
    }

    /// Overrides these features with those set in `set`.
    ///
    /// Returns the name and number of the first feature set to a value that is not one of its
    /// enum's known values (including the `*_UNKNOWN` zero value).
    pub(crate) fn merge(mut self, set: &FeatureSetProto) -> Result<Features, (&'static str, i32)> {
        if let Some(value) = set.field_presence {
            self.field_presence = match value {
                1 => FieldPresence::Explicit,
                2 => FieldPresence::Implicit,
                3 => FieldPresence::LegacyRequired,
                _ => return Err(("field_presence", value)),
            };
        }
        if let Some(value) = set.enum_type {
            self.enum_type = match value {
                1 => EnumType::Open,
                2 => EnumType::Closed,
                _ => return Err(("enum_type", value)),
            };
        }
        if let Some(value) = set.repeated_field_encoding {
            self.repeated_field_encoding = match value {
                1 => RepeatedFieldEncoding::Packed,
                2 => RepeatedFieldEncoding::Expanded,
                _ => return Err(("repeated_field_encoding", value)),
            };
        }
        if let Some(value) = set.utf8_validation {
            self.utf8_validation = match value {
                2 => Utf8Validation::Verify,
                3 => Utf8Validation::None,
                _ => return Err(("utf8_validation", value)),
            };
        }
        if let Some(value) = set.message_encoding {
            self.message_encoding = match value {
                1 => MessageEncoding::LengthPrefixed,
                2 => MessageEncoding::Delimited,
                _ => return Err(("message_encoding", value)),
            };
        }
        if let Some(value) = set.json_format {
            self.json_format = match value {
                1 => JsonFormat::Allow,
                2 => JsonFormat::LegacyBestEffort,
                _ => return Err(("json_format", value)),
            };
        }
        Ok(self)
    }
}

impl fmt::Debug for Features {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Features")
            .field("field_presence", &self.field_presence)
            .field("enum_type", &self.enum_type)
            .field("repeated_field_encoding", &self.repeated_field_encoding)
            .field("utf8_validation", &self.utf8_validation)
            .field("message_encoding", &self.message_encoding)
            .field("json_format", &self.json_format)
            .finish()
    }
}

/// The fields of `google.protobuf.FeatureSet` this crate resolves, plus the two that edition
/// 2024 introduced, so that a 2023 file setting them can be refused.
#[derive(Clone, PartialEq, Message)]
pub(crate) struct FeatureSetProto {
    #[prost(int32, optional, tag = "1")]
    pub field_presence: Option<i32>,
    #[prost(int32, optional, tag = "2")]
    pub enum_type: Option<i32>,
    #[prost(int32, optional, tag = "3")]
    pub repeated_field_encoding: Option<i32>,
    #[prost(int32, optional, tag = "4")]
    pub utf8_validation: Option<i32>,
    #[prost(int32, optional, tag = "5")]
    pub message_encoding: Option<i32>,
    #[prost(int32, optional, tag = "6")]
    pub json_format: Option<i32>,
    #[prost(int32, optional, tag = "7")]
    pub enforce_naming_style: Option<i32>,
    #[prost(int32, optional, tag = "8")]
    pub default_symbol_visibility: Option<i32>,
}

impl FeatureSetProto {
    /// Reads the `features` field, numbered `tag`, out of an encoded options message.
    pub(crate) fn from_options(encoded: &[u8], tag: u32) -> Option<FeatureSetProto> {
        let mut buf = encoded;
        let mut result: Option<FeatureSetProto> = None;
        while !buf.is_empty() {
            let (field_tag, wire_type) = prost::encoding::decode_key(&mut buf).ok()?;
            if field_tag == tag && wire_type == prost::encoding::WireType::LengthDelimited {
                let len = prost::encoding::decode_varint(&mut buf).ok()? as usize;
                if len > buf.len() {
                    return None;
                }
                let decoded = FeatureSetProto::decode(&buf[..len]).ok()?;
                match &mut result {
                    Some(existing) => existing.merge_from(decoded),
                    None => result = Some(decoded),
                }
                buf = &buf[len..];
            } else {
                prost::encoding::skip_field(
                    wire_type,
                    field_tag,
                    &mut buf,
                    prost::encoding::DecodeContext::default(),
                )
                .ok()?;
            }
        }
        result
    }

    fn merge_from(&mut self, other: FeatureSetProto) {
        macro_rules! merge {
            ($($field:ident),*) => {
                $(if other.$field.is_some() {
                    self.$field = other.$field;
                })*
            };
        }
        merge!(
            field_presence,
            enum_type,
            repeated_field_encoding,
            utf8_validation,
            message_encoding,
            json_format,
            enforce_naming_style,
            default_symbol_visibility
        );
    }
}
