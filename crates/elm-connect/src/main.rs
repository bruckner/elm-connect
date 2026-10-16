use std::path::PathBuf;
use std::process::ExitCode;

use clap::{Args, Parser, Subcommand};
use elm_connect_gen::ir::ModuleName;
use elm_connect_gen::{
    EnumUnknown, Generated, Int64, Options, Spelling, Streaming, UnboundMethods,
};
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
    Gen(GenArgs),
    /// Generate as `gen` would, in memory, and compare with the modules
    /// under `--out`: exit status 0 when they are current, 1 when a module
    /// is missing, differs or is stale (a file elm-connect generated that
    /// generating no longer gives). Takes exactly `gen`'s arguments.
    Check(GenArgs),
}

/// What to generate from and how: the arguments `gen` and `check` share.
#[derive(Args)]
struct GenArgs {
    /// The .proto files to generate from, relative to an include directory.
    #[arg(required = true)]
    files: Vec<PathBuf>,
    /// A directory to search for imports; repeatable. Defaults to `.`.
    #[arg(short = 'I', long = "proto-path", value_name = "DIR")]
    includes: Vec<PathBuf>,
    /// The directory of the Elm modules: `gen` writes them there, and
    /// `check` compares them with what it would write.
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
    /// The module every generated module goes inside, such as
    /// `Api.Notes`: `notes.v1` then becomes `Api.Notes.V1`, in
    /// `Api/Notes/V1.elm`. The runtime's modules are never prefixed.
    #[arg(long, value_name = "MODULE", value_parser = elm_connect_gen::parse_module_prefix)]
    module_prefix: Option<ModuleName>,
    /// Also generate every imported file that declares a message or enum
    /// the given files' packages refer to, transitively, each imported
    /// package from those files alone; without it, a reference to a
    /// package none of the given files declares is an error. A file
    /// imported only for its options (`google/api/annotations.proto`,
    /// `google/api/client.proto`) is not generated, nor are
    /// `google/protobuf` files, which map to the runtime.
    #[arg(long)]
    include_imports: bool,
}

impl GenArgs {
    /// The generator's options the flags set.
    fn options(&self) -> miette::Result<Options> {
        let mut options = Options::default();
        options.int64 = self.int64;
        options.unbound_methods = self.unbound_methods;
        options.streaming = self.streaming;
        options.enum_unknown = self.enum_unknown;
        options.module_prefix = self.module_prefix.clone();
        options.spelling = Spelling::Flags;
        for entry in &self.rename {
            options
                .add_rename(entry)
                .map_err(|err| miette!("--rename: {err}"))?;
        }
        Ok(options)
    }

    /// Generates as the flags say, printing any warnings to stderr.
    fn generate(&self) -> miette::Result<Generated> {
        let generated = elm_connect::generate(
            &self.files,
            &self.includes,
            self.include_imports,
            &self.options()?,
        )?;
        if !generated.warnings.is_empty() {
            eprintln!("{:?}", Report::new(generated.warnings.clone()));
        }
        Ok(generated)
    }
}

/// A `--rename` value, checked for its `<proto full name>:<Elm name>`
/// form.
fn rename_entry(value: &str) -> Result<String, String> {
    elm_connect_gen::parse_rename(value).map(|_| value.to_owned())
}

fn main() -> miette::Result<ExitCode> {
    match Cli::parse().command {
        Command::Gen(args) => {
            let generated = args.generate()?;
            for path in elm_connect::write(&generated.files, &args.out)? {
                println!("{}", path.display());
            }
            Ok(ExitCode::SUCCESS)
        }
        Command::Check(args) => {
            let generated = args.generate()?;
            let check = elm_connect::check(&generated.files, &args.out)?;
            print!("{}", check.render());
            Ok(if check.is_current() {
                ExitCode::SUCCESS
            } else {
                ExitCode::FAILURE
            })
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// `gen`'s arguments, parsed from `a.proto --out out` and `args`.
    fn gen_args(args: &[&str]) -> Result<GenArgs, clap::Error> {
        let base = ["elm-connect", "gen", "a.proto", "--out", "out"];
        match Cli::try_parse_from(base.iter().chain(args))?.command {
            Command::Gen(args) => Ok(args),
            Command::Check(_) => unreachable!("parsed as gen"),
        }
    }

    #[test]
    fn check_takes_the_arguments_of_gen() {
        let args = [
            "elm-connect",
            "check",
            "a.proto",
            "b.proto",
            "-I",
            "protos",
            "--out",
            "generated",
            "--int64",
            "int",
            "--unbound-methods",
            "error",
            "--streaming",
            "skip",
            "--enum-unknown",
            "zero",
            "--rename",
            "notes.v1.Note:Memo",
            "--module-prefix",
            "Api",
            "--include-imports",
        ];
        let Command::Check(args) = Cli::try_parse_from(args).expect("parses").command else {
            panic!("parsed as check");
        };
        assert_eq!(
            args.files,
            [PathBuf::from("a.proto"), PathBuf::from("b.proto")]
        );
        assert_eq!(args.includes, [PathBuf::from("protos")]);
        assert_eq!(args.out, PathBuf::from("generated"));
        let options = args.options().expect("valid options");
        assert_eq!(options.int64, Int64::Int);
        assert_eq!(options.unbound_methods, UnboundMethods::Error);
        assert_eq!(options.streaming, Streaming::Skip);
        assert_eq!(options.enum_unknown, EnumUnknown::Zero);
        assert_eq!(options.spelling, Spelling::Flags);
        assert!(args.include_imports);
        assert!(Cli::try_parse_from(["elm-connect", "check", "a.proto"]).is_err());
    }

    fn int64(args: &[&str]) -> Result<Int64, clap::Error> {
        gen_args(args).map(|args| args.int64)
    }

    fn unbound_methods(args: &[&str]) -> Result<UnboundMethods, clap::Error> {
        gen_args(args).map(|args| args.unbound_methods)
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
        gen_args(args).map(|args| args.streaming)
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
        gen_args(args).map(|args| args.enum_unknown)
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
        gen_args(args).map(|args| args.rename)
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

    fn module_prefix(args: &[&str]) -> Result<Option<String>, clap::Error> {
        gen_args(args).map(|args| args.module_prefix.map(|module| module.to_string()))
    }

    #[test]
    fn module_prefix_takes_elm_module_segments_once() {
        assert_eq!(module_prefix(&[]).expect("parses"), None);
        assert_eq!(
            module_prefix(&["--module-prefix", "Api.Notes"]).expect("parses"),
            Some("Api.Notes".to_owned())
        );
        for invalid in ["", "api.Notes", "Api.", "Api-Notes"] {
            let error = module_prefix(&["--module-prefix", invalid]).unwrap_err();
            assert!(
                error
                    .to_string()
                    .contains("`module_prefix` is dot-separated Elm module segments"),
                "{invalid}: {error}"
            );
        }
        assert!(module_prefix(&["--module-prefix", "Api", "--module-prefix", "Web"]).is_err());
    }

    fn include_imports(args: &[&str]) -> Result<bool, clap::Error> {
        gen_args(args).map(|args| args.include_imports)
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
