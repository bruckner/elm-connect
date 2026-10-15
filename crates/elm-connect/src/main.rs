use std::path::PathBuf;

use clap::{Parser, Subcommand};
use elm_connect_gen::{EnumUnknown, Int64, Options, Streaming, UnboundMethods};
use miette::{Report, miette};

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
        /// What an enum value name the decoder does not know reads as:
        /// `fail` (the decode fails) or `zero` (the zero value, as an
        /// unknown number always does).
        #[arg(long, value_name = "fail|zero", default_value = "fail")]
        enum_unknown: EnumUnknown,
        /// An Elm name for a proto element, in place of the one the naming
        /// rules derive: `<proto full name>:<Elm name>`, such as
        /// `notes.v1.Note:Memo`; repeatable. The proto name is a package,
        /// service, method, message, enum, field, oneof or enum value.
        #[arg(long, value_name = "PROTO:ELM", value_parser = rename_entry)]
        rename: Vec<String>,
        /// Also generate the packages of every file the given ones import,
        /// transitively, as `buf generate --include-imports` does; without
        /// it, a reference to a package none of the given files declares is
        /// an error. `google/protobuf` files are never generated, nor are
        /// `google/api/http.proto` and `google/api/annotations.proto`,
        /// which only carry `google.api.http`.
        #[arg(long)]
        include_imports: bool,
    },
}

/// A `--rename` value, checked for its `<proto full name>:<Elm name>`
/// form.
fn rename_entry(value: &str) -> Result<String, String> {
    elm_connect_gen::parse_rename(value).map(|_| value.to_owned())
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
            enum_unknown,
            rename,
            include_imports,
        } => {
            let mut options = Options::default();
            options.int64 = int64;
            options.unbound_methods = unbound_methods;
            options.streaming = streaming;
            options.enum_unknown = enum_unknown;
            for entry in &rename {
                options
                    .add_rename(entry)
                    .map_err(|err| miette!("--rename: {err}"))?;
            }
            let generated = elm_connect::generate(&files, &includes, include_imports, &options)?;
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

    fn enum_unknown(args: &[&str]) -> Result<EnumUnknown, clap::Error> {
        let base = ["elm-connect", "gen", "a.proto", "--out", "out"];
        let cli = Cli::try_parse_from(base.iter().chain(args))?;
        let Command::Gen { enum_unknown, .. } = cli.command;
        Ok(enum_unknown)
    }

    #[test]
    fn enum_unknown_defaults_to_fail_and_takes_zero() {
        assert_eq!(enum_unknown(&[]).expect("parses"), EnumUnknown::Fail);
        assert_eq!(
            enum_unknown(&["--enum-unknown", "zero"]).expect("parses"),
            EnumUnknown::Zero
        );
        assert!(enum_unknown(&["--enum-unknown", "variant"]).is_err());
    }

    fn rename(args: &[&str]) -> Result<Vec<String>, clap::Error> {
        let base = ["elm-connect", "gen", "a.proto", "--out", "out"];
        let cli = Cli::try_parse_from(base.iter().chain(args))?;
        let Command::Gen { rename, .. } = cli.command;
        Ok(rename)
    }

    #[test]
    fn rename_repeats_and_needs_a_colon() {
        assert_eq!(rename(&[]).expect("parses"), Vec::<String>::new());
        assert_eq!(
            rename(&[
                "--rename",
                "notes.v1.Note:Memo",
                "--rename",
                "notes.v1.Note.title:heading"
            ])
            .expect("parses"),
            ["notes.v1.Note:Memo", "notes.v1.Note.title:heading"]
        );
        assert!(rename(&["--rename", "notes.v1.Note"]).is_err());
        assert!(rename(&["--rename", "notes.v1.Note:"]).is_err());
        assert!(int64(&["--int64", "int", "--int64", "string"]).is_err());
    }

    fn include_imports(args: &[&str]) -> Result<bool, clap::Error> {
        let base = ["elm-connect", "gen", "a.proto", "--out", "out"];
        let cli = Cli::try_parse_from(base.iter().chain(args))?;
        let Command::Gen {
            include_imports, ..
        } = cli.command;
        Ok(include_imports)
    }

    #[test]
    fn include_imports_defaults_to_off_and_takes_no_value() {
        assert!(!include_imports(&[]).expect("parses"));
        assert!(include_imports(&["--include-imports"]).expect("parses"));
        assert!(include_imports(&["--include-imports=true"]).is_err());
    }

    #[test]
    fn int64_defaults_to_string_and_takes_int() {
        assert_eq!(int64(&[]).expect("parses"), Int64::String);
        assert_eq!(int64(&["--int64", "int"]).expect("parses"), Int64::Int);
        assert!(int64(&["--int64", "long"]).is_err());
    }
}
