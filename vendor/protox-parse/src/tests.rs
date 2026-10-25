use insta::assert_debug_snapshot;
use prost_types::FileDescriptorProto;

use crate::error::ParseErrorKind::{self, *};

fn parse(source: &str) -> Result<FileDescriptorProto, Vec<ParseErrorKind>> {
    crate::parse("test.proto", source).map_err(|err| err.into_inner())
}

#[test]
fn error_fmt_debug() {
    let error = crate::parse("foo.proto", "message {}").unwrap_err();

    assert_eq!(error.file(), "foo.proto");
    assert_eq!(error.span(), Some(8..9));

    assert_eq!(
        format!("{:?}", error),
        "foo.proto:1:9: expected an identifier, but found '{'"
    );
}

#[test]
fn parse_field_default() {
    assert_debug_snapshot!(parse(
        "
        message Foo {
            optional int32 enum = 1 [default = 2.4];
        }
    "
    ));
    assert_debug_snapshot!(parse(
        "
        message Foo {
            optional Enum enum = 1 [default = ONE];
        }

        enum Enum {}
    "
    ));
}

#[test]
fn negative_ident_outside_default() {
    assert_debug_snapshot!(parse(
        "
        option opt = -foo;
    "
    ));
}

#[test]
fn map_field_invalid_type() {
    assert_eq!(
        parse(
            r#"message Message {
            map<Message, sfixed32> field = 1;
        }"#
        ),
        Err(vec![InvalidMapFieldKeyType { span: 34..41 }]),
    );
    assert_eq!(
        parse(
            r#"message Message {
            map<.Message, fixed32> field = 1;
        }"#
        ),
        Err(vec![InvalidMapFieldKeyType { span: 34..42 }]),
    );
    assert_eq!(
        parse(
            r#"message Message {
            map<.Message, bool> field = 1;
        }"#
        ),
        Err(vec![InvalidMapFieldKeyType { span: 34..42 }]),
    );
    assert_eq!(
        parse(
            r#"message Message {
            map<float, string> field = 1;
        }"#
        ),
        Err(vec![InvalidMapFieldKeyType { span: 34..39 }]),
    );
    assert_eq!(
        parse(
            r#"message Message {
            map<double, int64> field = 1;
        }"#
        ),
        Err(vec![InvalidMapFieldKeyType { span: 34..40 }]),
    );
    assert_eq!(
        parse(
            r#"message Message {
            map<Enum, int64> field = 1;

            enum Enum {
                ZERO = 0;
            }
        }"#
        ),
        Err(vec![InvalidMapFieldKeyType { span: 34..38 }]),
    );
    assert_debug_snapshot!(parse(
        r#"message Message {
        map<int64, float> int64 = 1;
        map<uint32, double> uint32 = 2;
        map<uint64, .Message> uint64 = 3;
        map<sint32, Message> sint32 = 4;
        map<sint64, bytes> sint64 = 5;
        map<fixed32, int64> fixed32 = 6;
        map<fixed64, uint32> fixed64 = 7;
        map<sfixed32, sint32> sfixed32 = 8;
        map<sfixed64, sint64> sfixed64 = 9;
        map<bool, fixed32> bool = 10;
        map<string, fixed64> string = 11;
    }"#
    ));
}

#[test]
fn invalid_message_number() {
    assert_eq!(
        parse("message Foo { optional int32 i = -5; }"),
        Err(vec![InvalidMessageNumber { span: 33..35 }])
    );
    assert_eq!(
        parse("message Foo { optional int32 i = 0; }"),
        Err(vec![InvalidMessageNumber { span: 33..34 }])
    );
    assert_eq!(
        parse("message Foo { optional int32 i = 536870912; }"),
        Err(vec![InvalidMessageNumber { span: 33..42 }])
    );
    assert_debug_snapshot!(parse("message Foo { optional int32 i = 1; }"));
    assert_debug_snapshot!(parse("message Foo { optional int32 i = 536870911; }"));
    assert_debug_snapshot!(parse("message Foo { optional int32 i = 18999; }"));
    assert_debug_snapshot!(parse("message Foo { optional int32 i = 20000; }"));
}

#[test]
fn proto3_default_value() {
    assert_eq!(
        parse(
            r#"
            syntax = 'proto3';

            message Message {
                optional int32 foo = 1 [default = -0];
            }"#
        ),
        Err(vec![Proto3DefaultValue { span: 103..115 }]),
    );
}

#[test]
fn map_field_with_label() {
    assert_eq!(
        parse(
            r#"message Message {
            optional map<int32, string> field = 1;
        }"#
        ),
        Err(vec![MapFieldWithLabel { span: 30..38 }]),
    );
    assert_eq!(
        parse(
            r#"
            syntax = 'proto3';

            message Message {
                required map<int32, string> field = 1;
            }"#
        ),
        Err(vec![MapFieldWithLabel { span: 79..87 }]),
    );
}

#[test]
fn message_reserved_range_extrema() {
    assert_eq!(
        parse(
            r#"message Message {
                reserved 0 to 1;
            }"#
        ),
        Err(vec![InvalidMessageNumber { span: 43..44 }]),
    );
    assert_eq!(
        parse(
            r#"message Message {
                reserved 1 to 536870912;
            }"#
        ),
        Err(vec![InvalidMessageNumber { span: 48..57 }]),
    );
    assert_debug_snapshot!(parse(
        r#"message Message {
            reserved 1 to 536870911;
        }"#
    ));
}

#[test]
fn extend_required_field() {
    assert_eq!(
        parse(
            r#"
            message Message {
                extensions 1;
            }

            extend Message {
                required int32 foo = 1;
            }
            "#
        ),
        Err(vec![RequiredExtendField { span: 121..129 }]),
    );
}

#[test]
fn extend_map_field() {
    assert_eq!(
        parse(
            r#"
            message Message {
                extensions 1;
            }

            extend Message {
                map<int32, string> foo = 1;
            }
            "#
        ),
        Err(vec![InvalidExtendFieldKind {
            kind: "map",
            span: 121..148,
        }]),
    );
}

#[test]
fn proto3_group_field() {
    assert_eq!(
        parse(
            r#"
            syntax = 'proto3';

            message Message {
                optional group Foo = 1 {};
            }
            "#
        ),
        Err(vec![Proto3GroupField { span: 79..104 }]),
    );
}

#[test]
fn proto3_required_field() {
    assert_eq!(
        parse(
            r#"
            syntax = 'proto3';

            message Message {
                required int32 foo = 1;
            }
            "#
        ),
        Err(vec![Proto3RequiredField { span: 79..87 }]),
    );
}

#[test]
fn proto2_field_missing_label() {
    assert_eq!(
        parse(
            r#"
            syntax = 'proto2';

            message Message {
                int32 foo = 1;
            }
            "#
        ),
        Err(vec![Proto2FieldMissingLabel { span: 79..93 }]),
    );
}

#[test]
fn oneof_field_with_label() {
    assert_eq!(
        parse(
            r#"
            syntax = 'proto3';

            message Message {
                oneof foo {
                    optional int32 bar = 1;
                }
            }
            "#
        ),
        Err(vec![OneofFieldWithLabel { span: 111..119 }]),
    );
}

#[test]
fn oneof_map_field() {
    assert_eq!(
        parse(
            r#"
            syntax = 'proto3';

            message Message {
                oneof foo {
                    map<int32, bytes> bar = 1;
                }
            }
            "#
        ),
        Err(vec![InvalidOneofFieldKind {
            kind: "map",
            span: 111..137,
        }]),
    );
}

#[test]
fn empty_oneof() {
    assert_eq!(
        parse(
            r#"
            syntax = 'proto3';

            message Message {
                oneof foo {}
            }
            "#
        ),
        Err(vec![EmptyOneof { span: 79..91 }]),
    );
}

#[test]
fn enum_value_extrema() {
    assert_eq!(
        parse(
            r#"
            syntax = "proto3";

            enum Extreme {
                ZERO = 0;
                MIN = -2147483649;
                MAX = 2147483648;
            }
            "#
        ),
        Err(vec![
            InvalidEnumNumber { span: 108..119 },
            InvalidEnumNumber { span: 143..153 }
        ]),
    );
    assert_debug_snapshot!(parse(
        r#"
        syntax = "proto3";

        enum Extreme {
            ZERO = 0;
            MIN = -2147483648;
            MAX = 2147483647;
        }
        "#
    ));
}

#[test]
fn enum_reserved_range_extrema() {
    assert_eq!(
        parse(
            r#"
            syntax = "proto3";

            enum Extreme {
                ZERO = 0;

                reserved -2147483649 to -1, 1 to 2147483648;
            }
            "#
        ),
        Err(vec![
            InvalidEnumNumber { span: 112..123 },
            InvalidEnumNumber { span: 136..146 }
        ]),
    );
    assert_debug_snapshot!(parse(
        r#"
        syntax = "proto3";

        enum Extreme {
            ZERO = 0;
            reserved -2147483648 to -1, 1 to 2147483647;
        }
        "#
    ));
}

#[test]
fn message_field_json_name() {
    assert_eq!(
        parse(
            r#"message Message {
            optional int32 field = 1 [json_name = "\xFF"];
        }"#
        ),
        Err(vec![InvalidUtf8String { span: 68..74 }]),
    );
    assert_debug_snapshot!(parse(
        r#"message Message {
        optional int32 field = 1 [json_name = '$FIELD'];
    }"#
    ));
}

#[test]
fn field_default_value() {
    assert_debug_snapshot!(parse(
        r#"
        message Message {
            optional Message foo = 1 [default = ""];
        }"#
    ));
    assert_eq!(
        parse(
            r#"
            message Message {
                map<uint32, sfixed64> foo = 1 [default = ""];
            }"#
        ),
        Err(vec![InvalidDefault {
            kind: "map",
            span: 78..90,
        }]),
    );
    assert_eq!(
        parse(
            r#"
            message Message {
                optional group Foo = 1 [default = ""] {};
            }"#
        ),
        Err(vec![InvalidDefault {
            kind: "group",
            span: 71..83,
        }]),
    );
    assert_eq!(
        parse(
            r#"
            message Message {
                repeated int32 foo = 1 [default = 1];
            }"#
        ),
        Err(vec![InvalidDefault {
            kind: "repeated",
            span: 71..82,
        }]),
    );
    assert_debug_snapshot!(parse(
        r#"
            message Message {
                optional float default_float_exp = 23 [ default = 9e6];
                optional double default_double_exp = 24 [ default = 9e22];
            }
        "#
    ));
}

#[test]
fn field_default_invalid_type() {
    assert_eq!(
        parse(
            r#"
            message Message {
                optional int32 foo = 1 [default = "foo"];
            }"#
        ),
        Err(vec![ValueInvalidType {
            expected: "an integer".to_owned(),
            actual: "foo".to_owned(),
            span: 81..86,
        }]),
    );
    assert_eq!(
        parse(
            r#"
            message Message {
                optional uint32 foo = 1 [default = -100];
            }"#
        ),
        Err(vec![IntegerValueOutOfRange {
            expected: "an unsigned 32-bit integer".to_owned(),
            actual: "-100".to_owned(),
            min: "0".to_owned(),
            max: "4294967295".to_owned(),
            span: 82..86,
        }]),
    );
    assert_eq!(
        parse(
            r#"
            message Message {
                optional int32 foo = 1 [default = 2147483648];
            }"#
        ),
        Err(vec![IntegerValueOutOfRange {
            expected: "a signed 32-bit integer".to_owned(),
            actual: "2147483648".to_owned(),
            min: "-2147483648".to_owned(),
            max: "2147483647".to_owned(),
            span: 81..91,
        }]),
    );
    assert_debug_snapshot!(parse(
        r#"
        message Message {
            optional Foo foo = 1 [default = 1];
        }

        enum Foo {
            ZERO = 0;
        }"#
    ));
    assert_debug_snapshot!(parse(
        r#"
        message Message {
            optional Foo foo = 1 [default = "ZERO"];
        }

        enum Foo {
            ZERO = 0;
        }"#
    ));
    assert_eq!(
        parse(
            r#"
            message Message {
                optional bool foo = 1 [default = FALSE];
            }"#
        ),
        Err(vec![ValueInvalidType {
            expected: "either 'true' or 'false'".to_owned(),
            actual: "FALSE".to_owned(),
            span: 80..85,
        }]),
    );
    assert_debug_snapshot!(parse(
        r#"
        message Message {
            optional Foo foo = 1 [default = FALSE];
        }

        enum Foo {
            ZERO = 0;
        }"#
    ));
    assert_eq!(
        parse(
            r#"
            message Message {
                optional bool foo = 1 [default = -false];
            }

            enum Foo {
                ZERO = 0;
            }"#
        ),
        Err(vec![ValueInvalidType {
            expected: "either 'true' or 'false'".to_owned(),
            actual: "-false".to_owned(),
            span: 80..86,
        }]),
    );
    assert_eq!(
        parse(
            r"
            message Message {
                optional string foo = 1 [default = '\xFF'];
            }"
        ),
        Err(vec![InvalidUtf8String { span: 82..88 }]),
    );
    assert_eq!(
        parse(
            r#"
            message Message {
                optional fixed64 foo = 1 [default = -5];
            }"#
        ),
        Err(vec![IntegerValueOutOfRange {
            expected: "an unsigned 64-bit integer".to_owned(),
            actual: "-5".to_owned(),
            span: 83..85,
            min: "0".to_owned(),
            max: "18446744073709551615".to_owned()
        }]),
    );
    assert_eq!(
        parse(
            r#"
            message Message {
                optional int32 foo = 1 [default = 5.0];
            }"#
        ),
        Err(vec![ValueInvalidType {
            expected: "an integer".to_owned(),
            actual: "5.0".to_owned(),
            span: 81..84,
        }]),
    );
    assert_debug_snapshot!(parse(
        r#"
        message Message {
            optional double foo = 1 [default = nan];
            optional float foo = 1 [default = -inf];
        }"#
    ));
    assert_eq!(
        parse(
            r#"
            message Message {
                optional double foo = 1 [default = ident];
            }"#
        ),
        Err(vec![ValueInvalidType {
            expected: "a floating-point number".to_owned(),
            actual: "ident".to_owned(),
            span: 82..87,
        }]),
    );
    assert_eq!(
        parse(
            r#"
            message Message {
                optional double foo = 1 [default = {a:0}];
            }"#
        ),
        Err(vec![ValueInvalidType {
            expected: "a floating-point number".to_owned(),
            actual: "a : 0".to_owned(),
            span: 82..87,
        }]),
    );
    assert_eq!(
        parse(
            r#"
            message Message {
                optional double foo = 1 [default = "abc"];
            }"#
        ),
        Err(vec![ValueInvalidType {
            expected: "a floating-point number".to_owned(),
            actual: "abc".to_owned(),
            span: 82..87,
        }]),
    );
    assert_eq!(
        parse(
            r#"
            message Message {
                optional sint64 foo = 1 [default = 13835058055282163711];
            }"#
        ),
        Err(vec![IntegerValueOutOfRange {
            expected: "a signed 64-bit integer".to_owned(),
            actual: "13835058055282163711".to_owned(),
            span: 82..102,
            min: "-9223372036854775808".to_owned(),
            max: "9223372036854775807".to_owned()
        }]),
    );
    assert_eq!(
        parse(
            r#"
            message Message {
                optional string foo = 1 [default = 123];
            }"#
        ),
        Err(vec![ValueInvalidType {
            expected: "a string".to_owned(),
            actual: "123".to_owned(),
            span: 82..85,
        }]),
    );
    assert_eq!(
        parse(
            r#"
            message Message {
                optional bytes foo = 1 [default = 123];
            }"#
        ),
        Err(vec![ValueInvalidType {
            expected: "a string".to_owned(),
            actual: "123".to_owned(),
            span: 81..84,
        }]),
    );
}

#[test]
fn syntax() {
    assert_debug_snapshot!(parse(""));
    assert_debug_snapshot!(parse("syntax = 'proto2';"));
    assert_debug_snapshot!(parse("syntax = 'proto3';"));
}

#[test]
fn imports() {
    assert_debug_snapshot!(parse("import 'foo.proto';"));
    assert_debug_snapshot!(parse("import weak 'foo.proto';"));
    assert_debug_snapshot!(parse("import public 'foo.proto';"));
}

#[test]
fn reserved_range() {
    assert_debug_snapshot!(parse(
        "message Foo {
            reserved 1 to max;

            option message_set_wire_format = false;
        }"
    ));
    assert_debug_snapshot!(parse(
        "message Foo {
            reserved 1 to max;

            option message_set_wire_format = true;
        }"
    ));
}

#[test]
fn options() {
    assert_debug_snapshot!(parse("option (ext.foo).bar = true;"));
    assert_debug_snapshot!(parse("option ext.(foo.bar) = true;"));
    assert_debug_snapshot!(parse("option opt = ident;"));
    assert_debug_snapshot!(parse("option opt = 5;"));
    assert_debug_snapshot!(parse("option opt = -5;"));
    assert_debug_snapshot!(parse("option opt = 1.1;"));
    assert_debug_snapshot!(parse("option opt = 'foo';"));
    assert_debug_snapshot!(parse("option opt = { foo: 1 };"));
    assert_eq!(
        parse("option opt = -ident;"),
        Err(vec![NegativeIdentOutsideDefault { span: 13..19 }]),
    );
    assert_eq!(
        parse("option opt = -13835058055282163711;"),
        Err(vec![IntegerValueOutOfRange {
            expected: "a 64-bit integer".to_owned(),
            actual: "-13835058055282163711".to_string(),
            span: 13..34,
            min: "-9223372036854775808".to_owned(),
            max: "18446744073709551615".to_owned(),
        }]),
    );
}

#[test]
fn editions_file() {
    let source = r#"
        edition = "2023";

        package editions;

        option features.field_presence = IMPLICIT;

        message Message {
            int32 implicit = 1;
            int32 explicit = 2 [features.field_presence = EXPLICIT, default = 3];
            repeated int32 values = 3;
            map<string, Message> map = 4 [features.utf8_validation = NONE];
            Message delimited = 5 [features.message_encoding = DELIMITED];
            oneof choice {
                string text = 6;
            }
            reserved 7, 9 to 10;
            reserved removed, gone;
        }

        enum Enum {
            reserved RETIRED;
            ZERO = 0;
        }
    "#;
    let file = crate::parse("test.proto", source).unwrap();
    assert_eq!(file.edition, Some(1000));
    assert_eq!(file.syntax(), "editions");
    // No synthetic oneofs or proto3_optional in editions; defaults are allowed; the map entry's
    // fields carry the map field's features.
    assert_debug_snapshot!(FileDescriptorProto {
        source_code_info: None,
        ..file
    });
}

#[test]
fn editions_parse_sets_edition() {
    let file = parse("edition = '2023';").unwrap();
    assert_eq!(file.syntax(), "editions");
    assert_eq!(file.edition(), prost_types::Edition::Edition2023);
    assert_eq!(parse("syntax = 'proto3';").unwrap().edition, None);
}

#[test]
fn editions_unknown_edition() {
    assert_eq!(
        parse("edition = '2025';"),
        Err(vec![UnknownEdition {
            edition: "2025".to_owned(),
            span: 10..16,
        }]),
    );
    assert_eq!(
        parse("edition = 'proto3';"),
        Err(vec![UnknownEdition {
            edition: "proto3".to_owned(),
            span: 10..18,
        }]),
    );
}

#[test]
fn editions_field_label() {
    assert_eq!(
        parse(
            r#"
            edition = "2023";

            message Message {
                optional int32 foo = 1;
                required int32 bar = 2;
            }
            "#
        ),
        Err(vec![
            EditionsFieldLabel {
                label: "optional",
                help: "fields have explicit presence by default; the option \
                       'features.field_presence' changes it",
                span: 78..86,
            },
            EditionsFieldLabel {
                label: "required",
                help: "use the option 'features.field_presence = LEGACY_REQUIRED'",
                span: 118..126,
            },
        ]),
    );
}

#[test]
fn editions_group_field() {
    assert_eq!(
        parse(
            r#"
            edition = "2023";

            message Message {
                repeated group Foo = 1 {};
            }
            "#
        ),
        Err(vec![EditionsGroupField { span: 78..103 }]),
    );
}

#[test]
fn editions_reserved_names() {
    assert_eq!(
        parse(
            r#"
            edition = "2023";

            message Message {
                reserved "foo";
            }
            "#
        ),
        Err(vec![EditionsReservedNameString { span: 87..92 }]),
    );
    assert_eq!(
        parse(
            r#"
            syntax = "proto3";

            message Message {
                reserved foo;
            }
            "#
        )
        .unwrap_err()
        .len(),
        1,
    );
}

#[test]
fn edition_2024_file() {
    let source = r#"
        edition = "2024";

        package editions;

        import "dep.proto";
        import option "options.proto";

        // An exported message.
        export message Message {
            local message Nested {}
            export enum Kind {
                KIND_UNSPECIFIED = 0;
            }
            Nested nested = 1 [(custom) = true];
        }

        local enum Hidden {
            HIDDEN_UNSPECIFIED = 0;
        }

        message Plain {}
    "#;
    let file = crate::parse("test.proto", source).unwrap();
    assert_eq!(file.edition, Some(1001));
    assert_eq!(file.dependency, ["dep.proto"]);
    assert_eq!(file.option_dependency, ["options.proto"]);

    let message = &file.message_type[0];
    assert_eq!(
        message.visibility(),
        prost_types::SymbolVisibility::VisibilityExport
    );
    assert_eq!(
        message.nested_type[0].visibility(),
        prost_types::SymbolVisibility::VisibilityLocal
    );
    assert_eq!(
        message.enum_type[0].visibility(),
        prost_types::SymbolVisibility::VisibilityExport
    );
    assert_eq!(
        file.enum_type[0].visibility(),
        prost_types::SymbolVisibility::VisibilityLocal
    );
    assert_eq!(file.message_type[1].visibility, None);

    // The leading comment belongs to the message, the modifier aside; the option import has a
    // location of its own.
    let locations = &file.source_code_info.as_ref().unwrap().location;
    let message_location = locations.iter().find(|l| l.path == [4, 0]).unwrap();
    assert_eq!(
        message_location.leading_comments(),
        " An exported message.\n"
    );
    assert!(locations.iter().any(|l| l.path == [15, 0]));
}

#[test]
fn edition_2024_option_import_order() {
    assert_eq!(
        parse(
            r#"
            edition = "2024";
            import option "options.proto";
            import "dep.proto";
            "#
        ),
        Err(vec![ImportAfterOptionImport { span: 86..105 }]),
    );
}

#[test]
fn option_import_before_edition_2024() {
    assert_eq!(
        parse(
            r#"
            edition = "2023";
            import option "options.proto";
            "#
        ),
        Err(vec![OptionImportBeforeEdition2024 { span: 50..56 }]),
    );
    assert_eq!(
        parse("syntax = 'proto3'; import option 'options.proto';"),
        Err(vec![OptionImportBeforeEdition2024 { span: 26..32 }]),
    );
}

#[test]
fn edition_2024_weak_import() {
    assert_eq!(
        parse(
            r#"
            edition = "2024";
            import weak "dep.proto";
            "#
        ),
        Err(vec![WeakImportInEdition2024 { span: 50..54 }]),
    );
    assert!(parse("edition = '2023'; import weak 'dep.proto';").is_ok());
}

#[test]
fn edition_2024_visibility_modifier_placement() {
    assert_eq!(
        parse(
            r#"
            edition = "2024";
            export service Service {}
            "#
        ),
        Err(vec![InvalidVisibilityModifier { span: 43..49 }]),
    );
    assert_eq!(
        parse(
            r#"
            edition = "2024";
            message Message {
                local int32 field = 1;
            }
            "#
        ),
        Err(vec![InvalidVisibilityModifier { span: 77..82 }]),
    );
}

#[test]
fn visibility_modifier_before_edition_2024() {
    // Before edition 2024 `export` and `local` are ordinary identifiers: a top-level statement
    // cannot start with one, and in a message one names a field's type.
    assert!(parse("edition = '2023'; export message Message {}").is_err());
    let file = parse("edition = '2023'; message Message { local field = 1; }").unwrap();
    assert_eq!(file.message_type[0].field[0].type_name(), "local");
}
