//! The generator's options (design §6): what a protoc plugin parameter or
//! the CLI's flags set.

use std::collections::{BTreeMap, BTreeSet};

use crate::ir::ModuleName;

/// How to generate (design §6). The options design §6 lists that are not
/// here arrive with the features they control.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
#[non_exhaustive]
pub struct Options {
    /// How 64-bit integer fields are held (`int64=`), unless a field's
    /// `jstype` says otherwise (design §3.4).
    pub int64: Int64,
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
}

impl Options {
    /// The options a protoc plugin parameter sets: comma-separated
    /// `key=value` pairs, such as `int64=int`, each option at most once
    /// but `rename`, which repeats. The empty parameter is the defaults.
    /// An unknown key or value is an error saying which.
    pub fn from_parameter(parameter: &str) -> Result<Self, String> {
        let mut options = Options::default();
        let mut seen = BTreeSet::new();
        for pair in parameter
            .split(',')
            .map(str::trim)
            .filter(|p| !p.is_empty())
        {
            let Some((key, value)) = pair.split_once('=') else {
                return Err(format!("expected `key=value`, got `{pair}`"));
            };
            let (key, value) = (key.trim(), value.trim());
            if key != "rename" && !seen.insert(key.to_owned()) {
                return Err(format!("`{key}` is given more than once"));
            }
            match key {
                "int64" => options.int64 = value.parse()?,
                "unbound_methods" => options.unbound_methods = value.parse()?,
                "streaming" => options.streaming = value.parse()?,
                "enum_unknown" => options.enum_unknown = value.parse()?,
                "rename" => options.add_rename(value)?,
                "module_prefix" => options.module_prefix = Some(parse_module_prefix(value)?),
                _ => {
                    return Err(format!(
                        "unknown option `{key}`; the options are: int64, unbound_methods, \
                         streaming, enum_unknown, rename, module_prefix"
                    ));
                }
            }
        }
        Ok(options)
    }

    /// Adds one entry of the rename map, written `<proto full name>:<Elm
    /// name>` (`notes.v1.Note:Memo`). Neither side may be empty, and a
    /// proto name may be renamed once. Whether the Elm name suits what the
    /// proto name denotes is the IR builder's to check, since that needs
    /// the descriptors.
    pub fn add_rename(&mut self, entry: &str) -> Result<(), String> {
        let (proto, elm) = parse_rename(entry)?;
        if self.rename.contains_key(&proto) {
            return Err(format!("`rename` renames `{proto}` more than once"));
        }
        self.rename.insert(proto, elm);
        Ok(())
    }
}

/// One entry of the rename map, `<proto full name>:<Elm name>`, as its two
/// sides, trimmed: what [`Options::add_rename`] accepts.
pub fn parse_rename(entry: &str) -> Result<(String, String), String> {
    match entry.split_once(':') {
        Some((proto, elm)) if !proto.trim().is_empty() && !elm.trim().is_empty() => {
            Ok((proto.trim().to_owned(), elm.trim().to_owned()))
        }
        _ => Err(format!(
            "`rename` is `<proto full name>:<Elm name>`, such as `notes.v1.Note:Memo`, not \
             `{entry}`"
        )),
    }
}

/// A `module_prefix` value: dot-separated Elm module segments, each an
/// ASCII uppercase letter followed by ASCII letters, digits or
/// underscores, such as `Api.Notes`.
pub fn parse_module_prefix(value: &str) -> Result<ModuleName, String> {
    ModuleName::parse(value).ok_or_else(|| {
        format!(
            "`module_prefix` is dot-separated Elm module segments, such as `Api.Notes`, not \
             `{value}`"
        )
    })
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

/// What a method without a `google.api.http` rule gets (design §4).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum UnboundMethods {
    /// Generated like any other, with no bindings: the runtime calls it
    /// over the implicit route `POST /<package>.<Service>/<Method>`, which
    /// grpc-gateway (`generate_unbound_methods`), Envoy's transcoder
    /// (`auto_mapping`) and Vanguard serve.
    #[default]
    Implicit,
    /// A diagnostic, `services::unbound_method`, for a server that serves
    /// rules alone.
    Error,
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

    #[test]
    fn options_come_from_a_plugin_parameter() {
        assert_eq!(Options::from_parameter(""), Ok(Options::default()));
        assert_eq!(
            Options::from_parameter("int64=int").map(|o| o.int64),
            Ok(Int64::Int)
        );
        assert_eq!(
            Options::from_parameter(" int64 = string ,").map(|o| o.int64),
            Ok(Int64::String)
        );
        let error = |parameter| Options::from_parameter(parameter).unwrap_err();
        assert!(error("int64=long").contains("`string` or `int`"));
        assert!(error("int64").contains("`key=value`"));
        assert!(error("colour=red").contains("unknown option `colour`"));
        assert!(error("int64=int,int64=string").contains("more than once"));
        let unbound = |parameter| Options::from_parameter(parameter).map(|o| o.unbound_methods);
        assert_eq!(unbound(""), Ok(UnboundMethods::Implicit));
        assert_eq!(unbound("unbound_methods=error"), Ok(UnboundMethods::Error));
        assert_eq!(
            unbound("int64=int,unbound_methods=implicit"),
            Ok(UnboundMethods::Implicit)
        );
        assert!(error("unbound_methods=drop").contains("`implicit` or `error`"));
        let streaming = |parameter| Options::from_parameter(parameter).map(|o| o.streaming);
        assert_eq!(streaming(""), Ok(Streaming::Error));
        assert_eq!(streaming("streaming=skip"), Ok(Streaming::Skip));
        assert_eq!(streaming("streaming=error,int64=int"), Ok(Streaming::Error));
        assert!(error("streaming=drop").contains("`error` or `skip`"));
        assert!(error("streaming=skip,streaming=skip").contains("more than once"));
        let enum_unknown = |parameter| Options::from_parameter(parameter).map(|o| o.enum_unknown);
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
    fn rename_repeats_and_takes_proto_and_elm_names() {
        let rename = |parameter| Options::from_parameter(parameter).map(|o| o.rename);
        assert_eq!(rename(""), Ok(BTreeMap::new()));
        assert_eq!(
            rename("rename=notes.v1.Note:Memo, rename = notes.v1.Note.title : heading"),
            Ok(BTreeMap::from([
                ("notes.v1.Note".to_owned(), "Memo".to_owned()),
                ("notes.v1.Note.title".to_owned(), "heading".to_owned()),
            ]))
        );
        let error = |parameter| Options::from_parameter(parameter).unwrap_err();
        assert!(error("rename=notes.v1.Note").contains("`<proto full name>:<Elm name>`"));
        assert!(error("rename=notes.v1.Note:").contains("`<proto full name>:<Elm name>`"));
        assert!(error("rename=:Memo").contains("`<proto full name>:<Elm name>`"));
        assert!(
            error("rename=notes.v1.Note:Memo,rename=notes.v1.Note:Note")
                .contains("renames `notes.v1.Note` more than once")
        );
        assert!(
            error("rename=a.B:C,int64=int,int64=int").contains("`int64` is given more than once")
        );
    }

    #[test]
    fn module_prefix_takes_elm_module_segments_once() {
        let prefix = |parameter| {
            Options::from_parameter(parameter)
                .map(|o| o.module_prefix.map(|module| module.to_string()))
        };
        assert_eq!(prefix(""), Ok(None));
        assert_eq!(prefix("module_prefix=Api"), Ok(Some("Api".to_owned())));
        assert_eq!(
            prefix("module_prefix = Api.Notes_2 ,int64=int"),
            Ok(Some("Api.Notes_2".to_owned()))
        );
        let error = |parameter: &str| Options::from_parameter(parameter).unwrap_err();
        for invalid in [
            "",
            "api",
            "Api.",
            ".Api",
            "Api..Notes",
            "Api.1V",
            "Api-Notes",
        ] {
            assert_eq!(
                error(&format!("module_prefix={invalid}")),
                format!(
                    "`module_prefix` is dot-separated Elm module segments, such as \
                     `Api.Notes`, not `{invalid}`"
                )
            );
        }
        assert!(error("module_prefix=Api,module_prefix=Api").contains("more than once"));
    }
}
