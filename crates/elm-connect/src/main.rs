use std::path::PathBuf;

use clap::{Parser, Subcommand};
use elm_connect_gen::{Int64, Options};

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
    },
}

fn main() -> miette::Result<()> {
    match Cli::parse().command {
        Command::Gen {
            files,
            includes,
            out,
            int64,
        } => {
            let mut options = Options::default();
            options.int64 = int64;
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

    #[test]
    fn int64_defaults_to_string_and_takes_int() {
        assert_eq!(int64(&[]).expect("parses"), Int64::String);
        assert_eq!(int64(&["--int64", "int"]).expect("parses"), Int64::Int);
        assert!(int64(&["--int64", "long"]).is_err());
    }
}
