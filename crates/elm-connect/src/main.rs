use std::path::PathBuf;

use clap::{Parser, Subcommand};

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
    },
}

fn main() -> miette::Result<()> {
    match Cli::parse().command {
        Command::Gen {
            files,
            includes,
            out,
        } => {
            let generated = elm_connect::generate(&files, &includes)?;
            for path in elm_connect::write(&generated, &out)? {
                println!("{}", path.display());
            }
            Ok(())
        }
    }
}
