use std::{
    env, fs,
    path::{Path, PathBuf},
};

use insta::assert_yaml_snapshot;
use miette::JSONReportHandler;
use prost::Message;
use prost_reflect::{
    Cardinality, DefaultSymbolVisibility, DescriptorError, DescriptorPool, DynamicMessage, Edition,
    EnforceNamingStyle, EnumType, FieldPresence, JsonFormat, MessageEncoding, ReflectMessage,
    RepeatedFieldEncoding, SymbolVisibility, Syntax, Utf8Validation, Value,
};
use prost_types::FileDescriptorSet;

fn test_data_dir() -> PathBuf {
    PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").unwrap()).join("tests/data")
}

fn read_file_descriptor_set(path: impl AsRef<Path>) -> DynamicMessage {
    let yaml_bytes = fs::read(test_data_dir().join(path)).unwrap();

    let deserializer = yaml_serde::Deserializer::from_slice(&yaml_bytes);
    DynamicMessage::deserialize(FileDescriptorSet::default().descriptor(), deserializer).unwrap()
}

fn check(name: &str, add_wkt: bool) -> Result<DescriptorPool, DescriptorError> {
    check_with(name, add_wkt, false)
}

fn check_with(
    name: &str,
    add_wkt: bool,
    enforce_naming_style: bool,
) -> Result<DescriptorPool, DescriptorError> {
    let input = read_file_descriptor_set(format!("{}.yml", name));
    let proto_bytes = input.encode_to_vec();

    let mut pool = if add_wkt {
        FileDescriptorSet::default()
            .descriptor()
            .parent_pool()
            .clone()
    } else {
        DescriptorPool::new()
    };
    pool.enforce_naming_style(enforce_naming_style);
    pool.decode_file_descriptor_set(proto_bytes.as_slice())?;

    Ok(pool)
}

fn check_ok(name: &str, add_wkt: bool) {
    let pool = check(name, add_wkt).unwrap();
    let set_desc = pool
        .get_message_by_name("google.protobuf.FileDescriptorSet")
        .unwrap_or_else(|| FileDescriptorSet::default().descriptor());

    let mut actual = DynamicMessage::decode(set_desc, pool.encode_to_vec().as_slice()).unwrap();

    if add_wkt {
        actual
            .get_field_by_name_mut("file")
            .unwrap()
            .as_list_mut()
            .unwrap()
            .retain(|f| {
                !f.as_message()
                    .unwrap()
                    .get_field_by_name("package")
                    .unwrap()
                    .as_str()
                    .unwrap()
                    .starts_with("google.protobuf")
            });
    }

    insta::with_settings!({ sort_maps => true }, {
        assert_yaml_snapshot!(name, actual);
    });
}

fn check_err(name: &str, add_wkt: bool) {
    render_err(name, check(name, add_wkt).unwrap_err());
}

fn render_err(name: &str, actual_err: DescriptorError) {
    let mut actual_json = String::new();
    JSONReportHandler::new()
        .render_report(&mut actual_json, &actual_err)
        .unwrap();
    let actual = serde_json::from_str::<serde_json::Value>(&actual_json).unwrap();

    insta::with_settings!({ sort_maps => true }, {
        assert_yaml_snapshot!(name, actual);
    });
}

macro_rules! check_ok {
    ($name:ident) => {
        #[test]
        fn $name() {
            check_ok(stringify!($name), false);
        }
    };
    ($name:ident, add_wkt: true) => {
        #[test]
        fn $name() {
            check_ok(stringify!($name), true);
        }
    };
}

macro_rules! check_err {
    ($name:ident) => {
        #[test]
        fn $name() {
            check_err(stringify!($name), false);
        }
    };
    ($name:ident, add_wkt: true) => {
        #[test]
        fn $name() {
            check_err(stringify!($name), true);
        }
    };
}

check_err!(name_conflict_in_imported_files);
check_err!(name_conflict_with_import);
check_err!(name_conflict_package1);
check_err!(name_conflict_package2);
check_ok!(name_conflict_package3);
check_err!(name_conflict_field_camel_case1);
check_err!(name_conflict_field_camel_case2);
check_ok!(name_conflict_field_camel_case3);
check_err!(name_conflict1);
check_err!(name_conflict2);
check_err!(name_conflict3);
check_err!(invalid_message_number1);
check_err!(invalid_message_number2);
check_err!(generate_map_entry_message_name_conflict);
check_err!(generate_group_message_name_conflict);
check_err!(generate_synthetic_oneof_name_conflict);
check_err!(invalid_service_type1);
check_err!(invalid_service_type2);
check_err!(invalid_service_type3);
check_err!(name_resolution1);
check_err!(name_resolution2);
check_ok!(name_resolution3);
check_err!(name_resolution4);
check_ok!(name_resolution5);
check_ok!(name_resolution6);
check_err!(name_collision1);
check_err!(name_collision2);
check_err!(name_collision3);
check_err!(name_collision4);
check_err!(name_collision5);
check_err!(field_default_value1);
check_ok!(field_default_value2);
check_ok!(field_set_json_name);
check_err!(enum_field_invalid_default1);
check_err!(enum_field_invalid_default2);
check_err!(enum_field_invalid_default3);
check_err!(enum_field_invalid_default4);
check_ok!(enum_field_invalid_default5);
check_err!(enum_field_invalid_default6);
check_ok!(enum_field_invalid_default7);
check_err!(enum_field_invalid_default8);
check_ok!(enum_field_invalid_default9);
check_err!(field_default_invalid_type1);
check_err!(field_default_invalid_type2);
check_err!(field_default_invalid_type3);
check_err!(message_field_duplicate_number1);
check_err!(message_field_duplicate_number2);
check_err!(message_reserved_range_overlap_with_field1);
check_err!(message_reserved_range_overlap_with_field2);
check_ok!(message_reserved_range_message_set1);
check_ok!(message_reserved_range_message_set2);
check_ok!(extend_group_field);
check_err!(extend_field_number_not_in_extensions1);
check_err!(extend_field_number_not_in_extensions2);
check_ok!(oneof_group_field);
check_err!(enum_reserved_range_overlap_with_value1);
check_err!(enum_reserved_range_overlap_with_value2);
check_err!(enum_reserved_range_overlap_with_value3);
check_err!(enum_duplicate_number1);
check_err!(enum_duplicate_number2);
check_ok!(enum_duplicate_number3);
check_ok!(enum_default1);
check_err!(enum_default2);
check_ok!(enum_default3);
check_err!(option_unknown_field);
check_err!(option_unknown_extension);
check_err!(option_extension_dependency_not_imported, add_wkt: true);
check_ok!(option_extension_dependency_transitive, add_wkt: true);
check_err!(option_extension_wrong_extendee, add_wkt: true);
check_err!(option_extension_invalid_type);
check_err!(option_already_set);
check_ok!(option_map_entry_set_explicitly);
check_ok!(option_resolution1, add_wkt: true);
check_ok!(option_resolution2, add_wkt: true);
check_ok!(option_resolution3, add_wkt: true);
check_ok!(option_resolution4, add_wkt: true);
check_ok!(option_resolution5, add_wkt: true);
check_ok!(option_resolution6, add_wkt: true);
check_ok!(option_resolution7, add_wkt: true);
check_ok!(option_resolution8, add_wkt: true);
check_ok!(option_resolution9, add_wkt: true);
check_ok!(option_resolution10, add_wkt: true);
check_ok!(option_resolution11, add_wkt: true);
check_ok!(option_resolution12, add_wkt: true);
check_ok!(option_resolution13, add_wkt: true);
check_ok!(option_resolution14, add_wkt: true);
check_ok!(option_resolution15, add_wkt: true);
check_ok!(option_resolution16, add_wkt: true);
check_ok!(option_resolution17, add_wkt: true);
check_err!(option_resolution18, add_wkt: true);
check_ok!(option_resolution19);
check_ok!(option_resolution20, add_wkt: true);
check_ok!(option_resolution21, add_wkt: true);
check_ok!(option_resolution22, add_wkt: true);
check_ok!(option_resolution23, add_wkt: true);
check_ok!(option_resolution24, add_wkt: true);
check_err!(dependency_not_imported);
check_ok!(dependency_resolution_transitive);
check_ok!(dependency_resolution_transitive2);
check_err!(dependency_resolution_transitive3);
check_ok!(editions_features);
check_ok!(editions_map_fields);
check_err!(editions_unsupported_edition);
check_err!(editions_missing_edition);
check_err!(editions_features_in_proto3);
check_err!(editions_required_label);
check_err!(editions_group_type);
check_err!(editions_packed_option);
check_err!(editions_implicit_default);
check_err!(editions_implicit_closed_enum);
check_err!(editions_open_enum_first_value);
check_err!(editions_oneof_field_presence);
check_err!(editions_repeated_field_presence);
check_err!(editions_message_implicit_presence);
check_err!(editions_feature_unknown_value);
check_err!(editions_feature_from_2024);
check_err!(editions_file_legacy_required);
check_ok!(editions_json_name_conflict1);
check_ok!(editions_json_name_conflict2);
check_err!(editions_extension_required);
check_err!(editions_utf8_validation_non_string);
check_err!(editions_message_encoding_non_message);
check_err!(editions_feature_target);
check_ok!(editions_2024_visibility);
check_err!(editions_2024_local_message);
check_err!(editions_2024_nested_default_local);
check_err!(editions_2024_local_all);
check_err!(editions_2024_extendee_not_visible);
check_ok!(editions_2023_visibility);
check_err!(editions_2024_strict_nested_message);
check_err!(editions_2024_strict_nested_enum);
check_ok!(editions_2024_strict_namespace_enum);
check_err!(editions_2024_default_visibility_target);
check_ok!(editions_2024_option_dependency, add_wkt: true);
check_err!(editions_2024_option_dependency_type);
check_ok!(editions_2024_option_dependency_missing);
check_err!(editions_option_dependency_before_2024);
check_err!(editions_2024_weak_dependency);
check_err!(editions_2024_ctype);
check_err!(editions_2024_java_multiple_files);

// Regression test for https://github.com/andrewhickman/prost-reflect/issues/195
//
// When FieldOptions is present but carries no explicit `packed` entry,
// is_packed() must follow the syntax default: true for proto3, false for proto2.
// This applies to both regular fields (resolve_field) and extension fields
// (resolve_extension).
#[test]
fn is_packed_with_present_but_empty_field_options() {
    use prost::Message as _;
    use prost_types::{
        descriptor_proto::ExtensionRange,
        field_descriptor_proto::{Label, Type},
        DescriptorProto, FieldDescriptorProto, FieldOptions, FileDescriptorProto,
        FileDescriptorSet,
    };

    // Build a pool with one repeated int32 regular field and one repeated int32
    // extension field, both carrying FieldOptions::default() (present but empty,
    // as emitted by protoc when a custom option annotation is present but packed
    // is unset).
    let make_pool = |syntax: &str| {
        let fds = FileDescriptorSet {
            file: vec![FileDescriptorProto {
                name: Some("test.proto".into()),
                syntax: Some(syntax.into()),
                message_type: vec![DescriptorProto {
                    name: Some("Foo".into()),
                    field: vec![FieldDescriptorProto {
                        name: Some("values".into()),
                        number: Some(1),
                        label: Some(Label::Repeated as i32),
                        r#type: Some(Type::Int32 as i32),
                        options: Some(FieldOptions::default()),
                        ..Default::default()
                    }],
                    extension_range: vec![ExtensionRange {
                        start: Some(100),
                        end: Some(200),
                        ..Default::default()
                    }],
                    ..Default::default()
                }],
                extension: vec![FieldDescriptorProto {
                    name: Some("ext_values".into()),
                    number: Some(100),
                    label: Some(Label::Repeated as i32),
                    r#type: Some(Type::Int32 as i32),
                    extendee: Some(".Foo".into()),
                    options: Some(FieldOptions::default()),
                    ..Default::default()
                }],
                ..Default::default()
            }],
        };
        DescriptorPool::decode(fds.encode_to_vec().as_slice()).unwrap()
    };

    // proto3: packed defaults to true when options is present but packed is absent
    let pool = make_pool("proto3");
    let field = pool
        .get_message_by_name("Foo")
        .unwrap()
        .get_field_by_name("values")
        .unwrap();
    assert!(
        field.is_packed(),
        "proto3 regular field: present-but-empty FieldOptions must be packed"
    );
    let ext = pool.get_extension_by_name("ext_values").unwrap();
    assert!(
        ext.is_packed(),
        "proto3 extension field: present-but-empty FieldOptions must be packed"
    );

    // proto2: packed defaults to false when options is present but packed is absent
    let pool = make_pool("proto2");
    let field = pool
        .get_message_by_name("Foo")
        .unwrap()
        .get_field_by_name("values")
        .unwrap();
    assert!(
        !field.is_packed(),
        "proto2 regular field: present-but-empty FieldOptions must not be packed"
    );
    let ext = pool.get_extension_by_name("ext_values").unwrap();
    assert!(
        !ext.is_packed(),
        "proto2 extension field: present-but-empty FieldOptions must not be packed"
    );
}

#[test]
fn editions_features_resolve() {
    let pool = check("editions_features", false).unwrap();
    let file = pool.get_file_by_name("test.proto").unwrap();
    assert_eq!(file.syntax(), Syntax::Editions);
    assert_eq!(file.edition(), Edition::Edition2023);
    // Set on the file; the rest are edition 2023's defaults.
    assert_eq!(file.features().enum_type(), EnumType::Closed);
    assert_eq!(file.features().utf8_validation(), Utf8Validation::None);
    assert_eq!(file.features().field_presence(), FieldPresence::Implicit);
    assert_eq!(
        file.features().repeated_field_encoding(),
        RepeatedFieldEncoding::Packed
    );
    assert_eq!(
        file.features().message_encoding(),
        MessageEncoding::LengthPrefixed
    );
    assert_eq!(file.features().json_format(), JsonFormat::Allow);

    let message = pool.get_message_by_name("test.Message").unwrap();
    assert_eq!(message.features().field_presence(), FieldPresence::Implicit);
    assert_eq!(
        message.features().json_format(),
        JsonFormat::LegacyBestEffort
    );
    let field = |name: &str| message.get_field_by_name(name).unwrap();

    // Inherited from the file through the message.
    let implicit = field("implicit");
    assert_eq!(
        implicit.features().field_presence(),
        FieldPresence::Implicit
    );
    assert_eq!(
        implicit.features().json_format(),
        JsonFormat::LegacyBestEffort
    );
    assert!(!implicit.supports_presence());
    assert_eq!(implicit.cardinality(), Cardinality::Optional);

    let explicit = field("explicit");
    assert_eq!(
        explicit.features().field_presence(),
        FieldPresence::Explicit
    );
    assert!(explicit.supports_presence());

    let required = field("required");
    assert!(required.is_required());
    assert_eq!(required.cardinality(), Cardinality::Required);
    assert!(required.supports_presence());

    assert!(field("packed").is_packed());
    assert!(!field("expanded").is_packed());

    let delimited = field("delimited");
    assert!(delimited.is_group());
    assert!(delimited.supports_presence());
    assert!(!field("child").is_group());
    // Message fields have presence whatever their presence feature.
    assert!(field("child").supports_presence());

    // A oneof's features pass to its fields; oneof fields always have presence. No 2023
    // feature targets a oneof, so its features are its message's.
    let choice = message.oneofs().next().unwrap();
    assert_eq!(choice.features(), message.features());
    let in_oneof = field("in_oneof");
    assert_eq!(
        in_oneof.features().field_presence(),
        FieldPresence::Implicit
    );
    assert!(in_oneof.supports_presence());

    assert_eq!(field("with_default").default_value(), Value::I32(7));
    assert_eq!(
        field("text").features().utf8_validation(),
        Utf8Validation::Verify
    );

    let child = pool.get_message_by_name("test.Message.Child").unwrap();
    assert_eq!(child.features(), message.features());
    assert!(!child
        .get_field_by_name("value")
        .unwrap()
        .supports_presence());

    let closed = pool.get_enum_by_name("test.Closed").unwrap();
    assert!(closed.is_closed());
    let open = pool.get_enum_by_name("test.Open").unwrap();
    assert!(!open.is_closed());
    assert_eq!(
        open.get_value(1).unwrap().features().enum_type(),
        EnumType::Open
    );

    // No 2023 feature targets services or methods; they inherit the file's.
    let service = pool.get_service_by_name("test.Service").unwrap();
    assert_eq!(service.features(), file.features());
    let method = service.methods().next().unwrap();
    assert_eq!(method.features(), file.features());

    // An extension inherits from the scope it is declared in, not from the message it extends.
    let ext = pool.get_extension_by_name("test.ext").unwrap();
    assert_eq!(ext.features().json_format(), JsonFormat::Allow);
    assert!(ext.is_packed());

    // The edition survives encoding the pool.
    let reencoded = DescriptorPool::decode(pool.encode_to_vec().as_slice()).unwrap();
    assert_eq!(
        reencoded.get_file_by_name("test.proto").unwrap().edition(),
        Edition::Edition2023
    );
}

#[test]
fn legacy_features() {
    let pool = check("field_default_value2", false).unwrap();
    let file = pool.files().next().unwrap();
    assert_eq!(file.edition(), Edition::Proto2);
    assert_eq!(file.features().enum_type(), EnumType::Closed);
    assert_eq!(file.features().json_format(), JsonFormat::LegacyBestEffort);
    assert_eq!(
        file.features().repeated_field_encoding(),
        RepeatedFieldEncoding::Expanded
    );

    let proto3 = FileDescriptorSet::default()
        .descriptor()
        .parent_pool()
        .clone();
    let any = proto3
        .get_file_by_name("google/protobuf/any.proto")
        .unwrap();
    assert_eq!(any.edition(), Edition::Proto3);
    assert_eq!(any.features().field_presence(), FieldPresence::Implicit);
    assert_eq!(any.features().enum_type(), EnumType::Open);

    // descriptor.proto is proto2: `required` fields have required presence.
    let name_part = proto3
        .get_message_by_name("google.protobuf.UninterpretedOption.NamePart")
        .unwrap();
    assert_eq!(
        name_part
            .get_field_by_name("name_part")
            .unwrap()
            .features()
            .field_presence(),
        FieldPresence::LegacyRequired
    );
}

#[test]
fn editions_binary_encoding() {
    let pool = check("editions_features", false).unwrap();
    let message = pool.get_message_by_name("test.Message").unwrap();
    let child = pool.get_message_by_name("test.Message.Child").unwrap();

    let mut child_value = DynamicMessage::new(child.clone());
    child_value.set_field_by_name("value", Value::I32(1));

    let mut value = DynamicMessage::new(message.clone());
    value.set_field_by_name("implicit", Value::I32(0));
    value.set_field_by_name("explicit", Value::I32(0));
    value.set_field_by_name("required", Value::I32(5));
    value.set_field_by_name("packed", Value::List(vec![Value::I32(1), Value::I32(2)]));
    value.set_field_by_name("expanded", Value::List(vec![Value::I32(1), Value::I32(2)]));
    value.set_field_by_name("delimited", Value::Message(child_value));

    let encoded = value.encode_to_vec();
    assert_eq!(
        encoded,
        [
            // explicit = 0: set, so written although it is the default
            0x10, 0x00, //
            // required = 5
            0x18, 0x05, //
            // packed = [1, 2]: one length-delimited record
            0x22, 0x02, 0x01, 0x02, //
            // expanded = [1, 2]: a record per element
            0x28, 0x01, 0x28, 0x02, //
            // delimited: start group 6, value = 1, end group 6
            0x33, 0x08, 0x01, 0x34,
        ]
    );

    // The implicit-presence field set to its default was not written, so it decodes as unset.
    let decoded = DynamicMessage::decode(message.clone(), encoded.as_slice()).unwrap();
    let mut expected = value.clone();
    expected.clear_field_by_name("implicit");
    assert_eq!(decoded, expected);
    assert!(!decoded.has_field_by_name("implicit"));
    assert!(decoded.has_field_by_name("explicit"));
}

#[test]
fn editions_json_and_text_format() {
    let pool = check("editions_features", false).unwrap();
    let message = pool.get_message_by_name("test.Message").unwrap();
    let child = pool.get_message_by_name("test.Message.Child").unwrap();

    let mut child_value = DynamicMessage::new(child);
    child_value.set_field_by_name("value", Value::I32(1));

    let mut value = DynamicMessage::new(message.clone());
    value.set_field_by_name("explicit", Value::I32(0));
    value.set_field_by_name("delimited", Value::Message(child_value));

    // A field with explicit presence is written when set to its default; one with implicit
    // presence is not.
    let json = serde_json::to_value(&value).unwrap();
    assert_eq!(
        json,
        serde_json::json!({ "explicit": 0, "delimited": { "value": 1 } })
    );
    let parsed = DynamicMessage::deserialize(
        message.clone(),
        serde_json::json!({ "explicit": 0, "delimited": { "value": 1 } }),
    )
    .unwrap();
    assert_eq!(parsed, value);

    // A delimited field is not a group in the text format unless it looks like one: this one
    // keeps its field name.
    let text = value.to_text_format();
    assert_eq!(text, "explicit:0,delimited{value:1}");
    assert_eq!(
        DynamicMessage::parse_text_format(message, &text).unwrap(),
        value
    );
}

#[test]
fn editions_map_fields_are_not_delimited() {
    let pool = check("editions_map_fields", false).unwrap();
    let message = pool.get_message_by_name("Message").unwrap();
    // The file is delimited, but a map field and its entry's value are not groups.
    let map = message.get_field_by_name("map").unwrap();
    assert!(map.is_map());
    assert!(!map.is_group());
    let entry = pool.get_message_by_name("Message.MapEntry").unwrap();
    assert!(!entry.map_entry_value_field().is_group());
    assert_eq!(
        entry.map_entry_key_field().features().utf8_validation(),
        Utf8Validation::None
    );
    assert!(message.get_field_by_name("child").unwrap().is_group());
}

#[test]
fn editions_2024_visibility_resolves() {
    let pool = check("editions_2024_visibility", false).unwrap();
    let file = pool.get_file_by_name("dep.proto").unwrap();
    assert_eq!(file.edition(), Edition::Edition2024);
    // Edition 2024's defaults; the 2023 features keep theirs.
    assert_eq!(
        file.features().default_symbol_visibility(),
        DefaultSymbolVisibility::ExportTopLevel
    );
    assert_eq!(
        file.features().enforce_naming_style(),
        EnforceNamingStyle::Style2024
    );
    assert_eq!(file.features().field_presence(), FieldPresence::Explicit);

    let message = |name: &str| pool.get_message_by_name(name).unwrap();
    assert_eq!(message("dep.Top").visibility_keyword(), None);
    assert_eq!(message("dep.Top").visibility(), SymbolVisibility::Export);
    assert_eq!(
        message("dep.Top.Exported").visibility_keyword(),
        Some(SymbolVisibility::Export)
    );
    assert_eq!(
        message("dep.Top.Nested").visibility(),
        SymbolVisibility::Local
    );
    let kind = pool.get_enum_by_name("dep.Top.Kind").unwrap();
    assert_eq!(kind.visibility(), SymbolVisibility::Export);
    let color = pool.get_enum_by_name("dep.Color").unwrap();
    assert_eq!(color.visibility(), SymbolVisibility::Export);

    // Before edition 2024 everything is exported.
    let pool = check("editions_2023_visibility", false).unwrap();
    let nested = pool.get_message_by_name("dep.Top.Nested").unwrap();
    assert_eq!(nested.visibility(), SymbolVisibility::Export);
    assert_eq!(
        nested.features().default_symbol_visibility(),
        DefaultSymbolVisibility::ExportAll
    );
    assert_eq!(
        nested.features().enforce_naming_style(),
        EnforceNamingStyle::StyleLegacy
    );
}

#[test]
fn editions_2024_option_dependencies() {
    let pool = check("editions_2024_option_dependency", true).unwrap();
    let file = pool.get_file_by_name("test.proto").unwrap();
    assert_eq!(file.dependencies().len(), 0);
    let option_dependencies: Vec<_> = file
        .option_dependencies()
        .map(|f| f.name().to_owned())
        .collect();
    assert_eq!(option_dependencies, ["options.proto"]);
    // The option dependency survives the prost-types and encoded forms.
    assert_eq!(
        file.file_descriptor_proto().option_dependency,
        ["options.proto"]
    );
    // An option dependency that is not in the pool is left out.
    let missing_pool = check("editions_2024_option_dependency_missing", false).unwrap();
    let missing = missing_pool.get_file_by_name("test.proto").unwrap();
    assert_eq!(missing.option_dependencies().count(), 0);
    assert_eq!(
        missing.file_descriptor_proto().option_dependency,
        ["options.proto"]
    );

    let round_trip = DescriptorPool::decode(pool.encode_to_vec().as_slice()).unwrap();
    assert_eq!(
        round_trip
            .get_file_by_name("test.proto")
            .unwrap()
            .option_dependencies()
            .count(),
        1
    );
}

#[test]
fn editions_2024_naming_style() {
    let name = "editions_2024_naming_style";
    render_err(name, check_with(name, false, true).unwrap_err());
    // Names are checked only when the pool is asked to: protoc strips the source-retention
    // feature that opts a file out from the descriptors it writes.
    assert!(check(name, false).is_ok());
}

#[test]
fn editions_2024_naming_style_legacy() {
    check_with("editions_2024_naming_style_legacy", false, true).unwrap();
}
