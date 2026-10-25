//! The generator's options (design §6): what a protoc plugin parameter or
//! the CLI's flags set.

use std::collections::{BTreeMap, BTreeSet};

use crate::diagnostics::{Diagnostics, Problem};
use crate::ir::ModuleName;

/// How to generate (design §6). The options design §6 lists that are not
/// here arrive with the features they control.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
#[non_exhaustive]
pub struct Options {
    /// How 64-bit integer fields are held (`int64=`), unless a field's
    /// `jstype` says otherwise (design §3.4).
    pub int64: Int64,
    /// How `bytes` fields are held (`bytes=`, design §3.4).
    pub bytes: Bytes,
    /// What a method without a `google.api.http` rule gets
    /// (`unbound_methods=`, design §4).
    pub unbound_methods: UnboundMethods,
    /// What a client, server or bidirectional streaming method gets
    /// (`streaming=`, design §3.8).
    pub streaming: Streaming,
    /// What an enum value the generated decoder does not know reads as
    /// (`enum_unknown=`, design §3.3).
    pub enum_unknown: EnumUnknown,
    /// The rename map (`rename=`, design §3.7): Elm names given by proto
    /// full name, each used in place of the name the naming rules would
    /// derive. [`Options::add_rename`] adds one; the IR builder checks
    /// each against the element it names.
    pub rename: BTreeMap<String, String>,
    /// The module every generated module goes inside (`module_prefix=`,
    /// design §3.1): with `Api`, `notes.v1` becomes `Api.Notes.V1`. The
    /// runtime's modules are not generated, so never prefixed.
    pub module_prefix: Option<ModuleName>,
    /// How the options are written where they were given, so that a
    /// diagnostic's help names an option the way its reader writes it.
    /// Not an option itself: each binary sets its own.
    pub spelling: Spelling,
}

/// How a front end's options are written.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Spelling {
    /// The protoc plugin's parameter: `rename=notes.v1.Note:Memo`.
    #[default]
    Parameter,
    /// The CLI's flags: `--rename notes.v1.Note:Memo`.
    Flags,
}

impl Spelling {
    /// The `rename` option for the proto element `proto`, with a
    /// placeholder for the Elm name, quoted: `` `rename=notes.v1.Note:<Elm
    /// name>` ``.
    pub fn rename(self, proto: &str) -> String {
        match self {
            Spelling::Parameter => format!("`rename={proto}:<Elm name>`"),
            Spelling::Flags => format!("`--rename {proto}:<Elm name>`"),
        }
    }

    /// The `rename` option giving `proto` the Elm name `elm`, quoted:
    /// `` `rename=notes.v1.Note.title:heading` ``.
    pub fn rename_to(self, proto: &str, elm: &str) -> String {
        match self {
            Spelling::Parameter => format!("`rename={proto}:{elm}`"),
            Spelling::Flags => format!("`--rename {proto}:{elm}`"),
        }
    }

    /// The `rename` option's name, quoted: `` `rename` `` or `` `--rename` ``.
    pub fn rename_key(self) -> &'static str {
        match self {
            Spelling::Parameter => "`rename`",
            Spelling::Flags => "`--rename`",
        }
    }

    /// The option `key` set to `value`, quoted: `` `streaming=skip` `` or
    /// `` `--streaming skip` ``.
    pub fn option(self, key: &str, value: &str) -> String {
        match self {
            Spelling::Parameter => format!("`{key}={value}`"),
            Spelling::Flags => format!("`--{} {value}`", key.replace('_', "-")),
        }
    }

    /// The `module_prefix` option with a placeholder, quoted.
    pub fn module_prefix(self) -> &'static str {
        match self {
            Spelling::Parameter => "`module_prefix=<Elm module>`",
            Spelling::Flags => "`--module-prefix <Elm module>`",
        }
    }
}

impl Options {
    /// The options a protoc plugin parameter sets: comma-separated
    /// `key=value` pairs, such as `int64=int`, each option at most once
    /// but `rename`, which repeats. The empty parameter is the defaults.
    /// Every unknown key or value, repeated option and malformed `rename`
    /// or `module_prefix` is a problem (`options::*`), all of them
    /// reported together.
    pub fn from_parameter(parameter: &str) -> Result<Self, Diagnostics> {
        let mut options = Options::default();
        let mut problems = Diagnostics::new();
        let mut seen = BTreeSet::new();
        for pair in parameter
            .split(',')
            .map(str::trim)
            .filter(|p| !p.is_empty())
        {
            let Some((key, value)) = pair.split_once('=') else {
                problems.push(Problem::option_without_value(pair));
                continue;
            };
            let (key, value) = (key.trim(), value.trim());
            if !KEYS.contains(&key) {
                problems.push(Problem::unknown_option(key, &KEYS));
                continue;
            }
            if key != "rename" && !seen.insert(key.to_owned()) {
                problems.push(Problem::duplicate_option(key));
                continue;
            }
            let set = match key {
                "int64" => value_of(key, value, Int64::VALUES).map(|v| options.int64 = v),
                "bytes" => value_of(key, value, Bytes::VALUES).map(|v| options.bytes = v),
                "unbound_methods" => value_of(key, value, UnboundMethods::VALUES)
                    .map(|v| options.unbound_methods = v),
                "streaming" => {
                    value_of(key, value, Streaming::VALUES).map(|v| options.streaming = v)
                }
                "enum_unknown" => {
                    value_of(key, value, EnumUnknown::VALUES).map(|v| options.enum_unknown = v)
                }
                "rename" => options.add_rename(value),
                _ => parse_module_prefix(value).map(|v| options.module_prefix = Some(v)),
            };
            if let Err(problem) = set {
                problems.push(problem);
            }
        }
        if problems.is_empty() {
            Ok(options)
        } else {
            Err(problems)
        }
    }

    /// Adds one entry of the rename map, written `<proto full name>:<Elm
    /// name>` (`notes.v1.Note:Memo`). Neither side may be empty, and a
    /// proto name may be renamed once. Whether the Elm name suits what the
    /// proto name denotes is the IR builder's to check, since that needs
    /// the descriptors.
    pub fn add_rename(&mut self, entry: &str) -> Result<(), Problem> {
        let (proto, elm) = parse_rename(entry)?;
        if self.rename.contains_key(&proto) {
            return Err(Problem::duplicate_rename(&proto));
        }
        self.rename.insert(proto, elm);
        Ok(())
    }
}

impl Options {
    /// The options as a generated module's header records them, in the
    /// plugin parameter's form: each option not at its default as
    /// `key=value`, in the order of [`KEYS`], a `rename` once per entry
    /// in proto-name order. Empty for the defaults. An option given its
    /// default is left out, so a header written before an option existed
    /// still reads as that option's default.
    pub fn recorded(&self) -> Vec<String> {
        let mut pairs = Vec::new();
        let mut set = |key: &str, value: &str, default: &[&str]| {
            if default.first() != Some(&value) {
                pairs.push(format!("{key}={value}"));
            }
        };
        set("int64", self.int64.as_str(), Int64::VALUES);
        set("bytes", self.bytes.as_str(), Bytes::VALUES);
        set(
            "unbound_methods",
            self.unbound_methods.as_str(),
            UnboundMethods::VALUES,
        );
        set("streaming", self.streaming.as_str(), Streaming::VALUES);
        set(
            "enum_unknown",
            self.enum_unknown.as_str(),
            EnumUnknown::VALUES,
        );
        for (proto, elm) in &self.rename {
            pairs.push(format!("rename={proto}:{elm}"));
        }
        if let Some(prefix) = &self.module_prefix {
            pairs.push(format!("module_prefix={prefix}"));
        }
        pairs
    }
}

/// The value an option takes when it is not given, as written: `string`
/// for `int64`; `None` for `rename` and `module_prefix`, which are absent
/// unless given, and for a key that is no option.
pub fn default_value(key: &str) -> Option<&'static str> {
    let values = match key {
        "int64" => Int64::VALUES,
        "bytes" => Bytes::VALUES,
        "unbound_methods" => UnboundMethods::VALUES,
        "streaming" => Streaming::VALUES,
        "enum_unknown" => EnumUnknown::VALUES,
        _ => return None,
    };
    values.first().copied()
}

/// The plugin parameter's keys.
pub const KEYS: [&str; 7] = [
    "int64",
    "bytes",
    "unbound_methods",
    "streaming",
    "enum_unknown",
    "rename",
    "module_prefix",
];

/// The value of the option `key`, which takes `values`, parsed from
/// `value`.
fn value_of<T: std::str::FromStr>(key: &str, value: &str, values: &[&str]) -> Result<T, Problem> {
    value
        .parse()
        .map_err(|_| Problem::unknown_option_value(key, value, values))
}

/// One entry of the rename map, `<proto full name>:<Elm name>`, as its two
/// sides, trimmed: what [`Options::add_rename`] accepts.
pub fn parse_rename(entry: &str) -> Result<(String, String), Problem> {
    match entry.split_once(':') {
        Some((proto, elm)) if !proto.trim().is_empty() && !elm.trim().is_empty() => {
            Ok((proto.trim().to_owned(), elm.trim().to_owned()))
        }
        _ => Err(Problem::rename_form(entry)),
    }
}

/// A `module_prefix` value: dot-separated Elm module segments, each an
/// ASCII uppercase letter followed by ASCII letters, digits or
/// underscores, such as `Api.Notes`.
pub fn parse_module_prefix(value: &str) -> Result<ModuleName, Problem> {
    ModuleName::parse(value).ok_or_else(|| Problem::invalid_module_prefix(value))
}

/// How 64-bit integers (`int64`, `uint64`, `sint64`, `fixed64`,
/// `sfixed64`) are held in Elm (design §3.4).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Int64 {
    /// `String`, the decimal integer as proto3 JSON writes it: exact for
    /// every value.
    #[default]
    String,
    /// `Int`, exact within ±(2^53 − 1); a value outside that range fails
    /// to decode.
    Int,
}

impl Int64 {
    /// The values the option takes, as written, the default first.
    pub const VALUES: &'static [&'static str] = &["string", "int"];

    /// The value as written.
    pub fn as_str(self) -> &'static str {
        match self {
            Int64::String => "string",
            Int64::Int => "int",
        }
    }
}

impl std::str::FromStr for Int64 {
    type Err = String;

    fn from_str(value: &str) -> Result<Self, String> {
        match value {
            "string" => Ok(Int64::String),
            "int" => Ok(Int64::Int),
            _ => Err(format!("`int64` is `string` or `int`, not `{value}`")),
        }
    }
}

/// How `bytes` fields are held in Elm (design §3.4).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Bytes {
    /// `String`, the base64 text as proto3 JSON carries it, validated
    /// when decoded and kept as received.
    #[default]
    String,
    /// elm/bytes' `Bytes`, decoded from base64 and encoded as standard
    /// base64 with padding. Elm's `==` finds any two `Bytes` equal.
    Bytes,
}

impl Bytes {
    /// The values the option takes, as written, the default first.
    pub const VALUES: &'static [&'static str] = &["string", "bytes"];

    /// The value as written.
    pub fn as_str(self) -> &'static str {
        match self {
            Bytes::String => "string",
            Bytes::Bytes => "bytes",
        }
    }
}

impl std::str::FromStr for Bytes {
    type Err = String;

    fn from_str(value: &str) -> Result<Self, String> {
        match value {
            "string" => Ok(Bytes::String),
            "bytes" => Ok(Bytes::Bytes),
            _ => Err(format!("`bytes` is `string` or `bytes`, not `{value}`")),
        }
    }
}

/// What a method without a `google.api.http` rule gets (design §4).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum UnboundMethods {
    /// Generated like any other, with no bindings: the runtime calls it
    /// over the implicit route `POST /<package>.<Service>/<Method>`, which
    /// grpc-gateway (`generate_unbound_methods`), Envoy's transcoder
    /// (`auto_mapping`) and a Connect handler serve.
    #[default]
    Implicit,
    /// A diagnostic, `services::unbound_method`, for a server that serves
    /// rules alone.
    Error,
}

impl UnboundMethods {
    /// The values the option takes, as written, the default first.
    pub const VALUES: &'static [&'static str] = &["implicit", "error"];

    /// The value as written.
    pub fn as_str(self) -> &'static str {
        match self {
            UnboundMethods::Implicit => "implicit",
            UnboundMethods::Error => "error",
        }
    }
}

impl std::str::FromStr for UnboundMethods {
    type Err = String;

    fn from_str(value: &str) -> Result<Self, String> {
        match value {
            "implicit" => Ok(UnboundMethods::Implicit),
            "error" => Ok(UnboundMethods::Error),
            _ => Err(format!(
                "`unbound_methods` is `implicit` or `error`, not `{value}`"
            )),
        }
    }
}

/// What a streaming method gets (design §3.8). elm-connect generates unary
/// calls only.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Streaming {
    /// A diagnostic, `services::streaming`, failing the run.
    #[default]
    Error,
    /// Left out of its service's module, with a `services::streaming`
    /// warning; the rest is generated.
    Skip,
}

impl Streaming {
    /// The values the option takes, as written, the default first.
    pub const VALUES: &'static [&'static str] = &["error", "skip"];

    /// The value as written.
    pub fn as_str(self) -> &'static str {
        match self {
            Streaming::Error => "error",
            Streaming::Skip => "skip",
        }
    }
}

impl std::str::FromStr for Streaming {
    type Err = String;

    fn from_str(value: &str) -> Result<Self, String> {
        match value {
            "error" => Ok(Streaming::Error),
            "skip" => Ok(Streaming::Skip),
            _ => Err(format!("`streaming` is `error` or `skip`, not `{value}`")),
        }
    }
}

/// What an enum value the generated decoder does not know reads as
/// (design §3.3). An unknown number reads as the zero value either way.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum EnumUnknown {
    /// An unknown name fails the decode, as protobuf's own parsers do
    /// (`Proto.Json.enum`).
    #[default]
    Fail,
    /// An unknown name reads as the zero value too, so nothing an enum
    /// field receives fails (`Proto.Json.enumOrZero`): for clients that
    /// outlive the server's deploys.
    Zero,
}

impl EnumUnknown {
    /// The values the option takes, as written, the default first.
    pub const VALUES: &'static [&'static str] = &["fail", "zero"];

    /// The value as written.
    pub fn as_str(self) -> &'static str {
        match self {
            EnumUnknown::Fail => "fail",
            EnumUnknown::Zero => "zero",
        }
    }
}

impl std::str::FromStr for EnumUnknown {
    type Err = String;

    fn from_str(value: &str) -> Result<Self, String> {
        match value {
            "fail" => Ok(EnumUnknown::Fail),
            "zero" => Ok(EnumUnknown::Zero),
            _ => Err(format!("`enum_unknown` is `fail` or `zero`, not `{value}`")),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::diagnostics::Code;

    /// The message and help of every problem `parameter` gives, one line
    /// each.
    fn error(parameter: &str) -> String {
        Options::from_parameter(parameter)
            .unwrap_err()
            .iter()
            .map(|problem| format!("{} {}", problem.message(), problem.help_text()))
            .collect::<Vec<_>>()
            .join("\n")
    }

    /// The codes of the problems `parameter` gives.
    fn codes(parameter: &str) -> Vec<Code> {
        Options::from_parameter(parameter)
            .unwrap_err()
            .iter()
            .map(Problem::code)
            .collect()
    }

    /// The options `parameter` sets, or the message and help of its
    /// problems.
    fn parse(parameter: &str) -> Result<Options, String> {
        Options::from_parameter(parameter).map_err(|_| error(parameter))
    }

    #[test]
    fn options_come_from_a_plugin_parameter() {
        assert_eq!(parse(""), Ok(Options::default()));
        assert_eq!(parse("int64=int").map(|o| o.int64), Ok(Int64::Int));
        assert_eq!(
            parse(" int64 = string ,").map(|o| o.int64),
            Ok(Int64::String)
        );
        assert!(error("int64=long").contains("`string` or `int`"));
        assert!(error("int64").contains("`key=value`"));
        assert!(error("colour=red").contains("There is no option `colour`."));
        assert!(error("int64=int,int64=string").contains("more than once"));
        let bytes = |parameter| parse(parameter).map(|o| o.bytes);
        assert_eq!(bytes(""), Ok(Bytes::String));
        assert_eq!(bytes("bytes=bytes"), Ok(Bytes::Bytes));
        assert_eq!(bytes("bytes=string,int64=int"), Ok(Bytes::String));
        assert_eq!(parse("bytes=bytes").map(|o| o.int64), Ok(Int64::String));
        assert!(error("bytes=base64").contains("`string` or `bytes`"));
        assert!(error("bytes=bytes,bytes=string").contains("more than once"));
        let unbound = |parameter| parse(parameter).map(|o| o.unbound_methods);
        assert_eq!(unbound(""), Ok(UnboundMethods::Implicit));
        assert_eq!(unbound("unbound_methods=error"), Ok(UnboundMethods::Error));
        assert_eq!(
            unbound("int64=int,unbound_methods=implicit"),
            Ok(UnboundMethods::Implicit)
        );
        assert!(error("unbound_methods=drop").contains("`implicit` or `error`"));
        let streaming = |parameter| parse(parameter).map(|o| o.streaming);
        assert_eq!(streaming(""), Ok(Streaming::Error));
        assert_eq!(streaming("streaming=skip"), Ok(Streaming::Skip));
        assert_eq!(streaming("streaming=error,int64=int"), Ok(Streaming::Error));
        assert!(error("streaming=drop").contains("`error` or `skip`"));
        assert!(error("streaming=skip,streaming=skip").contains("more than once"));
        let enum_unknown = |parameter| parse(parameter).map(|o| o.enum_unknown);
        assert_eq!(enum_unknown(""), Ok(EnumUnknown::Fail));
        assert_eq!(enum_unknown("enum_unknown=zero"), Ok(EnumUnknown::Zero));
        assert_eq!(
            enum_unknown("enum_unknown=fail,streaming=skip"),
            Ok(EnumUnknown::Fail)
        );
        assert!(error("enum_unknown=variant").contains("`fail` or `zero`"));
        assert!(error("enum_unknown=zero,enum_unknown=zero").contains("more than once"));
    }

    #[test]
    fn the_header_records_options_off_their_defaults_in_a_fixed_order() {
        let recorded = |parameter| parse(parameter).map(|o| o.recorded());
        assert_eq!(recorded(""), Ok(Vec::new()));
        assert_eq!(
            recorded("int64=string,bytes=string,streaming=error,enum_unknown=fail"),
            Ok(Vec::new())
        );
        assert_eq!(
            recorded(
                "module_prefix=Api,rename=b.C:D,enum_unknown=zero,rename=a.B:C,\
                 unbound_methods=error,streaming=skip,bytes=bytes,int64=int"
            ),
            Ok([
                "int64=int",
                "bytes=bytes",
                "unbound_methods=error",
                "streaming=skip",
                "enum_unknown=zero",
                "rename=a.B:C",
                "rename=b.C:D",
                "module_prefix=Api",
            ]
            .map(str::to_owned)
            .to_vec())
        );
        for key in [
            "int64",
            "bytes",
            "unbound_methods",
            "streaming",
            "enum_unknown",
        ] {
            assert!(default_value(key).is_some(), "{key}");
        }
        assert_eq!(default_value("rename"), None);
        assert_eq!(default_value("module_prefix"), None);
    }

    #[test]
    fn option_problems_have_codes_and_are_reported_together() {
        assert_eq!(codes("colour=red"), [Code::UnknownOption]);
        assert_eq!(codes("int64"), [Code::UnknownOption]);
        assert_eq!(codes("int64=long"), [Code::UnknownOption]);
        assert_eq!(codes("int64=int,int64=int"), [Code::DuplicateOption]);
        assert_eq!(codes("rename=a.B:C,rename=a.B:D"), [Code::DuplicateOption]);
        assert_eq!(codes("rename=a.B"), [Code::InvalidRename]);
        assert_eq!(codes("module_prefix=api"), [Code::InvalidModulePrefix]);
        assert_eq!(
            codes("colour=red,int64=long,bytes=bytes,bytes=string,module_prefix=api"),
            [
                Code::UnknownOption,
                Code::UnknownOption,
                Code::DuplicateOption,
                Code::InvalidModulePrefix
            ]
        );
        assert_eq!(
            error("int64=long"),
            "The option `int64` is `long`, which is not one of its values. `int64` is \
             `string` or `int`; left out, it is `string`."
        );
        // An unknown key repeated is unknown each time, not a duplicate.
        assert_eq!(
            codes("colour=red,colour=blue"),
            [Code::UnknownOption, Code::UnknownOption]
        );
    }

    #[test]
    fn rename_repeats_and_takes_proto_and_elm_names() {
        let rename = |parameter| parse(parameter).map(|o| o.rename);
        assert_eq!(rename(""), Ok(BTreeMap::new()));
        assert_eq!(
            rename("rename=notes.v1.Note:Memo, rename = notes.v1.Note.title : heading"),
            Ok(BTreeMap::from([
                ("notes.v1.Note".to_owned(), "Memo".to_owned()),
                ("notes.v1.Note.title".to_owned(), "heading".to_owned()),
            ]))
        );
        assert!(error("rename=notes.v1.Note").contains("`<proto full name>:<Elm name>`"));
        assert!(error("rename=notes.v1.Note:").contains("`<proto full name>:<Elm name>`"));
        assert!(error("rename=:Memo").contains("`<proto full name>:<Elm name>`"));
        assert!(
            error("rename=notes.v1.Note:Memo,rename=notes.v1.Note:Note")
                .contains("rename `notes.v1.Note` more than once")
        );
        assert!(
            error("rename=a.B:C,int64=int,int64=int").contains("`int64` is given more than once")
        );
    }

    #[test]
    fn module_prefix_takes_elm_module_segments_once() {
        let prefix =
            |parameter| parse(parameter).map(|o| o.module_prefix.map(|module| module.to_string()));
        assert_eq!(prefix(""), Ok(None));
        assert_eq!(prefix("module_prefix=Api"), Ok(Some("Api".to_owned())));
        assert_eq!(
            prefix("module_prefix = Api.Notes_2 ,int64=int"),
            Ok(Some("Api.Notes_2".to_owned()))
        );
        for invalid in [
            "",
            "api",
            "Api.",
            ".Api",
            "Api..Notes",
            "Api.1V",
            "Api-Notes",
        ] {
            let parameter = format!("module_prefix={invalid}");
            assert_eq!(codes(&parameter), [Code::InvalidModulePrefix]);
            assert!(
                error(&parameter).starts_with(&format!(
                    "The module prefix `{invalid}` is not an Elm module name. A module \
                     prefix is dot-separated Elm module segments"
                )),
                "{invalid}"
            );
        }
        assert!(error("module_prefix=Api,module_prefix=Api").contains("more than once"));
    }
}
