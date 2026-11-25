//! The flag generated code gives a method so that a send over one of its
//! typed routes does not write the request's JSON only to check it
//! (`Proto.Method.withoutRequestCheck`, design §5). Nothing in Elm checks
//! that a flagged method's request cannot refuse its JSON write, so this
//! test holds the committed generated code to it: the corpus's expected
//! modules, which the corpus test holds to the generator, and the
//! examples'.
//!
//! Whether a request can refuse is read from its encoder as the compiler
//! checked it: a generated message encoder annotated `Proto.Json.Encoder
//! x` cannot produce an error whatever `x` is, one annotated
//! `Proto.Json.Encoder Proto.Error.Error` can; a well-known request is
//! written by `Proto.Json.succeed << ...` when it cannot refuse and by a
//! `Proto.Json.write...` encoder when it can. A method is flagged exactly
//! when it has typed routes (`withRoutes`) and its request cannot refuse.

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

mod common;
use common::{cases, files_under, is_diagnostics_case, repo_root};

/// The directories of generated modules this test reads, each a module
/// root.
fn roots() -> Vec<PathBuf> {
    let mut roots: Vec<PathBuf> = cases()
        .into_iter()
        .filter(|case| !is_diagnostics_case(case))
        .map(|case| case.join("expected"))
        .collect();
    roots.push(repo_root().join("examples/notes/elm/generated"));
    roots.push(repo_root().join("examples/eliza/generated"));
    roots
}

/// The Elm modules under `root`, by module name.
fn modules(root: &Path) -> HashMap<String, String> {
    files_under(root)
        .into_iter()
        .filter_map(|file| {
            let name = file.strip_suffix(".elm")?.replace('/', ".");
            let text =
                fs::read_to_string(root.join(&file)).unwrap_or_else(|e| panic!("read {file}: {e}"));
            Some((name, text))
        })
        .collect()
}

/// Whether each generated JSON encoder (`Notes.V1.encodeNote`) can refuse,
/// from its annotation.
fn encoders(modules: &HashMap<String, String>) -> HashMap<String, bool> {
    let mut out = HashMap::new();
    for (module, text) in modules {
        for line in text.lines() {
            let Some((name, annotation)) = line.split_once(" : ") else {
                continue;
            };
            if !name.starts_with("encode") || name.contains(' ') {
                continue;
            }
            let Some((_, error)) = annotation.rsplit_once("-> Proto.Json.Encoder ") else {
                continue;
            };
            let refuses = match error {
                "Proto.Error.Error" => true,
                variable if variable.chars().all(|c| c.is_ascii_lowercase()) => false,
                other => panic!("{module}.{name}: an encoder of error type {other}"),
            };
            out.insert(format!("{module}.{name}"), refuses);
        }
    }
    out
}

/// One generated method over JSON: its name, whether its request can
/// refuse, and the steps piped after its builder.
struct Built {
    name: String,
    refuses: bool,
    steps: Vec<String>,
}

fn methods(modules: &HashMap<String, String>, encoders: &HashMap<String, bool>) -> Vec<Built> {
    let mut out = Vec::new();
    for (module, text) in modules {
        let lines: Vec<&str> = text.lines().map(str::trim).collect();
        for (at, line) in lines.iter().enumerate() {
            if !(line.starts_with("(Proto.Method.init \"")
                || line.starts_with("(Proto.Method.initJson \""))
            {
                continue;
            }
            let name = format!("{module} {}", lines[at + 1]);
            let encoder = lines[at + 2];
            let refuses = if encoder.starts_with("(Proto.Json.succeed << ") {
                false
            } else if encoder.starts_with("Proto.Json.write") {
                true
            } else {
                *encoders.get(encoder).unwrap_or_else(|| {
                    panic!("{name}: an encoder this test cannot read: {encoder}")
                })
            };
            let steps = lines[at + 3..]
                .iter()
                .take_while(|line| **line != ")")
                .filter_map(|line| line.strip_prefix("|> "))
                .map(str::to_owned)
                .collect();
            out.push(Built {
                name,
                refuses,
                steps,
            });
        }
    }
    out
}

#[test]
fn only_a_request_that_cannot_refuse_skips_its_check() {
    let (mut flagged, mut checked_typed) = (0, 0);
    for root in roots() {
        let modules = modules(&root);
        let encoders = encoders(&modules);
        for method in methods(&modules, &encoders) {
            let flag = method
                .steps
                .iter()
                .any(|step| step == "Proto.Method.withoutRequestCheck");
            let typed = method
                .steps
                .iter()
                .any(|step| step.starts_with("Proto.Method.withRoutes "));
            assert_eq!(
                flag,
                typed && !method.refuses,
                "{} under {}: flagged {flag}, typed routes {typed}, request can refuse {}",
                method.name,
                root.display(),
                method.refuses
            );
            flagged += usize::from(flag);
            checked_typed += usize::from(typed && method.refuses);
        }
    }
    // Both sides are present, so the assertion above is not vacuous.
    assert!(flagged > 0, "no flagged method");
    assert!(
        checked_typed > 0,
        "no method with typed routes whose request can refuse"
    );
}
