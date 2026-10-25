//! The IR built from small protos: structure, names and the problems
//! reported instead.

use elm_connect_gen::diagnostics::{Code, Diagnostics};
use elm_connect_gen::ir::{
    Annotations, Cardinality, Field, FieldBehavior, MapKey, Message, Package, ScalarKind, TypeRef,
    WellKnown,
};

use crate::common::{build, package, problems};

fn message<'a>(package: &'a Package, elm_name: &str) -> &'a Message {
    package
        .messages
        .iter()
        .find(|message| message.elm_name == elm_name)
        .unwrap_or_else(|| panic!("no message {elm_name} in {package:#?}"))
}

fn field<'a>(message: &'a Message, elm_name: &str) -> &'a Field {
    message
        .fields
        .iter()
        .find(|field| field.elm_name == elm_name)
        .unwrap_or_else(|| panic!("no field {elm_name} in {message:#?}"))
}

fn codes(diagnostics: &Diagnostics) -> Vec<Code> {
    diagnostics.iter().map(|problem| problem.code()).collect()
}

#[test]
fn package_becomes_a_module() {
    let package = package("syntax = \"proto3\"; package foo_bar.v2beta1; message A {}");
    assert_eq!(package.proto_name, "foo_bar.v2beta1");
    assert_eq!(package.module.to_string(), "FooBar.V2beta1");
    assert_eq!(package.files, ["test.proto"]);
    let a = message(&package, "A");
    assert_eq!(a.proto_full_name, "foo_bar.v2beta1.A");
    assert!(a.fields.is_empty() && a.oneofs.is_empty() && a.wrapper.is_none());
}

#[test]
fn every_scalar_kind() {
    let package = package(
        r#"
        syntax = "proto3";
        package t;
        message S {
          double a = 1; float b = 2; int32 c = 3; int64 d = 4; uint32 e = 5;
          uint64 f = 6; sint32 g = 7; sint64 h = 8; fixed32 i = 9; fixed64 j = 10;
          sfixed32 k = 11; sfixed64 l = 12; bool m = 13; string n = 14; bytes o = 15;
        }
        "#,
    );
    let kinds: Vec<_> = message(&package, "S")
        .fields
        .iter()
        .map(|field| {
            assert_eq!(field.cardinality, Cardinality::Singular);
            field.ty.clone()
        })
        .collect();
    use ScalarKind::*;
    let expected: Vec<_> = [
        Double, Float, Int32, Int64, UInt32, UInt64, SInt32, SInt64, Fixed32, Fixed64, SFixed32,
        SFixed64, Bool, String, Bytes,
    ]
    .into_iter()
    .map(TypeRef::Scalar)
    .collect();
    assert_eq!(kinds, expected);
}

#[test]
fn cardinalities_and_maps() {
    let package = package(
        r#"
        syntax = "proto3";
        package t;
        message Tag { string name = 1; }
        message Note {
          string title = 1;
          optional string subtitle = 2;
          repeated string labels = 3;
          map<string, Tag> tags_by_name = 4;
          map<int64, int32> counts = 5;
          map<bool, string> by_flag = 6;
          Tag primary_tag = 7;
          repeated Tag all_tags = 8;
        }
        "#,
    );
    let note = message(&package, "Note");
    let tag = TypeRef::Message(elm_connect_gen::ir::TypeName {
        module: package.module.clone(),
        name: "Tag".into(),
        proto_full_name: "t.Tag".into(),
    });
    let cases = [
        (
            "title",
            Cardinality::Singular,
            TypeRef::Scalar(ScalarKind::String),
        ),
        (
            "subtitle",
            Cardinality::Optional,
            TypeRef::Scalar(ScalarKind::String),
        ),
        (
            "labels",
            Cardinality::Repeated,
            TypeRef::Scalar(ScalarKind::String),
        ),
        ("tagsByName", Cardinality::Map(MapKey::String), tag.clone()),
        (
            "counts",
            Cardinality::Map(MapKey::Int64),
            TypeRef::Scalar(ScalarKind::Int32),
        ),
        (
            "byFlag",
            Cardinality::Map(MapKey::Bool),
            TypeRef::Scalar(ScalarKind::String),
        ),
        ("primaryTag", Cardinality::Singular, tag.clone()),
        ("allTags", Cardinality::Repeated, tag),
    ];
    for (name, cardinality, ty) in cases {
        let field = field(note, name);
        assert_eq!((field.cardinality, &field.ty), (cardinality, &ty), "{name}");
    }
    assert_eq!(field(note, "tagsByName").proto_name, "tags_by_name");
    assert_eq!(field(note, "tagsByName").json_name, "tagsByName");
    assert_eq!(field(note, "tagsByName").number, 4);
    assert!(
        package
            .messages
            .iter()
            .all(|m| !m.elm_name.ends_with("Entry")),
        "map entries are not messages"
    );
}

#[test]
fn json_name_does_not_shape_elm_names() {
    let package = package(
        "syntax = \"proto3\"; package t; message M { string display_name = 1 [json_name = \"dn\"]; }",
    );
    let field = field(message(&package, "M"), "displayName");
    assert_eq!(field.json_name, "dn");
}

#[test]
fn reserved_words_gain_an_underscore() {
    let package = package(
        "syntax = \"proto3\"; package t; message M { string type = 1; int32 port = 2; bool alias = 3; }",
    );
    let names: Vec<_> = message(&package, "M")
        .fields
        .iter()
        .map(|field| field.elm_name.as_str())
        .collect();
    assert_eq!(names, ["type_", "port_", "alias"]);
}

#[test]
fn nested_types_flatten_with_a_prefix() {
    let package = package(
        r#"
        syntax = "proto3";
        package t;
        message Outer {
          message Inner {
            message Deepest { Kind kind = 1; }
          }
          enum Kind { KIND_UNSPECIFIED = 0; KIND_DRAFT = 1; }
          Inner inner = 1;
        }
        "#,
    );
    let names: Vec<_> = package
        .messages
        .iter()
        .map(|m| m.elm_name.as_str())
        .collect();
    assert_eq!(names, ["Outer", "OuterInner", "OuterInnerDeepest"]);
    assert_eq!(
        message(&package, "OuterInnerDeepest").proto_full_name,
        "t.Outer.Inner.Deepest"
    );
    assert_eq!(package.enums.len(), 1);
    let kind = &package.enums[0];
    assert_eq!(kind.elm_name, "OuterKind");
    let ctors: Vec<_> = kind.values().map(|v| v.elm_ctor.as_str()).collect();
    assert_eq!(ctors, ["OuterKindUnspecified", "OuterKindDraft"]);
    let TypeRef::Enum { name, zero_ctor } =
        &field(message(&package, "OuterInnerDeepest"), "kind").ty
    else {
        panic!("kind is an enum");
    };
    assert_eq!(name.name, "OuterKind");
    assert_eq!(zero_ctor, "OuterKindUnspecified");
    let TypeRef::Message(name) = &field(message(&package, "Outer"), "inner").ty else {
        panic!("inner is a message");
    };
    assert_eq!(name.name, "OuterInner");
}

#[test]
fn proto3_optional_is_not_a_oneof() {
    let package = package(
        "syntax = \"proto3\"; package t; message M { optional int32 limit = 1; optional M next = 2; }",
    );
    let m = message(&package, "M");
    assert!(m.oneofs.is_empty(), "{m:#?}");
    assert_eq!(field(m, "limit").cardinality, Cardinality::Optional);
    assert_eq!(field(m, "next").cardinality, Cardinality::Optional);
}

#[test]
fn real_oneof_is_a_union_with_an_unset_case() {
    let package = package(
        r#"
        syntax = "proto3";
        package t;
        message Created { string id = 1; }
        message NoteEvent {
          string note_id = 1;
          oneof kind {
            Created created = 2;
            string title_changed = 3;
          }
          optional string actor = 4;
        }
        "#,
    );
    let event = message(&package, "NoteEvent");
    let fields: Vec<_> = event.fields.iter().map(|f| f.elm_name.as_str()).collect();
    assert_eq!(fields, ["noteId", "actor"]);
    assert_eq!(event.oneofs.len(), 1);
    let kind = &event.oneofs[0];
    assert_eq!(kind.proto_name, "kind");
    assert_eq!(kind.elm_field_name, "kind");
    assert_eq!(kind.elm_type_name, "NoteEventKind");
    assert_eq!(kind.unset_ctor, "NoteEventKindUnset");
    // Declared after `note_id`, before `actor`.
    assert_eq!(kind.position, 1);
    let variants: Vec<_> = kind
        .variants
        .iter()
        .map(|v| (v.elm_ctor.as_str(), v.proto_name.as_str(), v.number))
        .collect();
    assert_eq!(
        variants,
        [
            ("NoteEventKindCreated", "created", 2),
            ("NoteEventKindTitleChanged", "title_changed", 3)
        ]
    );
    assert_eq!(kind.variants[1].json_name, "titleChanged");
    assert_eq!(kind.variants[1].ty, TypeRef::Scalar(ScalarKind::String));
}

#[test]
fn fields_keep_declaration_order() {
    let package = package(
        r#"
        syntax = "proto3";
        package t;
        message Draft {
          string title = 5;
          oneof body {
            string text = 9;
            bytes blob = 1;
          }
          int32 revision = 2;
          repeated string tags = 7;
        }
        "#,
    );
    let draft = message(&package, "Draft");
    let fields: Vec<_> = draft
        .fields
        .iter()
        .map(|f| (f.elm_name.as_str(), f.number))
        .collect();
    // The order the file writes them in, not number order.
    assert_eq!(fields, [("title", 5), ("revision", 2), ("tags", 7)]);
    // The oneof sits where its first member was declared, after `title`,
    // though its member numbered 1 would put it first by number.
    let body = &draft.oneofs[0];
    assert_eq!(body.position, 1);
    let members: Vec<_> = body
        .variants
        .iter()
        .map(|v| (v.proto_name.as_str(), v.number))
        .collect();
    assert_eq!(members, [("text", 9), ("blob", 1)]);
}

#[test]
fn enum_records_its_zero_value() {
    let package = package(
        r#"
        syntax = "proto3";
        package t;
        enum Status { STATUS_UNSPECIFIED = 0; STATUS_ACTIVE = 1; ARCHIVED = 2; }
        "#,
    );
    let status = &package.enums[0];
    assert_eq!(status.proto_full_name, "t.Status");
    assert_eq!(status.elm_name, "Status");
    assert_eq!(status.zero().proto_name, "STATUS_UNSPECIFIED");
    assert_eq!(status.zero().number, 0);
    let values: Vec<_> = status
        .values()
        .map(|v| (v.proto_name.as_str(), v.number, v.elm_ctor.as_str()))
        .collect();
    assert_eq!(
        values,
        [
            ("STATUS_UNSPECIFIED", 0, "StatusUnspecified"),
            ("STATUS_ACTIVE", 1, "StatusActive"),
            ("ARCHIVED", 2, "StatusArchived"),
        ]
    );
}

#[test]
fn enum_values_keep_declaration_order() {
    let package = package(
        r#"
        syntax = "proto3";
        package t;
        enum Level {
          option allow_alias = true;
          LEVEL_NONE = 0; HIGH = 2; LOW = 1; TOP = 2; BELOW = -1;
        }
        message M { Level level = 1; }
        "#,
    );
    let level = &package.enums[0];
    assert_eq!(level.proto_name, "Level");
    // An alias joins the constructor of the first value with its number.
    let values: Vec<_> = level
        .values()
        .map(|v| (v.proto_name.as_str(), v.number, v.aliases.clone()))
        .collect();
    assert_eq!(
        values,
        [
            ("LEVEL_NONE", 0, vec![]),
            ("HIGH", 2, vec!["TOP".to_owned()]),
            ("LOW", 1, vec![]),
            ("BELOW", -1, vec![])
        ]
    );
    let TypeRef::Enum { zero_ctor, .. } = &field(message(&package, "M"), "level").ty else {
        panic!("level is an enum");
    };
    assert_eq!(zero_ctor, "LevelNone");
}

#[test]
fn well_known_types_map() {
    let package = package(
        r#"
        syntax = "proto3";
        package t;
        import "google/protobuf/timestamp.proto";
        import "google/protobuf/duration.proto";
        import "google/protobuf/field_mask.proto";
        import "google/protobuf/empty.proto";
        import "google/protobuf/struct.proto";
        import "google/protobuf/wrappers.proto";
        import "google/protobuf/any.proto";
        message W {
          google.protobuf.Timestamp a = 1;
          google.protobuf.Duration b = 2;
          google.protobuf.FieldMask c = 3;
          google.protobuf.Empty d = 4;
          google.protobuf.Struct e = 5;
          google.protobuf.Value f = 6;
          google.protobuf.ListValue g = 7;
          google.protobuf.DoubleValue h = 8;
          google.protobuf.FloatValue i = 9;
          google.protobuf.Int64Value j = 10;
          google.protobuf.UInt64Value k = 11;
          google.protobuf.Int32Value l = 12;
          google.protobuf.UInt32Value m = 13;
          google.protobuf.BoolValue n = 14;
          google.protobuf.StringValue o = 15;
          google.protobuf.BytesValue p = 16;
          repeated google.protobuf.Timestamp q = 17;
          google.protobuf.Any r = 18;
        }
        "#,
    );
    use WellKnown::*;
    let expected = [
        Timestamp,
        Duration,
        FieldMask,
        Empty,
        Struct,
        Value,
        ListValue,
        DoubleValue,
        FloatValue,
        Int64Value,
        UInt64Value,
        Int32Value,
        UInt32Value,
        BoolValue,
        StringValue,
        BytesValue,
        Timestamp,
        Any,
    ];
    let actual: Vec<_> = message(&package, "W")
        .fields
        .iter()
        .map(|f| f.ty.clone())
        .collect();
    assert_eq!(
        actual,
        expected
            .into_iter()
            .map(TypeRef::WellKnown)
            .collect::<Vec<_>>()
    );
}

#[test]
fn google_protobuf_is_never_a_package() {
    let packages = build(
        &[(
            "test.proto",
            "syntax = \"proto3\"; package t; import \"google/protobuf/empty.proto\"; message A { google.protobuf.Empty e = 1; }",
        )],
        &["test.proto", "google/protobuf/empty.proto"],
    )
    .expect("builds");
    let names: Vec<_> = packages.iter().map(|p| p.proto_name.as_str()).collect();
    assert_eq!(names, ["t"]);
}

const USERS: &str = r#"
syntax = "proto3";
package users.v1;
message User { string id = 1; }
enum Role { ROLE_UNSPECIFIED = 0; ROLE_ADMIN = 1; }
"#;

const NOTES: &str = r#"
syntax = "proto3";
package notes.v1;
import "users/v1/user.proto";
message Note {
  users.v1.User owner = 1;
  users.v1.Role owner_role = 2;
}
"#;

#[test]
fn cross_package_references_name_their_module() {
    let files = [
        ("users/v1/user.proto", USERS),
        ("notes/v1/note.proto", NOTES),
    ];
    let packages = build(&files, &["notes/v1/note.proto", "users/v1/user.proto"]).expect("builds");
    let names: Vec<_> = packages.iter().map(|p| p.module.to_string()).collect();
    assert_eq!(names, ["Notes.V1", "Users.V1"]);
    let note = message(&packages[0], "Note");
    let TypeRef::Message(owner) = &field(note, "owner").ty else {
        panic!("owner is a message");
    };
    assert_eq!(owner.module.to_string(), "Users.V1");
    assert_eq!(owner.name, "User");
    let TypeRef::Enum { name: role, .. } = &field(note, "ownerRole").ty else {
        panic!("ownerRole is an enum");
    };
    assert_eq!(role.module.to_string(), "Users.V1");
    assert_eq!(role.name, "Role");
}

#[test]
fn a_package_spans_its_files() {
    let files = [
        (
            "a.proto",
            "syntax = \"proto3\"; package p; import \"b.proto\"; message A { B b = 1; }",
        ),
        ("b.proto", "syntax = \"proto3\"; package p; message B {}"),
    ];
    let packages = build(&files, &["b.proto", "a.proto"]).expect("builds");
    assert_eq!(packages.len(), 1);
    assert_eq!(packages[0].files, ["a.proto", "b.proto"]);
    let names: Vec<_> = packages[0]
        .messages
        .iter()
        .map(|m| m.elm_name.as_str())
        .collect();
    assert_eq!(names, ["A", "B"]);
}

#[test]
fn generate_set_must_be_closed_under_package_references() {
    let files = [
        ("users/v1/user.proto", USERS),
        ("notes/v1/note.proto", NOTES),
    ];
    let diagnostics = problems(&files, &["notes/v1/note.proto"]);
    assert_eq!(
        codes(&diagnostics),
        [Code::NotGenerated, Code::NotGenerated]
    );
    let first = diagnostics.iter().next().unwrap();
    assert!(
        first.message().contains("`notes.v1.Note`"),
        "{}",
        first.message()
    );
    assert!(
        first.message().contains("`users.v1.User`"),
        "{}",
        first.message()
    );
    let help = first.help_text();
    assert!(help.contains("users/v1/user.proto"), "{help}");
    assert!(help.contains("buf generate --include-imports"), "{help}");
    assert!(help.contains("with protoc"), "{help}");
    assert!(help.contains("`--include-imports`"), "{help}");
}

#[test]
fn a_requested_package_takes_its_unrequested_files() {
    let files = [
        (
            "users/v1/group.proto",
            "syntax = \"proto3\"; package users.v1; message Group {}",
        ),
        (
            "users/v1/user.proto",
            "syntax = \"proto3\"; package users.v1; import \"users/v1/group.proto\"; \
             message User { users.v1.Group group = 1; }",
        ),
        (
            "unrelated/v1/thing.proto",
            "syntax = \"proto3\"; package unrelated.v1; message Thing {}",
        ),
    ];
    let packages = build(&files, &["users/v1/user.proto"]).expect("builds");
    let names: Vec<_> = packages.iter().map(|p| p.proto_name.as_str()).collect();
    assert_eq!(names, ["users.v1"]);
    assert_eq!(
        packages[0].files,
        ["users/v1/group.proto", "users/v1/user.proto"]
    );
    let user = message(&packages[0], "User");
    let TypeRef::Message(group) = &field(user, "group").ty else {
        panic!("group is a message");
    };
    assert_eq!(group.name, "Group");
}

#[test]
fn recursion_is_flagged_direct_and_mutual() {
    let package = package(
        r#"
        syntax = "proto3";
        package t;
        message Node { repeated Node children = 1; }
        message Parent { Child child = 1; }
        message Child { optional Parent parent = 1; }
        message Graph { map<string, Vertex> vertices = 1; }
        message Vertex { Graph owner = 1; }
        message Leaf { string name = 1; }
        message Holder { Node root = 1; Leaf leaf = 2; }
        message Tree { oneof shape { Tree branch = 1; string tip = 2; } }
        "#,
    );
    let wrappers: Vec<_> = package
        .messages
        .iter()
        .map(|m| {
            let wrapper = m.wrapper.as_ref().map(|w| w.elm_name.as_str());
            (m.elm_name.as_str(), wrapper)
        })
        .collect();
    assert_eq!(
        wrappers,
        [
            ("Node", Some("Node_")),
            ("Parent", Some("Parent_")),
            ("Child", Some("Child_")),
            ("Graph", Some("Graph_")),
            ("Vertex", Some("Vertex_")),
            ("Leaf", None),
            ("Holder", None),
            ("Tree", None),
        ]
    );
    let cyclic =
        |message: &str, field: &str| self::field(self::message(&package, message), field).cyclic;
    assert!(cyclic("Node", "children"));
    assert!(cyclic("Parent", "child") && cyclic("Child", "parent"));
    assert!(cyclic("Graph", "vertices") && cyclic("Vertex", "owner"));
    // Holder refers to a recursive message without being on its cycle.
    assert!(!cyclic("Holder", "root") && !cyclic("Holder", "leaf"));
    let shape = &message(&package, "Tree").oneofs[0];
    let members: Vec<_> = shape
        .variants
        .iter()
        .map(|v| (v.proto_name.as_str(), v.cyclic))
        .collect();
    assert_eq!(members, [("branch", true), ("tip", false)]);
}

#[test]
fn a_cycle_through_a_oneof_marks_only_the_member() {
    let package = package(
        r#"
        syntax = "proto3";
        package t;
        message Expr { Call call = 1; }
        message Call { oneof arg { Expr expr = 1; string name = 2; } }
        "#,
    );
    assert!(package.messages.iter().all(|m| m.wrapper.is_none()));
    assert!(!field(message(&package, "Expr"), "call").cyclic);
    let arg = &message(&package, "Call").oneofs[0];
    assert!(arg.variants[0].cyclic && !arg.variants[1].cyclic);
}

#[test]
fn other_google_protobuf_types_are_errors() {
    let source = r#"
syntax = "proto3";
package t;
import "google/protobuf/api.proto";
import "google/protobuf/struct.proto";
message M { google.protobuf.Api api = 1; google.protobuf.NullValue null = 2; }
"#;
    let diagnostics = problems(&[("test.proto", source)], &["test.proto"]);
    assert_eq!(
        codes(&diagnostics),
        [Code::UnsupportedWellKnown, Code::UnsupportedWellKnown]
    );
}

#[test]
fn field_collision_after_lowercasing_capitals() {
    // protoc and protox reject two proto3 fields `ID` and `id`, but not a
    // oneof `ID` beside a field `id`; both become the record field `id`.
    let source = r#"
syntax = "proto3";
package t;
message M { string id = 1; oneof ID { string a = 2; } }
"#;
    let diagnostics = problems(&[("test.proto", source)], &["test.proto"]);
    assert_eq!(codes(&diagnostics), [Code::FieldCollision]);
}

#[test]
fn field_collision_after_casing() {
    // Two plain fields cannot collide here: protoc and protox already
    // reject proto3 fields whose default JSON names clash, and those are
    // the same lowerCamelCase names. A oneof's name is not checked.
    let source = r#"
syntax = "proto3";
package t;
message M { string foo_bar = 1; oneof fooBar { string a = 2; } }
"#;
    let diagnostics = problems(&[("test.proto", source)], &["test.proto"]);
    assert_eq!(codes(&diagnostics), [Code::FieldCollision]);
}

#[test]
fn oneof_name_collides_with_a_field() {
    let source = r#"
syntax = "proto3";
package t;
message M { string kind = 1; oneof kind_ { string a = 2; } }
"#;
    let diagnostics = problems(&[("test.proto", source)], &["test.proto"]);
    assert_eq!(codes(&diagnostics), [Code::FieldCollision]);
}

#[test]
fn type_collision_after_flattening() {
    let source = r#"
syntax = "proto3";
package t;
message Outer { message Inner {} }
message OuterInner {}
"#;
    let diagnostics = problems(&[("test.proto", source)], &["test.proto"]);
    // The record constructors collide along with the types, and the
    // type's problem says so: one mistake, one problem.
    assert_eq!(codes(&diagnostics), [Code::TypeCollision]);
    let problem = diagnostics.iter().next().unwrap();
    assert!(
        problem
            .message()
            .contains("two messages that both become the Elm type and record constructor"),
        "{}",
        problem.message()
    );
}

#[test]
fn type_collision_between_a_oneof_and_a_message() {
    let source = r#"
syntax = "proto3";
package t;
message Event { oneof kind { string a = 1; } }
message EventKind {}
"#;
    let diagnostics = problems(&[("test.proto", source)], &["test.proto"]);
    assert_eq!(codes(&diagnostics), [Code::TypeCollision]);
}

#[test]
fn type_collision_across_files_of_a_package() {
    let files = [
        (
            "a.proto",
            "syntax = \"proto3\"; package p; message A { message B {} }",
        ),
        (
            "b.proto",
            "syntax = \"proto3\"; package p; enum AB { AB_UNSPECIFIED = 0; }",
        ),
    ];
    let diagnostics = problems(&files, &["a.proto", "b.proto"]);
    assert_eq!(codes(&diagnostics), [Code::TypeCollision]);
    let sites: Vec<_> = diagnostics
        .iter()
        .next()
        .unwrap()
        .sites()
        .iter()
        .map(|s| s.file.as_str())
        .collect();
    assert_eq!(sites, ["a.proto", "b.proto"]);
}

#[test]
fn constructor_collision_between_an_enum_and_a_oneof() {
    let source = r#"
syntax = "proto3";
package t;
enum EventKind { EVENT_KIND_UNSPECIFIED = 0; EVENT_KIND_CREATED = 1; }
message Event { oneof kind { string created = 1; } }
"#;
    let diagnostics = problems(&[("test.proto", source)], &["test.proto"]);
    // `EventKind` is both the enum and the oneof's type, and
    // `EventKindCreated` both an enum value and a oneof case.
    assert_eq!(
        codes(&diagnostics),
        [Code::TypeCollision, Code::ConstructorCollision]
    );
}

#[test]
fn constructor_collision_with_a_record_constructor() {
    let source = r#"
syntax = "proto3";
package t;
enum Status { STATUS_UNSPECIFIED = 0; STATUS_ACTIVE = 1; }
message StatusActive {}
"#;
    let diagnostics = problems(&[("test.proto", source)], &["test.proto"]);
    assert_eq!(codes(&diagnostics), [Code::ConstructorCollision]);
}

#[test]
fn constructor_collision_after_stripping_a_nested_enums_prefixes() {
    let source = r#"
syntax = "proto3";
package t;
message Note {
  enum Kind { KIND_UNSPECIFIED = 0; KIND_DRAFT = 1; NOTE_KIND_DRAFT = 2; }
}
"#;
    let diagnostics = problems(&[("test.proto", source)], &["test.proto"]);
    // The own-name prefix and the path prefix both leave `Draft`, so the
    // two values are both `NoteKindDraft`.
    assert_eq!(codes(&diagnostics), [Code::ConstructorCollision]);
    let problem = diagnostics.iter().next().unwrap();
    assert!(
        problem.message().contains("`NoteKindDraft`"),
        "{}",
        problem.message()
    );
    assert_eq!(problem.sites().len(), 2);
}

#[test]
fn oneof_member_named_unset_collides_with_the_unset_case() {
    let source = r#"
syntax = "proto3";
package t;
message M { oneof choice { bool unset = 1; } }
"#;
    let diagnostics = problems(&[("test.proto", source)], &["test.proto"]);
    assert_eq!(codes(&diagnostics), [Code::ConstructorCollision]);
}

#[test]
fn invalid_names() {
    let field = "syntax = \"proto3\"; package t; message M { string _1title = 1; }";
    assert_eq!(
        codes(&problems(&[("test.proto", field)], &["test.proto"])),
        [Code::InvalidField]
    );
    let module = "syntax = \"proto3\"; package t.v1._2; message M {}";
    assert_eq!(
        codes(&problems(&[("test.proto", module)], &["test.proto"])),
        [Code::InvalidModule]
    );
    let missing = "syntax = \"proto3\"; message M {}";
    assert_eq!(
        codes(&problems(&[("test.proto", missing)], &["test.proto"])),
        [Code::InvalidModule]
    );
    let ty = "syntax = \"proto3\"; package t; message _1 {}";
    assert_eq!(
        codes(&problems(&[("test.proto", ty)], &["test.proto"])),
        [Code::InvalidType]
    );
}

#[test]
fn package_import_cycle_is_an_error() {
    // protox rejects import cycles between files, so the package cycle
    // runs through two files of package `a`.
    let files = [
        (
            "a1.proto",
            "syntax = \"proto3\"; package a; import \"b.proto\"; message A { b.B b = 1; }",
        ),
        ("a2.proto", "syntax = \"proto3\"; package a; message A2 {}"),
        (
            "b.proto",
            "syntax = \"proto3\"; package b; import \"a2.proto\"; message B { a.A2 a = 1; }",
        ),
    ];
    let diagnostics = problems(&files, &["a1.proto", "a2.proto", "b.proto"]);
    assert_eq!(codes(&diagnostics), [Code::ImportCycle]);
    let problem = diagnostics.iter().next().unwrap();
    assert_eq!(
        problem.message(),
        "The packages `a` (a1.proto, a2.proto) and `b` (b.proto) refer to each other in a cycle."
    );
    assert_eq!(problem.sites().len(), 2);
}

#[test]
fn unknown_and_proto2_files_are_errors() {
    let files = [(
        "old.proto",
        "syntax = \"proto2\"; package t; message M { optional int32 a = 1; }",
    )];
    assert_eq!(
        codes(&problems(&files, &["old.proto", "missing.proto"])),
        [Code::NotProto3, Code::UnknownFile]
    );
}

#[test]
fn a_file_name_with_a_control_character_is_an_error() {
    let files = [
        (
            "a\nevil = 1\n--.proto",
            "syntax = \"proto3\"; package t; import \"b.proto\"; message M { B b = 1; }",
        ),
        ("b.proto", "syntax = \"proto3\"; package t; message B {}"),
    ];
    let diagnostics = problems(&files, &["b.proto"]);
    assert_eq!(codes(&diagnostics), [Code::FileName]);
    let problem = diagnostics.iter().next().unwrap();
    assert_eq!(
        problem.message(),
        "The file name `a\\nevil = 1\\n--.proto` holds a control character."
    );
}

#[test]
fn services_are_ignored() {
    let package = package(
        r#"
        syntax = "proto3";
        package t;
        message Req {}
        service S { rpc Get(Req) returns (Req); }
        "#,
    );
    assert_eq!(package.messages.len(), 1);
}

#[test]
fn field_behavior_and_deprecation_are_read_from_the_options() {
    let package = package(
        r#"
syntax = "proto3";
package t.v1;
import "google/api/field_behavior.proto";

message Note {
  string name = 1 [(google.api.field_behavior) = IDENTIFIER];
  string etag = 2 [
    (google.api.field_behavior) = OUTPUT_ONLY,
    (google.api.field_behavior) = IMMUTABLE,
    deprecated = true
  ];
  string body = 3;
  oneof kind {
    string text = 4 [(google.api.field_behavior) = REQUIRED, deprecated = true];
  }
}

enum Level {
  LEVEL_UNSPECIFIED = 0;
  LEVEL_OLD = 1 [deprecated = true];
}
"#,
    );
    let note = message(&package, "Note");
    let annotations = |name: &str| field(note, name).annotations.clone();
    assert_eq!(
        annotations("name").behavior,
        [FieldBehavior::Identifier],
        "one value"
    );
    assert_eq!(
        annotations("etag"),
        Annotations {
            behavior: vec![FieldBehavior::OutputOnly, FieldBehavior::Immutable],
            deprecated: true,
            default: None,
        }
    );
    assert_eq!(annotations("body"), Annotations::default());
    assert_eq!(
        note.oneofs[0].variants[0].annotations,
        Annotations {
            behavior: vec![FieldBehavior::Required],
            deprecated: true,
            default: None,
        }
    );
    let level = &package.enums[0];
    assert!(level.is_deprecated("LEVEL_OLD"));
    assert!(!level.is_deprecated("LEVEL_UNSPECIFIED"));
}

#[test]
fn without_the_extension_a_field_has_no_behavior() {
    let package = package(
        r#"
syntax = "proto3";
package t.v1;
message Note { string name = 1 [deprecated = true]; }
"#,
    );
    assert_eq!(
        field(message(&package, "Note"), "name").annotations,
        Annotations {
            behavior: Vec::new(),
            deprecated: true,
            default: None,
        }
    );
}
