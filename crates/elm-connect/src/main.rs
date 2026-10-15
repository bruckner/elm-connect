use std::path::PathBuf;

use clap::{Parser, Subcommand};
use elm_connect_gen::{Int64, Options, Streaming, UnboundMethods};
use miette::Report;

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
        /// What a client, server or bidirectional streaming method gets:
        /// `error` (a diagnostic) or `skip` (left out of its service's
        /// module, with a warning; the rest is generated).
        #[arg(long, value_name = "error|skip", default_value = "error")]
        streaming: Streaming,
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
            streaming,
        } => {
            let mut options = Options::default();
            options.int64 = int64;
            options.unbound_methods = unbound_methods;
            options.streaming = streaming;
            let generated = elm_connect::generate(&files, &includes, &options)?;
            if !generated.warnings.is_empty() {
                eprintln!("{:?}", Report::new(generated.warnings));
            }
            for path in elm_connect::write(&generated.files, &out)? {
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

    fn streaming(args: &[&str]) -> Result<Streaming, clap::Error> {
        let base = ["elm-connect", "gen", "a.proto", "--out", "out"];
        let cli = Cli::try_parse_from(base.iter().chain(args))?;
        let Command::Gen { streaming, .. } = cli.command;
        Ok(streaming)
    }

    #[test]
    fn streaming_defaults_to_error_and_takes_skip() {
        assert_eq!(streaming(&[]).expect("parses"), Streaming::Error);
        assert_eq!(
            streaming(&["--streaming", "skip"]).expect("parses"),
            Streaming::Skip
        );
        assert!(streaming(&["--streaming", "drop"]).is_err());
    }

    #[test]
    fn int64_defaults_to_string_and_takes_int() {
        assert_eq!(int64(&[]).expect("parses"), Int64::String);
        assert_eq!(int64(&["--int64", "int"]).expect("parses"), Int64::Int);
        assert!(int64(&["--int64", "long"]).is_err());
    }
}
