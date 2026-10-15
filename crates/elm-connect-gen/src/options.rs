//! The generator's options (design §6): what a protoc plugin parameter or
//! the CLI's flags set.

use std::collections::BTreeSet;

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
}

impl Options {
    /// The options a protoc plugin parameter sets: comma-separated
    /// `key=value` pairs, such as `int64=int`, each option at most once.
    /// The empty parameter is the defaults. An unknown key or value is an
    /// error saying which.
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
            if !seen.insert(key.to_owned()) {
                return Err(format!("`{key}` is given more than once"));
            }
            match key {
                "int64" => options.int64 = value.parse()?,
                "unbound_methods" => options.unbound_methods = value.parse()?,
                "streaming" => options.streaming = value.parse()?,
                _ => {
                    return Err(format!(
                        "unknown option `{key}`; the options are: int64, unbound_methods, \
                         streaming"
                    ));
                }
            }
        }
        Ok(options)
    }
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
    }
}
