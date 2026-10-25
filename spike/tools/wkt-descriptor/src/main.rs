//! Prints descriptor.proto as the `FileDescriptorProto { .. }` literal of prost-reflect's
//! `src/reflect/wkt.rs`, in the field order and style of the literals already there. Options
//! are printed as prost-types sees them (wkt.rs builds them with `Options::from_prost`), so
//! options prost-types does not model are dropped, as they are in the existing literals.

use std::io::Read;

use prost::Message;
use prost_types::{
    field_descriptor_proto::{Label, Type},
    DescriptorProto, EnumDescriptorProto, EnumValueDescriptorProto, FieldDescriptorProto,
    FieldOptions, FileDescriptorProto, FileDescriptorSet, FileOptions, MessageOptions,
    OneofDescriptorProto,
};

fn main() {
    let mut bytes = Vec::new();
    std::io::stdin().read_to_end(&mut bytes).unwrap();
    let set = FileDescriptorSet::decode(bytes.as_slice()).unwrap();
    let file = set
        .file
        .iter()
        .find(|f| f.name() == "google/protobuf/descriptor.proto")
        .expect("descriptor.proto in the set");
    print!("{}", file_literal(file));
}

fn opt_str(value: &Option<String>) -> String {
    match value {
        Some(s) => format!("Some({:?}.into())", s),
        None => "None".to_owned(),
    }
}

fn opt<T: std::fmt::Debug>(value: &Option<T>) -> String {
    match value {
        Some(v) => format!("Some({v:?})"),
        None => "None".to_owned(),
    }
}

fn vec<T>(items: &[T], f: impl Fn(&T) -> String) -> String {
    format!(
        "vec![{}]",
        items.iter().map(f).collect::<Vec<_>>().join(", ")
    )
}

fn strings(items: &[String]) -> String {
    vec(items, |s| format!("{s:?}.into()"))
}

fn file_literal(file: &FileDescriptorProto) -> String {
    assert!(file.service.is_empty() && file.extension.is_empty());
    format!(
        "FileDescriptorProto {{ name: {}, package: {}, dependency: {}, public_dependency: {:?}, \
         weak_dependency: {:?}, message_type: {}, enum_type: {}, service: vec![], extension: \
         vec![], options: {}, source_code_info: None, syntax: {}, edition: None, }}",
        opt_str(&file.name),
        opt_str(&file.package),
        strings(&file.dependency),
        file.public_dependency,
        file.weak_dependency,
        vec(&file.message_type, message_literal),
        vec(&file.enum_type, enum_literal),
        file.options
            .as_ref()
            .map_or("None".to_owned(), |o| format!("Some(Options::from_prost({}))", file_options(o))),
        opt_str(&file.syntax),
    )
}

fn file_options(o: &FileOptions) -> String {
    assert!(o.uninterpreted_option.is_empty());
    let optimize_for = match o.optimize_for {
        Some(1) => "Some(Speed.into())".to_owned(),
        None => "None".to_owned(),
        Some(other) => panic!("optimize_for {other} not handled"),
    };
    format!(
        "FileOptions {{ java_package: {}, java_outer_classname: {}, java_multiple_files: {}, \
         java_generate_equals_and_hash: {}, java_string_check_utf8: {}, optimize_for: {}, \
         go_package: {}, cc_generic_services: {}, java_generic_services: {}, \
         py_generic_services: {}, php_generic_services: {}, deprecated: {}, cc_enable_arenas: \
         {}, objc_class_prefix: {}, csharp_namespace: {}, swift_prefix: {}, php_class_prefix: \
         {}, php_namespace: {}, php_metadata_namespace: {}, ruby_package: {}, \
         uninterpreted_option: vec![], }}",
        opt_str(&o.java_package),
        opt_str(&o.java_outer_classname),
        opt(&o.java_multiple_files),
        opt(&o.java_generate_equals_and_hash),
        opt(&o.java_string_check_utf8),
        optimize_for,
        opt_str(&o.go_package),
        opt(&o.cc_generic_services),
        opt(&o.java_generic_services),
        opt(&o.py_generic_services),
        opt(&o.php_generic_services),
        opt(&o.deprecated),
        opt(&o.cc_enable_arenas),
        opt_str(&o.objc_class_prefix),
        opt_str(&o.csharp_namespace),
        opt_str(&o.swift_prefix),
        opt_str(&o.php_class_prefix),
        opt_str(&o.php_namespace),
        opt_str(&o.php_metadata_namespace),
        opt_str(&o.ruby_package),
    )
}

fn message_literal(m: &DescriptorProto) -> String {
    format!(
        "DescriptorProto {{ name: {}, field: {}, extension: {}, nested_type: {}, enum_type: {}, \
         extension_range: {}, oneof_decl: {}, options: {}, reserved_range: {}, reserved_name: \
         {}, }}",
        opt_str(&m.name),
        vec(&m.field, field_literal),
        vec(&m.extension, field_literal),
        vec(&m.nested_type, message_literal),
        vec(&m.enum_type, enum_literal),
        // The existing literals carry no extension range options (prost-types' are empty).
        vec(&m.extension_range, |r| format!(
            "ExtensionRange {{ start: {}, end: {}, options: None, }}",
            opt(&r.start),
            opt(&r.end)
        )),
        vec(&m.oneof_decl, oneof_literal),
        m.options.as_ref().map_or("None".to_owned(), |o| format!(
            "Some(Options::from_prost({}))",
            message_options(o)
        )),
        vec(&m.reserved_range, |r| format!(
            "ReservedRange {{ start: {}, end: {}, }}",
            opt(&r.start),
            opt(&r.end)
        )),
        strings(&m.reserved_name),
    )
}

fn message_options(o: &MessageOptions) -> String {
    assert!(o.uninterpreted_option.is_empty());
    format!(
        "MessageOptions {{ message_set_wire_format: {}, no_standard_descriptor_accessor: {}, \
         deprecated: {}, map_entry: {}, uninterpreted_option: vec![], }}",
        opt(&o.message_set_wire_format),
        opt(&o.no_standard_descriptor_accessor),
        opt(&o.deprecated),
        opt(&o.map_entry),
    )
}

fn oneof_literal(o: &OneofDescriptorProto) -> String {
    assert!(o.options.is_none());
    format!(
        "OneofDescriptorProto {{ name: {}, options: None, }}",
        opt_str(&o.name)
    )
}

fn field_literal(f: &FieldDescriptorProto) -> String {
    let label = f
        .label
        .map_or("None".to_owned(), |l| format!("Some({:?}.into())", Label::try_from(l).unwrap()));
    let ty = f
        .r#type
        .map_or("None".to_owned(), |t| format!("Some({:?}.into())", Type::try_from(t).unwrap()));
    format!(
        "FieldDescriptorProto {{ name: {}, number: {}, label: {}, r#type: {}, type_name: {}, \
         extendee: {}, default_value: {}, oneof_index: {}, json_name: {}, options: {}, \
         proto3_optional: {}, }}",
        opt_str(&f.name),
        opt(&f.number),
        label,
        ty,
        opt_str(&f.type_name),
        opt_str(&f.extendee),
        opt_str(&f.default_value),
        opt(&f.oneof_index),
        opt_str(&f.json_name),
        f.options.as_ref().map_or("None".to_owned(), |o| format!(
            "Some(Options::from_prost({}))",
            field_options(o)
        )),
        opt(&f.proto3_optional),
    )
}

fn field_options(o: &FieldOptions) -> String {
    assert!(o.uninterpreted_option.is_empty());
    assert!(o.ctype.is_none() && o.jstype.is_none(), "ctype/jstype not handled");
    format!(
        "FieldOptions {{ ctype: None, packed: {}, jstype: None, lazy: {}, deprecated: {}, weak: \
         {}, uninterpreted_option: vec![], }}",
        opt(&o.packed),
        opt(&o.lazy),
        opt(&o.deprecated),
        opt(&o.weak),
    )
}

fn enum_literal(e: &EnumDescriptorProto) -> String {
    assert!(e.options.is_none(), "enum options not handled: {}", e.name());
    format!(
        "EnumDescriptorProto {{ name: {}, value: {}, options: None, reserved_range: {}, \
         reserved_name: {}, }}",
        opt_str(&e.name),
        vec(&e.value, value_literal),
        vec(&e.reserved_range, |r| format!(
            "EnumReservedRange {{ start: {}, end: {}, }}",
            opt(&r.start),
            opt(&r.end)
        )),
        strings(&e.reserved_name),
    )
}

fn value_literal(v: &EnumValueDescriptorProto) -> String {
    // Enum value options (feature support annotations) are not modelled by prost-types beyond
    // `deprecated`; the existing literals carry none.
    let deprecated = v.options.as_ref().and_then(|o| o.deprecated);
    assert!(deprecated.is_none(), "deprecated enum value not handled");
    format!(
        "EnumValueDescriptorProto {{ name: {}, number: {}, options: None, }}",
        opt_str(&v.name),
        opt(&v.number),
    )
}
