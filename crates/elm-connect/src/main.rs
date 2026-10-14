use std::path::PathBuf;

use clap::{Parser, Subcommand};
use elm_connect_gen::{Descriptors, Int64, Options, UnboundMethods};

/// Generate Elm clients for protobuf APIs.
#[derive(Parser)]
#[command(version = elm_connect_gen::VERSION)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Compile .proto files and generate Elm modules from them.
    Gen {
        /// The .proto files to generate from, relative to an include directory.
        #[arg(required = true)]
        files: Vec<PathBuf>,
        /// A directory to search for imports; repeatable. Defaults to `.`.
        #[arg(short = 'I', long = "proto-path", value_name = "DIR")]
        includes: Vec<PathBuf>,
        /// The directory to write Elm modules into.
        #[arg(short, long, value_name = "DIR")]
        out: PathBuf,
        /// How to hold 64-bit integers: `string` (exact) or `int` (Elm's
        /// `Int`, exact within ±(2^53 − 1); larger values fail to decode).
        /// A field's `jstype` option overrides it.
        #[arg(long, value_name = "string|int", default_value = "string")]
        int64: Int64,
        /// What a method without a `google.api.http` rule gets: `implicit`
        /// (a call the runtime sends over the implicit route,
        /// `POST /<package>.<Service>/<Method>`) or `error` (a diagnostic).
        #[arg(long, value_name = "implicit|error", default_value = "implicit")]
        unbound_methods: UnboundMethods,
        /// Whether messages' and enums' descriptors hold their fields and
        /// values: `on`, or `off` (the trees are empty and no registry is
        /// generated, for smaller modules).
        #[arg(long, value_name = "on|off", default_value = "on")]
        descriptors: Descriptors,
    },
}

fn main() -> miette::Result<()> {
    match Cli::parse().command {
        Command::Gen {
            files,
            includes,
            out,
            int64,
            unbound_methods,
            descriptors,
        } => {
            let mut options = Options::default();
            options.int64 = int64;
            options.unbound_methods = unbound_methods;
            options.descriptors = descriptors;
            let generated = elm_connect::generate(&files, &includes, &options)?;
            for path in elm_connect::write(&generated, &out)? {
                println!("{}", path.display());
            }
            Ok(())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn int64(args: &[&str]) -> Result<Int64, clap::Error> {
        let base = ["elm-connect", "gen", "a.proto", "--out", "out"];
        let cli = Cli::try_parse_from(base.iter().chain(args))?;
        let Command::Gen { int64, .. } = cli.command;
        Ok(int64)
    }

    fn unbound_methods(args: &[&str]) -> Result<UnboundMethods, clap::Error> {
        let base = ["elm-connect", "gen", "a.proto", "--out", "out"];
        let cli = Cli::try_parse_from(base.iter().chain(args))?;
        let Command::Gen {
            unbound_methods, ..
        } = cli.command;
        Ok(unbound_methods)
    }

    #[test]
    fn unbound_methods_default_to_implicit_and_take_error() {
        assert_eq!(
            unbound_methods(&[]).expect("parses"),
            UnboundMethods::Implicit
        );
        assert_eq!(
            unbound_methods(&["--unbound-methods", "error"]).expect("parses"),
            UnboundMethods::Error
        );
        assert!(unbound_methods(&["--unbound-methods", "drop"]).is_err());
    }

    fn descriptors(args: &[&str]) -> Result<Descriptors, clap::Error> {
        let base = ["elm-connect", "gen", "a.proto", "--out", "out"];
        let cli = Cli::try_parse_from(base.iter().chain(args))?;
        let Command::Gen { descriptors, .. } = cli.command;
        Ok(descriptors)
    }

    #[test]
    fn descriptors_default_to_on_and_take_off() {
        assert_eq!(descriptors(&[]).expect("parses"), Descriptors::On);
        assert_eq!(
            descriptors(&["--descriptors", "off"]).expect("parses"),
            Descriptors::Off
        );
        assert!(descriptors(&["--descriptors", "empty"]).is_err());
    }

    #[test]
    fn int64_defaults_to_string_and_takes_int() {
        assert_eq!(int64(&[]).expect("parses"), Int64::String);
        assert_eq!(int64(&["--int64", "int"]).expect("parses"), Int64::Int);
        assert!(int64(&["--int64", "long"]).is_err());
    }
}
