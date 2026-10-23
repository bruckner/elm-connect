//! The Elm naming rules (design §3.7): pure functions from proto names to
//! Elm names.
//!
//! Every function here is total over proto identifiers and deterministic;
//! the ones that can produce something Elm would reject return a
//! [`NameError`] instead. Detecting *collisions* between the names these
//! produce is the IR builder's job, since it needs the proto sources to
//! report them.

use crate::ir::ModuleName;

/// The words Elm reserves, which cannot name a record field or a variable.
///
/// The list is `reservedWords` in `compiler/src/Parse/Variable.hs` of
/// elm/compiler at tag 0.19.2 (unchanged since 0.19.0). `alias` and `infix`
/// are not in it: both are legal record field names in Elm 0.19.2, so they
/// are left alone.
pub const ELM_RESERVED_WORDS: [&str; 14] = [
    "if", "then", "else", "case", "of", "let", "in", "type", "module", "where", "import",
    "exposing", "as", "port",
];

/// The runtime package's name, as its `elm.json` gives it; a macro so the
/// strings built from it are constants.
macro_rules! runtime_package {
    () => {
        "bruckner/elm-connect"
    };
}

/// The runtime package's name.
pub const RUNTIME_PACKAGE: &str = runtime_package!();

/// The runtime package's documentation on the package site, to which a
/// module's page name and an anchor are appended
/// (`Proto-Message#Descriptor`). It names `latest` because the site has
/// no path for a major or minor version, only for an exact release, and
/// generated code is not tied to one: its `elmConnectVersion_` pins the
/// minor version it was generated for.
pub const RUNTIME_DOCS: &str = concat!(
    "https://package.elm-lang.org/packages/",
    runtime_package!(),
    "/latest/"
);

/// The repository's files on GitHub at the release tag of this crate's
/// version, to which a path from the repository root is appended
/// (`docs/diagnostics.md`): where the binaries point a reader at the docs
/// pages, whose relative links mean nothing on a terminal. A release's
/// binary so links the docs that describe it, not `main`'s, which move on
/// after it. A build between releases carries the last release's version,
/// and links that release's docs.
pub const REPOSITORY_FILES: &str = concat!(
    "https://github.com/bruckner/elm-connect/blob/",
    env!("CARGO_PKG_VERSION"),
    "/"
);

/// The runtime package's exposed modules, as its `elm.json` lists them.
pub const RUNTIME_MODULES: [&str; 25] = [
    "Rpc",
    "Rpc.Call",
    "Rpc.Code",
    "Rpc.Error",
    "Rpc.Transport",
    "Rpc.Retry",
    "Rpc.Trace",
    "Rpc.Body",
    "Rpc.Request",
    "Rpc.Response",
    "Proto.Http",
    "Proto.Message",
    "Proto.Field",
    "Proto.Enum",
    "Proto.EnumValue",
    "Proto.Method",
    "Proto.Registry",
    "Proto.WellKnown",
    "Proto.Any",
    "Proto.Json",
    "Proto.Int64",
    "Proto.Bytes",
    "Proto.Duration",
    "Proto.Timestamp",
    "Proto.Version",
];

/// The packages the runtime depends on, each with its exposed modules (at
/// elm/core 1.0.5, elm/json 1.1.3, elm/http 2.0.0, elm/time 1.0.0 and
/// elm/bytes 1.0.8). An application using generated code depends on them
/// too, elm/http and elm/json directly for the runtime's API.
pub const DEPENDENCY_MODULES: [(&str, &[&str]); 5] = [
    (
        "elm/core",
        &[
            "Array",
            "Basics",
            "Bitwise",
            "Char",
            "Debug",
            "Dict",
            "List",
            "Maybe",
            "Platform",
            "Platform.Cmd",
            "Platform.Sub",
            "Process",
            "Result",
            "Set",
            "String",
            "Task",
            "Tuple",
        ],
    ),
    ("elm/json", &["Json.Decode", "Json.Encode"]),
    ("elm/http", &["Http"]),
    ("elm/time", &["Time"]),
    ("elm/bytes", &["Bytes", "Bytes.Decode", "Bytes.Encode"]),
];

/// The package that already has a module named `module`, the runtime or
/// one it depends on: an application cannot define a module of that
/// name, since every import of it would be ambiguous.
pub fn reserved_module(module: &str) -> Option<&'static str> {
    if RUNTIME_MODULES.contains(&module) {
        return Some(concat!("the runtime package ", runtime_package!()));
    }
    DEPENDENCY_MODULES
        .iter()
        .find(|(_, modules)| modules.contains(&module))
        .map(|(package, _)| *package)
}

/// The segment of `module` that is a device name Windows reserves as a
/// file name, in any case and with any extension (`CON`, `PRN`, `AUX`,
/// `NUL`, `COM1` to `COM9`, `LPT1` to `LPT9`): a module `Notes.V1.Con`
/// is written to `Notes/V1/Con.elm`, which Windows cannot create and git
/// refuses to check out there.
pub fn windows_device_segment(module: &str) -> Option<&str> {
    module.split('.').find(|segment| {
        let upper = segment.to_ascii_uppercase();
        match upper.as_bytes() {
            [a, b, c] => matches!(&[*a, *b, *c], b"CON" | b"PRN" | b"AUX" | b"NUL"),
            [a, b, c, digit] => {
                matches!(&[*a, *b, *c], b"COM" | b"LPT") && (b'1'..=b'9').contains(digit)
            }
            _ => false,
        }
    })
}

/// The runtime package's namespaces: the module names it may take in any
/// release, a minor or patch one included (design §8.3). A generated
/// module named for one of them or inside one is the user's risk.
pub const RUNTIME_NAMESPACES: [&str; 2] = ["Rpc", "Proto"];

/// Whether `module` is one of [`RUNTIME_NAMESPACES`] or inside one
/// (`Proto`, `Rpc.V1`, `Proto.Notes.V1`).
pub fn in_runtime_namespace(module: &str) -> bool {
    RUNTIME_NAMESPACES.iter().any(|root| {
        module
            .strip_prefix(root)
            .is_some_and(|rest| rest.is_empty() || rest.starts_with('.'))
    })
}

/// The elm/* packages an application commonly depends on beside the
/// runtime, each with its exposed modules (at elm/html 1.0.1,
/// elm/browser 1.0.2, elm/url 1.0.0, elm/svg 1.0.1, elm/file 1.0.5,
/// elm/random 1.0.0, elm/regex 1.0.0, elm/parser 1.1.0 and
/// elm/virtual-dom 1.0.5). Generated code imports none of them, so a
/// generated module of the same name compiles, but an application that
/// depends on its package cannot import it: the import is ambiguous.
pub const APPLICATION_MODULES: [(&str, &[&str]); 9] = [
    (
        "elm/html",
        &[
            "Html",
            "Html.Attributes",
            "Html.Events",
            "Html.Keyed",
            "Html.Lazy",
        ],
    ),
    (
        "elm/browser",
        &[
            "Browser",
            "Browser.Dom",
            "Browser.Events",
            "Browser.Navigation",
        ],
    ),
    (
        "elm/url",
        &["Url", "Url.Builder", "Url.Parser", "Url.Parser.Query"],
    ),
    (
        "elm/svg",
        &[
            "Svg",
            "Svg.Attributes",
            "Svg.Events",
            "Svg.Keyed",
            "Svg.Lazy",
        ],
    ),
    ("elm/file", &["File", "File.Select", "File.Download"]),
    ("elm/random", &["Random"]),
    ("elm/regex", &["Regex"]),
    ("elm/parser", &["Parser", "Parser.Advanced"]),
    ("elm/virtual-dom", &["VirtualDom"]),
];

/// The package among [`APPLICATION_MODULES`] that has a module named
/// `module`, which a generated module of that name shadows for an
/// application depending on it.
pub fn shadowed_module(module: &str) -> Option<&'static str> {
    APPLICATION_MODULES
        .iter()
        .find(|(_, modules)| modules.contains(&module))
        .map(|(package, _)| *package)
}

/// Why a proto name has no Elm spelling.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum NameError {
    /// The proto file declares no package, so there is no module name.
    EmptyPackage,
    /// A package segment does not start with a letter once its
    /// underscores are dropped (`1v`, `_2`), which every Elm module segment
    /// must.
    InvalidSegment {
        /// The offending proto package segment.
        segment: String,
    },
    /// The converted name is empty: the proto name was only underscores.
    Empty,
    /// The converted name starts with something other than the letter case
    /// Elm requires: a type or constructor name must start with an uppercase
    /// letter, a field name with a lowercase one.
    WrongStart {
        /// The converted name.
        converted: String,
    },
}

/// The Elm module for a proto package: each `.`-separated segment in
/// PascalCase (`notes.v1` becomes `Notes.V1`, `foo_bar.v2beta1` becomes
/// `FooBar.V2beta1`).
pub fn module_name(package: &str) -> Result<ModuleName, NameError> {
    if package.is_empty() {
        return Err(NameError::EmptyPackage);
    }
    let mut segments = Vec::new();
    for segment in package.split('.') {
        let converted = pascal_case(segment);
        if ModuleName::new(vec![converted.clone()]).is_none() {
            return Err(NameError::InvalidSegment {
                segment: segment.to_owned(),
            });
        }
        segments.push(converted);
    }
    ModuleName::new(segments).ok_or(NameError::EmptyPackage)
}

/// The Elm type name for a message or enum, given its proto name and the
/// names of the messages enclosing it, outermost first: each in PascalCase,
/// joined (`["Outer", "Inner"]` becomes `OuterInner`).
pub fn type_name(nested_path: &[&str]) -> Result<String, NameError> {
    let converted: String = nested_path.iter().map(|name| pascal_case(name)).collect();
    check_upper(converted)
}

/// The Elm type name for a message or enum nested in a message whose Elm
/// name is `enclosing_elm_name`: that name followed by the proto name in
/// PascalCase. Without renames it is [`type_name`] of the whole path
/// (`OuterInner`); with one, it follows the enclosing message's new name
/// (`Shell` + `Inner` becomes `ShellInner`).
pub fn nested_type_name(enclosing_elm_name: &str, proto_name: &str) -> String {
    format!("{enclosing_elm_name}{}", pascal_case(proto_name))
}

/// The Elm record field name for a proto field (or oneof) name.
///
/// The conversion starts with protoc's default `json_name` rule, applied
/// to the proto name and never to an explicit `json_name`: drop each
/// underscore and capitalise the letter after it (`display_name` becomes
/// `displayName`). Then the leading run of uppercase letters is
/// lowercased, except that a run followed by a lowercase letter keeps its
/// last letter, which starts the next word (`Label` becomes `label`, `ID`
/// `id`, `URLPath` `urlPath`, `XCoord` `xCoord`). A run followed by a lone `s` is a
/// plural acronym and is lowercased with it (`IDs` becomes `ids`, `URLs`
/// `urls`), at the cost of `XIs` becoming `xis`. An Elm reserved
/// word gains a trailing underscore (`Type` becomes `type_`). A name with
/// no letter before its first digit (`_1x`) or with nothing but
/// underscores has no Elm name.
pub fn field_name(proto_name: &str) -> Result<String, NameError> {
    let mut converted = String::with_capacity(proto_name.len());
    let mut capitalise_next = false;
    for c in proto_name.chars() {
        if c == '_' {
            capitalise_next = true;
        } else if capitalise_next {
            converted.push(c.to_ascii_uppercase());
            capitalise_next = false;
        } else {
            converted.push(c);
        }
    }
    let converted = lower_leading_run(&converted);
    match converted.chars().next() {
        None => Err(NameError::Empty),
        Some(first) if !first.is_ascii_lowercase() => Err(NameError::WrongStart { converted }),
        Some(_) if ELM_RESERVED_WORDS.contains(&converted.as_str()) => Ok(converted + "_"),
        Some(_) => Ok(converted),
    }
}

/// The constructor for an enum value: the enum's Elm name followed by the
/// value name in PascalCase, with the conventional prefix stripped.
/// `enum_path` is the enum's proto name after the names of the messages
/// enclosing it, outermost first (`["Note", "Kind"]`).
///
/// The prefix is the enum's own proto name in `UPPER_SNAKE_CASE`, so
/// `Status` + `STATUS_ACTIVE` and `Status` + `ACTIVE` both become
/// `StatusActive`, or, for a nested enum, its whole path, so the values
/// `NOTE_KIND_DRAFT` and `KIND_DRAFT` of `Note.Kind` both become
/// `NoteKindDraft`; the longer of the two that the value starts with is
/// stripped. A prefix is matched word by word, ignoring case and
/// underscores, so `HttpMethod` + `HTTP_METHOD_GET` becomes
/// `HttpMethodGet`. A value that is nothing but the prefix keeps it. A
/// value name without lowercase letters (the proto convention) is
/// lowercased before casing, so `STATUS_ACTIVE` gives `Active`, not
/// `ACTIVE`.
pub fn enum_constructor(enum_elm_name: &str, enum_path: &[&str], value_name: &str) -> String {
    let own = enum_path.last().copied().unwrap_or_default();
    let by_path = strip_enum_prefix(&enum_path.concat(), value_name);
    let stripped = if by_path.len() < value_name.len() {
        by_path
    } else {
        strip_enum_prefix(own, value_name)
    };
    let value = if stripped.chars().any(|c| c.is_ascii_lowercase()) {
        pascal_case(stripped)
    } else {
        pascal_case(&stripped.to_ascii_lowercase())
    };
    format!("{enum_elm_name}{value}")
}

/// The custom type for a oneof: the message's Elm name followed by the
/// oneof name in PascalCase (`NoteEvent` + `kind` becomes `NoteEventKind`).
pub fn oneof_type_name(message_elm_name: &str, oneof_name: &str) -> String {
    format!("{message_elm_name}{}", pascal_case(oneof_name))
}

/// The constructor for one member of a oneof: the oneof's type name
/// followed by the field name in PascalCase (`NoteEventKind` + `created`
/// becomes `NoteEventKindCreated`).
pub fn oneof_variant_constructor(oneof_type_name: &str, field_name: &str) -> String {
    format!("{oneof_type_name}{}", pascal_case(field_name))
}

/// The constructor for a oneof's unset case: the oneof's type name followed
/// by `Unset`.
pub fn oneof_unset_constructor(oneof_type_name: &str) -> String {
    format!("{oneof_type_name}Unset")
}

/// The wrapper type of a recursive message, which is also its only
/// constructor: the message's Elm name followed by an underscore
/// (`Node` becomes `Node_`). No other generated type or constructor ends in
/// an underscore, since [`pascal_case`] drops every one, so the name is
/// free in both namespaces.
pub fn recursive_wrapper(message_elm_name: &str) -> String {
    format!("{message_elm_name}_")
}

/// The JSON encoder for a generated type: `encode` followed by the type's
/// Elm name (`Note` becomes `encodeNote`). Type names are unique within a
/// module, so encoder names are too.
pub fn encoder_name(type_elm_name: &str) -> String {
    format!("encode{type_elm_name}")
}

/// The JSON decoder for a generated type: `decode` followed by the type's
/// Elm name (`Note` becomes `decodeNote`). Type names are unique within a
/// module, so decoder names are too.
pub fn decoder_name(type_elm_name: &str) -> String {
    format!("decode{type_elm_name}")
}

/// The value holding every field of a message at its proto3 default:
/// `default` followed by the message's Elm name (`Note` becomes
/// `defaultNote`).
///
/// The top-level values of a generated module share one namespace, and
/// each is a prefix (`encode`, `decode`, `default`, `message`, `enum`)
/// followed by a type name. Type names are unique within a module and
/// start with an uppercase letter, and no prefix is another's, so two such
/// names never collide: neither within one prefix nor across two. (A
/// suffix would not do: `encodeFooMessage` would be both the encoder of
/// `FooMessage` and the record of `EncodeFoo`.)
pub fn default_name(type_elm_name: &str) -> String {
    format!("{DEFAULT_PREFIX}{type_elm_name}")
}

/// The prefix of [`default_name`].
const DEFAULT_PREFIX: &str = "default";

/// The typed value of a message (`Proto.Message.Message`): `message`
/// followed by the message's Elm name (`Note` becomes `messageNote`).
/// Like [`default_name`], a prefix and a type name.
pub fn message_value_name(type_elm_name: &str) -> String {
    format!("{MESSAGE_PREFIX}{type_elm_name}")
}

/// The prefix of [`message_value_name`].
const MESSAGE_PREFIX: &str = "message";

/// The typed value of an enum (`Proto.Enum.Enum`): `enum` followed by the
/// enum's Elm name (`Status` becomes `enumStatus`). Like
/// [`default_name`], a prefix and a type name.
pub fn enum_value_name(type_elm_name: &str) -> String {
    format!("{ENUM_PREFIX}{type_elm_name}")
}

/// The prefix of [`enum_value_name`].
const ENUM_PREFIX: &str = "enum";

/// The module of a message's or an enum's descriptor: its package's
/// module followed by its Elm type name (`Note` in `Notes.V1` becomes
/// `Notes.V1.Note`, a nested `Outer.Inner` becomes `Notes.V1.OuterInner`).
/// The package's module holds the values a program sends and receives;
/// this one holds what the proto says about the type, and imports nothing
/// of the package's module, so the package's module can import it.
pub fn descriptor_module(package_module: &ModuleName, type_elm_name: &str) -> ModuleName {
    let mut segments = package_module.segments().to_vec();
    segments.push(type_elm_name.to_owned());
    ModuleName::new(segments).expect("a type name is a valid module segment")
}

/// The value of a type's descriptor in its [`descriptor_module`]:
/// `Notes.V1.Note.descriptor`. It is the one value the generator adds to
/// a descriptor module whose name a field could take; a field of that
/// name takes `descriptor_` instead ([`field_value_name`]). Any value
/// added to descriptor modules later ends in `_`, which a field's name
/// does only as a reserved word's escape (`type_`) or as this one's
/// (design §3.1).
pub const DESCRIPTOR_VALUE: &str = "descriptor";

/// The Elm value of a field's descriptor in its message's
/// [`descriptor_module`], from the field's record field name: the same
/// name, but [`DESCRIPTOR_VALUE`], which the message's own descriptor
/// holds, gains a trailing underscore (`descriptor_`).
pub fn field_value_name(elm_name: &str) -> String {
    if elm_name == DESCRIPTOR_VALUE {
        format!("{elm_name}_")
    } else {
        elm_name.to_owned()
    }
}

/// The Elm value of a oneof member's descriptor in its message's
/// [`descriptor_module`]: its proto name converted as a field's is
/// ([`field_name`]), and `descriptor` escaped as [`field_value_name`]
/// escapes a field's (`created`, `a_b`, `Text` and `URL` become `created`,
/// `aB`, `text` and `url`, `_legacy` becomes `legacy`). A member is a
/// field of its message, so its descriptor is named as a field of that
/// name would be, whatever its constructor ends with. It follows the proto
/// name: a member's `rename` renames its constructor, not this.
pub fn member_value_name(proto_name: &str) -> Result<String, NameError> {
    field_name(proto_name).map(|name| field_value_name(&name))
}

/// The prefix the descriptor of a method takes.
const DESCRIPTOR_PREFIX: &str = "descriptor";

/// The descriptor of a method (`Proto.Method.Descriptor`), in
/// its service's module: `descriptor` followed by the method's Elm name
/// with its first letter uppercased, as [`pascal_case`] does (`getNote`
/// becomes `descriptorGetNote`). It follows the Elm name, so a renamed
/// method's descriptor is renamed with it. A service's module holds only
/// its methods' calls and descriptors, so it collides only with the call of
/// a method named for it (`DescriptorGetNote`), which is
/// `naming::value_collision`.
pub fn method_descriptor_name(method_elm_name: &str) -> String {
    let mut chars = method_elm_name.chars();
    let upper: String = chars
        .next()
        .map(|first| first.to_ascii_uppercase())
        .into_iter()
        .chain(chars)
        .collect();
    format!("{DESCRIPTOR_PREFIX}{upper}")
}

/// The value holding a package's descriptors and those of every package
/// it imports (`Proto.Registry.Registry`). Every other top-level value of a
/// package module is a prefix and a type name, whose first letter is
/// uppercase, so an all-lowercase name cannot be one of them.
pub const REGISTRY: &str = "registry";

/// The value every generated module defines, naming the `Proto.Version`
/// value of the release that generated it (design §8). Its trailing
/// underscore marks it as the generator's own, as with a recursive
/// message's wrapper (`Node_`): a derived value name drops underscores,
/// and only the reserved-word escape adds one, so no proto name derives to
/// it, and a `rename` to a value cannot end in `_`.
pub const VERSION_VALUE: &str = "elmConnectVersion_";

/// The parameter an encoder binds the value it encodes to. Elm rejects a
/// local name that shadows a top-level one, so no top-level value of a
/// generated module may take this name; every top-level name generated
/// today starts with one of the prefixes [`default_name`] lists, or is
/// [`REGISTRY`] or [`VERSION_VALUE`], or is a method's.
pub const ENCODER_ARGUMENT: &str = "value";

/// The variable a oneof's encoder binds the value of the set member to, in
/// each branch of its `case`. Like [`ENCODER_ARGUMENT`], it must not be
/// the name of a top-level value of a generated module.
pub const ONEOF_MEMBER: &str = "member";

/// The Elm value for an RPC method: its name converted as a field's is
/// ([`field_name`]), so `GetNote` becomes `getNote`, `get_note` `getNote`,
/// `HTTPGet` `httpGet` and `Type` `type_`.
pub fn method_name(proto_name: &str) -> Result<String, NameError> {
    field_name(proto_name)
}

/// The Elm module for a service: its package's module followed by the
/// service name in PascalCase, as a package segment is converted
/// (`NotesService` in `notes.v1` becomes `Notes.V1.NotesService`). Each
/// service gets a module of its own, so its methods share a namespace only
/// with each other.
pub fn service_module(
    package_module: &ModuleName,
    service_proto_name: &str,
) -> Result<ModuleName, NameError> {
    let mut segments = package_module.segments().to_vec();
    segments.push(pascal_case(service_proto_name));
    ModuleName::new(segments).ok_or_else(|| NameError::InvalidSegment {
        segment: service_proto_name.to_owned(),
    })
}

/// PascalCase of one proto identifier: drop underscores and uppercase the
/// first letter of every underscore-separated word, leaving the rest of
/// each word as written (`foo_bar` becomes `FooBar`, `HTTPRequest` stays).
pub fn pascal_case(name: &str) -> String {
    name.split('_')
        .flat_map(|word| {
            let mut chars = word.chars();
            chars
                .next()
                .map(|first| first.to_ascii_uppercase())
                .into_iter()
                .chain(chars)
        })
        .collect()
}

/// `name` with its leading run of ASCII uppercase letters lowercased,
/// except the run's last letter when a lowercase letter follows it. A run
/// of two or more followed by a lone `s` (then the end, an uppercase
/// letter, a digit or `_`) is a plural acronym, lowercased with its `s`
/// (`IDs` becomes `ids`, `URLsSeen` `urlsSeen`), so `XIs` becomes `xis`.
fn lower_leading_run(name: &str) -> String {
    let bytes = name.as_bytes();
    let run = bytes.iter().take_while(|b| b.is_ascii_uppercase()).count();
    let followed_by_lower = bytes.get(run).is_some_and(u8::is_ascii_lowercase);
    let plural = run > 1
        && bytes.get(run) == Some(&b's')
        && bytes
            .get(run + 1)
            .is_none_or(|&b| b.is_ascii_uppercase() || b.is_ascii_digit() || b == b'_');
    let lowered = if plural {
        run + 1
    } else if run > 1 && followed_by_lower {
        run - 1
    } else {
        run
    };
    let (head, tail) = name.split_at(lowered);
    head.to_ascii_lowercase() + tail
}

fn starts_with_upper(name: &str) -> bool {
    name.starts_with(|c: char| c.is_ascii_uppercase())
}

fn check_upper(converted: String) -> Result<String, NameError> {
    if converted.is_empty() {
        Err(NameError::Empty)
    } else if starts_with_upper(&converted) {
        Ok(converted)
    } else {
        Err(NameError::WrongStart { converted })
    }
}

/// `value_name` without `prefix` in `UPPER_SNAKE_CASE` and the underscore
/// after it, when it has it and something follows it.
fn strip_enum_prefix<'a>(prefix: &str, value_name: &'a str) -> &'a str {
    let target: String = prefix
        .chars()
        .filter(|&c| c != '_')
        .map(|c| c.to_ascii_uppercase())
        .collect();
    let mut seen = String::new();
    for (index, c) in value_name.char_indices() {
        if c == '_' {
            if seen == target {
                let rest = value_name[index..].trim_start_matches('_');
                return if rest.is_empty() { value_name } else { rest };
            }
            if seen.len() > target.len() {
                break;
            }
        } else {
            seen.push(c.to_ascii_uppercase());
        }
    }
    value_name
}

#[cfg(test)]
mod tests {
    use super::*;

    use std::collections::BTreeSet;

    #[test]
    fn the_runtime_modules_are_the_packages_exposed_modules() {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../elm.json");
        let text = std::fs::read_to_string(path).expect("the runtime's elm.json");
        let elm_json: serde_json::Value = serde_json::from_str(&text).expect("JSON");
        let exposed: Vec<&str> = elm_json["exposed-modules"]
            .as_array()
            .expect("a list of exposed modules")
            .iter()
            .map(|module| module.as_str().expect("a module name"))
            .collect();
        assert_eq!(exposed, RUNTIME_MODULES);
        let dependencies: BTreeSet<&str> = elm_json["dependencies"]
            .as_object()
            .expect("dependencies")
            .keys()
            .map(String::as_str)
            .collect();
        let reserved: BTreeSet<&str> = DEPENDENCY_MODULES.iter().map(|(p, _)| *p).collect();
        assert_eq!(dependencies, reserved);
    }

    #[test]
    fn reserved_modules_name_their_package() {
        assert_eq!(reserved_module("Time"), Some("elm/time"));
        assert_eq!(reserved_module("Bytes.Encode"), Some("elm/bytes"));
        assert_eq!(reserved_module("Json.Decode"), Some("elm/json"));
        assert_eq!(
            reserved_module("Proto.Json"),
            Some("the runtime package bruckner/elm-connect")
        );
        assert_eq!(reserved_module("Rpc"), reserved_module("Proto.Json"));
        assert_eq!(
            reserved_module("Proto.Field"),
            reserved_module("Proto.Json")
        );
        assert_eq!(
            reserved_module("Proto.EnumValue"),
            reserved_module("Proto.Json")
        );
        assert_eq!(reserved_module("Proto.Descriptor"), None);
        assert_eq!(reserved_module("Notes.V1"), None);
        assert_eq!(reserved_module("Proto.Notes"), None);
        assert_eq!(reserved_module("Html"), None);
    }

    #[test]
    fn windows_device_names_are_found_in_any_segment() {
        assert_eq!(windows_device_segment("Notes.V1.Con"), Some("Con"));
        assert_eq!(windows_device_segment("Shop.Aux.V1"), Some("Aux"));
        assert_eq!(windows_device_segment("NUL"), Some("NUL"));
        assert_eq!(windows_device_segment("A.Com1"), Some("Com1"));
        assert_eq!(windows_device_segment("A.LPT9.B"), Some("LPT9"));
        for module in [
            "Notes.V1",
            "A.Com0",
            "A.Com10",
            "A.Console",
            "A.Conn",
            "A.Lpt",
        ] {
            assert_eq!(windows_device_segment(module), None, "{module}");
        }
    }

    #[test]
    fn the_runtime_namespaces_hold_its_modules() {
        for module in RUNTIME_MODULES {
            assert!(in_runtime_namespace(module), "{module}");
        }
        for module in ["Proto", "Rpc", "Rpc.V1", "Proto.Notes", "Proto.Notes.V1"] {
            assert!(in_runtime_namespace(module), "{module}");
        }
        for module in ["Protocol", "Rpcs.V1", "Notes.Proto", "Api.Rpc"] {
            assert!(!in_runtime_namespace(module), "{module}");
        }
    }

    #[test]
    fn shadowed_modules_name_their_package() {
        assert_eq!(shadowed_module("Html"), Some("elm/html"));
        assert_eq!(shadowed_module("Url.Parser.Query"), Some("elm/url"));
        assert_eq!(shadowed_module("VirtualDom"), Some("elm/virtual-dom"));
        assert_eq!(shadowed_module("Html.V1"), None);
        assert_eq!(shadowed_module("Time"), None);
        for (_, modules) in APPLICATION_MODULES {
            for module in modules {
                assert_eq!(reserved_module(module), None, "{module}");
                assert!(ModuleName::parse(module).is_some(), "{module}");
            }
        }
    }

    #[test]
    fn codec_names() {
        assert_eq!(encoder_name("OuterInner"), "encodeOuterInner");
        assert_eq!(decoder_name("OuterInner"), "decodeOuterInner");
        assert_eq!(default_name("OuterInner"), "defaultOuterInner");
        assert_eq!(message_value_name("OuterInner"), "messageOuterInner");
        assert_eq!(enum_value_name("OuterInner"), "enumOuterInner");
        assert_eq!(
            descriptor_module(&ModuleName::parse("Notes.V1").unwrap(), "OuterInner").to_string(),
            "Notes.V1.OuterInner"
        );
        assert_eq!(member_value_name("legal_name"), Ok("legalName".into()));
        assert_eq!(member_value_name("a_b"), Ok("aB".into()));
        assert_eq!(member_value_name("Text"), Ok("text".into()));
        assert_eq!(member_value_name("type"), Ok("type_".into()));
        assert_eq!(member_value_name("descriptor"), Ok("descriptor_".into()));
        assert_eq!(member_value_name("_legacy"), Ok("legacy".into()));
        assert_eq!(member_value_name("__old_name"), Ok("oldName".into()));
        assert_eq!(member_value_name("x_1"), Ok("x1".into()));
        assert_eq!(member_value_name("URL"), Ok("url".into()));
        assert!(member_value_name("_1x").is_err());
        assert_eq!(field_value_name("descriptor"), "descriptor_");
        assert_eq!(field_value_name("descriptors"), "descriptors");
        assert_eq!(field_value_name("type_"), "type_");
        assert_eq!(method_descriptor_name("getNote"), "descriptorGetNote");
        assert_eq!(method_descriptor_name("type_"), "descriptorType_");
        assert_eq!(method_descriptor_name("httpGet"), "descriptorHttpGet");
        assert!(method_descriptor_name("getNote").starts_with(DESCRIPTOR_PREFIX));
        let prefixes = [
            "encode",
            "decode",
            DEFAULT_PREFIX,
            MESSAGE_PREFIX,
            ENUM_PREFIX,
            DESCRIPTOR_PREFIX,
        ];
        for local in [ENCODER_ARGUMENT, ONEOF_MEMBER] {
            assert!(prefixes.iter().all(|prefix| !local.starts_with(prefix)));
        }
        for (i, a) in prefixes.iter().enumerate() {
            for b in &prefixes[i + 1..] {
                assert!(!a.starts_with(b) && !b.starts_with(a), "{a} and {b}");
            }
        }
        assert_ne!(ENCODER_ARGUMENT, ONEOF_MEMBER);
        for name in [ENCODER_ARGUMENT, ONEOF_MEMBER, REGISTRY] {
            assert!(prefixes.iter().all(|prefix| !name.starts_with(prefix)));
            assert_eq!(name, name.to_ascii_lowercase());
        }
        assert!(![ENCODER_ARGUMENT, ONEOF_MEMBER].contains(&REGISTRY));
        assert!(
            prefixes
                .iter()
                .all(|prefix| !VERSION_VALUE.starts_with(prefix))
        );
        assert!(![ENCODER_ARGUMENT, ONEOF_MEMBER, REGISTRY].contains(&VERSION_VALUE));
    }

    #[test]
    fn module_names() {
        let cases = [
            ("notes.v1", "Notes.V1"),
            ("foo_bar.v2beta1", "FooBar.V2beta1"),
            ("acme", "Acme"),
            ("acme.Notes.v1", "Acme.Notes.V1"),
            ("a.b.c", "A.B.C"),
            ("_x.y", "X.Y"),
        ];
        for (package, expected) in cases {
            let module = module_name(package).unwrap_or_else(|e| panic!("{package}: {e:?}"));
            assert_eq!(module.to_string(), expected, "{package}");
        }
    }

    #[test]
    fn module_name_errors() {
        let cases = [
            ("", NameError::EmptyPackage),
            (
                "notes.1v",
                NameError::InvalidSegment {
                    segment: "1v".into(),
                },
            ),
            (
                "_1.x",
                NameError::InvalidSegment {
                    segment: "_1".into(),
                },
            ),
        ];
        for (package, expected) in cases {
            assert_eq!(module_name(package), Err(expected), "{package}");
        }
    }

    #[test]
    fn type_names() {
        let cases: [(&[&str], &str); 6] = [
            (&["Note"], "Note"),
            (&["Outer", "Inner"], "OuterInner"),
            (&["note_event"], "NoteEvent"),
            (&["HTTPRequest"], "HTTPRequest"),
            (&["outer", "inner_thing"], "OuterInnerThing"),
            (&["A", "B", "C"], "ABC"),
        ];
        for (path, expected) in cases {
            assert_eq!(type_name(path).as_deref(), Ok(expected), "{path:?}");
        }
    }

    #[test]
    fn type_name_errors() {
        assert_eq!(type_name(&["_"]), Err(NameError::Empty));
        assert_eq!(
            type_name(&["_1x"]),
            Err(NameError::WrongStart {
                converted: "1x".into()
            })
        );
    }

    #[test]
    fn field_names() {
        let cases = [
            ("name", "name"),
            ("display_name", "displayName"),
            ("fooBar", "fooBar"),
            ("foo_bar", "fooBar"),
            ("foo__bar", "fooBar"),
            ("foo_", "foo"),
            ("_foo", "foo"),
            ("x_1", "x1"),
            ("http_url", "httpUrl"),
            ("type", "type_"),
            ("module", "module_"),
            ("port", "port_"),
            ("alias", "alias"),
            ("infix", "infix"),
            ("as", "as_"),
            ("types", "types"),
        ];
        for (proto, expected) in cases {
            assert_eq!(field_name(proto).as_deref(), Ok(expected), "{proto}");
        }
    }

    #[test]
    fn leading_uppercase_runs_are_lowercased() {
        let cases = [
            ("Label", "label"),
            ("ID", "id"),
            ("URL", "url"),
            ("URLPath", "urlPath"),
            ("HTTPRequest", "httpRequest"),
            ("XCoord", "xCoord"),
            ("ABCDef", "abcDef"),
            ("_internal", "internal"),
            ("__Label", "label"),
            ("display_name", "displayName"),
            ("Type", "type_"),
            ("V2", "v2"),
            // A run followed by a lone `s` is a plural acronym.
            ("IDs", "ids"),
            ("URLs", "urls"),
            ("APIs", "apis"),
            ("UUIDs", "uuids"),
            ("IDsSeen", "idsSeen"),
            ("IDs2", "ids2"),
            ("IDsseen", "iDsseen"),
            ("XIs", "xis"),
            ("Is", "is"),
        ];
        for (proto, expected) in cases {
            assert_eq!(field_name(proto).as_deref(), Ok(expected), "{proto}");
        }
    }

    #[test]
    fn field_name_errors() {
        assert_eq!(field_name("_"), Err(NameError::Empty));
        assert_eq!(field_name("__"), Err(NameError::Empty));
        assert_eq!(
            field_name("_1"),
            Err(NameError::WrongStart {
                converted: "1".into()
            })
        );
        assert_eq!(
            field_name("_1x"),
            Err(NameError::WrongStart {
                converted: "1x".into()
            })
        );
    }

    #[test]
    fn every_reserved_word_is_escaped() {
        for word in ELM_RESERVED_WORDS {
            assert_eq!(field_name(word), Ok(format!("{word}_")));
        }
    }

    #[test]
    fn enum_constructors() {
        let cases: [(&str, &[&str], &str, &str); 19] = [
            ("Status", &["Status"], "STATUS_ACTIVE", "StatusActive"),
            ("Status", &["Status"], "ACTIVE", "StatusActive"),
            (
                "Status",
                &["Status"],
                "STATUS_UNSPECIFIED",
                "StatusUnspecified",
            ),
            ("Status", &["Status"], "STATUS", "StatusStatus"),
            ("Status", &["Status"], "STATUSES_ON", "StatusStatusesOn"),
            (
                "HttpMethod",
                &["HttpMethod"],
                "HTTP_METHOD_GET",
                "HttpMethodGet",
            ),
            ("HttpMethod", &["HttpMethod"], "GET", "HttpMethodGet"),
            (
                "HTTPMethod",
                &["HTTPMethod"],
                "HTTPMETHOD_GET",
                "HTTPMethodGet",
            ),
            ("NoteKind", &["Note", "Kind"], "KIND_DRAFT", "NoteKindDraft"),
            (
                "NoteKind",
                &["Note", "Kind"],
                "NOTE_KIND_DRAFT",
                "NoteKindDraft",
            ),
            ("NoteKind", &["Note", "Kind"], "DRAFT", "NoteKindDraft"),
            (
                "NoteKind",
                &["Note", "Kind"],
                "NOTE_KIND",
                "NoteKindNoteKind",
            ),
            (
                "NoteKind",
                &["Note", "Kind"],
                "NOTE_DRAFT",
                "NoteKindNoteDraft",
            ),
            (
                "OuterInnerKind",
                &["Outer", "Inner", "Kind"],
                "OUTER_INNER_KIND_DRAFT",
                "OuterInnerKindDraft",
            ),
            (
                "OuterInnerKind",
                &["Outer", "Inner", "Kind"],
                "INNER_KIND_DRAFT",
                "OuterInnerKindInnerKindDraft",
            ),
            ("KindKind", &["Kind", "Kind"], "KIND_KIND_ON", "KindKindOn"),
            ("Color", &["Color"], "COLOR_LIGHT_BLUE", "ColorLightBlue"),
            ("Color", &["Color"], "lightBlue", "ColorLightBlue"),
            ("Color", &["Color"], "COLOR_2D", "Color2d"),
        ];
        for (elm, path, value, expected) in cases {
            assert_eq!(enum_constructor(elm, path, value), expected, "{value}");
        }
    }

    #[test]
    fn method_names() {
        let cases = [
            ("GetNote", "getNote"),
            ("getNote", "getNote"),
            ("get_note", "getNote"),
            ("HTTPGet", "httpGet"),
            ("_Ping", "ping"),
            ("Type", "type_"),
            ("V2Get", "v2Get"),
        ];
        for (proto, expected) in cases {
            assert_eq!(method_name(proto).as_deref(), Ok(expected), "{proto}");
        }
        assert_eq!(method_name("_"), Err(NameError::Empty));
        assert!(matches!(
            method_name("_1"),
            Err(NameError::WrongStart { .. })
        ));
    }

    #[test]
    fn service_modules() {
        let package = module_name("notes.v1").unwrap();
        let cases = [
            ("NotesService", "Notes.V1.NotesService"),
            ("notes", "Notes.V1.Notes"),
            ("notes_service", "Notes.V1.NotesService"),
            ("HTTPNotes", "Notes.V1.HTTPNotes"),
        ];
        for (service, expected) in cases {
            let module = service_module(&package, service).unwrap();
            assert_eq!(module.to_string(), expected, "{service}");
        }
        for service in ["_", "_1x"] {
            assert_eq!(
                service_module(&package, service),
                Err(NameError::InvalidSegment {
                    segment: service.into()
                }),
                "{service}"
            );
        }
    }

    #[test]
    fn recursive_wrappers() {
        assert_eq!(recursive_wrapper("Node"), "Node_");
        assert_eq!(encoder_name(&recursive_wrapper("Node")), "encodeNode_");
        assert!(!pascal_case("node_").ends_with('_'));
    }

    #[test]
    fn oneof_names() {
        let ty = oneof_type_name("NoteEvent", "kind");
        assert_eq!(ty, "NoteEventKind");
        assert_eq!(oneof_type_name("Note", "body_kind"), "NoteBodyKind");
        assert_eq!(
            oneof_variant_constructor(&ty, "created"),
            "NoteEventKindCreated"
        );
        assert_eq!(
            oneof_variant_constructor(&ty, "title_changed"),
            "NoteEventKindTitleChanged"
        );
        assert_eq!(oneof_unset_constructor(&ty), "NoteEventKindUnset");
    }

    #[test]
    fn pascal_cases() {
        let cases = [
            ("foo", "Foo"),
            ("foo_bar", "FooBar"),
            ("fooBar", "FooBar"),
            ("HTTPRequest", "HTTPRequest"),
            ("v2beta1", "V2beta1"),
            ("__x__y", "XY"),
            ("", ""),
        ];
        for (input, expected) in cases {
            assert_eq!(pascal_case(input), expected, "{input}");
        }
    }
}
