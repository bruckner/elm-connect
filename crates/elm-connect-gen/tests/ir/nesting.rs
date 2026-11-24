//! The `types::deep_nesting` warning: a chain of messages longer than the
//! runtime's read limit of 100, counted from the outermost message at 1,
//! through every kind of message reference and across packages, ended by a
//! well-known type and passing through a cycle once; and its rendering, as
//! a corpus `warnings.txt` would hold it.

use elm_connect_gen::Options;
use elm_connect_gen::diagnostics::{Code, Problem};
use elm_connect_gen::ir;

use crate::common::{pool, render};

/// The deep-nesting warnings of `files`, all of them generated.
fn warnings(files: &[(&str, &str)]) -> Vec<Problem> {
    let names: Vec<&str> = files.iter().map(|(name, _)| *name).collect();
    let built = ir::build_with(&pool(files), &names, &Options::default())
        .unwrap_or_else(|d| panic!("{}", elm_connect_gen::diagnostics::render_narrow(&d)));
    built
        .warnings
        .iter()
        .filter(|problem| problem.code() == Code::DeepNesting)
        .cloned()
        .collect()
}

/// A proto of `package` declaring `L<first>` to `L<last>`, each holding the
/// next through the field written by `field` (given the next message's
/// name), and `L<last>` holding what `tail` writes.
fn chain(
    package: &str,
    first: usize,
    last: usize,
    field: fn(&str) -> String,
    tail: &str,
) -> String {
    let mut source = format!("syntax = \"proto3\";\npackage {package};\n{IMPORTS}\n");
    for n in first..last {
        source += &format!("message L{n} {{ {} }}\n", field(&format!("L{}", n + 1)));
    }
    source += &format!("message L{last} {{ {tail} }}\n");
    source
}

const IMPORTS: &str = "import \"google/protobuf/any.proto\";\nimport \"google/protobuf/struct.proto\";\nimport \"other.proto\";";

/// `other.proto`, which `chain`'s protos import, with whatever it declares.
fn other(source: &str) -> String {
    format!("syntax = \"proto3\";\npackage o.v1;\n{source}")
}

fn singular(next: &str) -> String {
    format!("{next} next = 1;")
}

#[test]
fn a_chain_of_100_messages_is_within_the_limit() {
    let source = chain("a.v1", 1, 100, singular, "");
    assert!(warnings(&[("a.proto", &source), ("other.proto", &other(""))]).is_empty());
}

#[test]
fn a_chain_of_101_messages_warns_once_from_its_outermost() {
    let source = chain("a.v1", 1, 101, singular, "");
    let found = warnings(&[("a.proto", &source), ("other.proto", &other(""))]);
    assert_eq!(found.len(), 1, "{found:#?}");
    assert_eq!(
        found[0].message(),
        "The message `a.v1.L1` holds messages nested 101 deep: `a.v1.L1`, `a.v1.L2`, \
         `a.v1.L3`, …, `a.v1.L99`, `a.v1.L100`, `a.v1.L101`."
    );
    assert!(found[0].is_warning());
    assert_eq!(found[0].sites().len(), 1);
    assert_eq!(found[0].sites()[0].file, "a.proto");
}

#[test]
fn every_kind_of_reference_counts() {
    let kinds: [fn(&str) -> String; 4] = [
        singular,
        |next| format!("repeated {next} next = 1;"),
        |next| format!("map<string, {next}> next = 1;"),
        |next| format!("oneof kind {{ {next} next = 1; string name = 2; }}"),
    ];
    for kind in kinds {
        let source = chain("a.v1", 1, 101, kind, "");
        let found = warnings(&[("a.proto", &source), ("other.proto", &other(""))]);
        assert_eq!(found.len(), 1, "{source}");
    }
}

#[test]
fn messages_of_another_package_count() {
    // `a.v1.L1` to `L59`, then `o.v1.L60` to `L101`.
    let source = chain("a.v1", 1, 59, singular, "o.v1.L60 next = 1;");
    let tail = chain("o.v1", 60, 101, singular, "");
    let tail = tail
        .split_once(IMPORTS)
        .map(|(_, rest)| rest)
        .expect("the imports");
    let found = warnings(&[("a.proto", &source), ("other.proto", &other(tail))]);
    assert_eq!(found.len(), 1, "{found:#?}");
    assert!(
        found[0]
            .message()
            .starts_with("The message `a.v1.L1` holds messages nested 101 deep"),
        "{}",
        found[0].message()
    );
    assert!(found[0].message().ends_with("`o.v1.L101`."));
}

#[test]
fn a_well_known_type_ends_a_chain() {
    for tail in [
        "google.protobuf.Any next = 1;",
        "google.protobuf.Struct next = 1;",
        "google.protobuf.Value next = 1;",
        "google.protobuf.ListValue next = 1;",
    ] {
        let source = chain("a.v1", 1, 100, singular, tail);
        assert!(
            warnings(&[("a.proto", &source), ("other.proto", &other(""))]).is_empty(),
            "{tail}"
        );
    }
}

#[test]
fn a_cycle_counts_its_members_once_and_is_named() {
    // 98 messages, then `C1` and `C2`, which hold each other: 100.
    let cycle = "message C1 { C2 next = 1; } message C2 { C1 back = 1; }";
    let within = chain("a.v1", 1, 98, singular, "C1 next = 1;") + cycle;
    assert!(warnings(&[("a.proto", &within), ("other.proto", &other(""))]).is_empty());
    let past = chain("a.v1", 1, 99, singular, "C1 next = 1;") + cycle;
    let found = warnings(&[("a.proto", &past), ("other.proto", &other(""))]);
    assert_eq!(found.len(), 1, "{found:#?}");
    assert_eq!(
        found[0].message(),
        "The message `a.v1.L1` holds messages nested 101 deep: `a.v1.L1`, `a.v1.L2`, \
         `a.v1.L3`, …, `a.v1.L99`, `a.v1.C1`, `a.v1.C2`. It passes through `a.v1.C1`, which \
         is on a cycle of references, so it can nest deeper still."
    );
}

#[test]
fn the_longest_of_two_chains_is_named() {
    let short = chain("a.v1", 1, 101, singular, "");
    let long = chain("o.v1", 1, 120, singular, "");
    let long = long
        .split_once(IMPORTS)
        .map(|(_, rest)| rest)
        .expect("the imports");
    let found = warnings(&[("a.proto", &short), ("other.proto", &other(long))]);
    assert_eq!(found.len(), 1, "{found:#?}");
    assert!(
        found[0]
            .message()
            .starts_with("The message `o.v1.L1` holds messages nested 120 deep"),
        "{}",
        found[0].message()
    );
}

/// `deep/v1/chain.proto`: `Level1` to `Level<length>`, one message to a
/// few lines, each holding the next, and the last holding what `tail`
/// writes; then `after`.
fn levels(length: usize, tail: &str, after: &str) -> String {
    let mut source = "syntax = \"proto3\";\n\npackage deep.v1;\n".to_owned();
    for n in 1..length {
        source += &format!("\nmessage Level{n} {{\n  Level{} next = 1;\n}}\n", n + 1);
    }
    source += &format!("\nmessage Level{length} {{\n  {tail}\n}}\n{after}");
    source
}

/// What generating `deep/v1/chain.proto` warns, rendered as the corpus
/// renders a `warnings.txt`. Generating succeeds, with exactly one warning.
fn rendered_warning(source: &str) -> String {
    let files = [("deep/v1/chain.proto", source)];
    let generated =
        elm_connect_gen::generate(&pool(&files), &["deep/v1/chain.proto"], &Options::default())
            .unwrap_or_else(|d| panic!("{}", render(&d, &files)));
    assert_eq!(
        generated.warnings.len(),
        1,
        "{}",
        render(&generated.warnings, &files)
    );
    render(&generated.warnings, &files)
}

#[test]
fn the_warning_renders_with_its_site_and_help() {
    let source = levels(101, "", "");
    assert_eq!(rendered_warning(&source), RENDERED);
}

const RENDERED: &str = r#"types::deep_nesting

  ⚠ The message `deep.v1.Level1` holds messages nested 101 deep:
  │ `deep.v1.Level1`, `deep.v1.Level2`, `deep.v1.Level3`, …,
  │ `deep.v1.Level99`, `deep.v1.Level100`, `deep.v1.Level101`.
   ╭─[deep/v1/chain.proto:5:9]
 4 │
 5 │ message Level1 {
   ·         ───┬──
   ·            ╰── the chain starts here
 6 │   Level2 next = 1;
   ╰────
  help: Most protobuf runtimes refuse to parse a message nested more than 100
        deep, so a server or client on one of them fails on a message that
        fills this chain. elm-connect's reads count only the messages on a
        cycle of references, so they read it to its end, and a chain deep
        enough overflows the JavaScript stack. Shorten the chain to 100
        messages: merge levels into one message, or hold the deep part as
        `bytes`.
"#;

#[test]
fn the_warning_renders_the_cycle_it_passes_through() {
    let cycle =
        "\nmessage Loop1 {\n  Loop2 next = 1;\n}\n\nmessage Loop2 {\n  Loop1 back = 1;\n}\n";
    let source = levels(99, "Loop1 next = 1;", cycle);
    assert_eq!(rendered_warning(&source), RENDERED_CYCLE);
}

const RENDERED_CYCLE: &str = r#"types::deep_nesting

  ⚠ The message `deep.v1.Level1` holds messages nested 101 deep:
  │ `deep.v1.Level1`, `deep.v1.Level2`, `deep.v1.Level3`, …,
  │ `deep.v1.Level99`, `deep.v1.Loop1`, `deep.v1.Loop2`. It passes through
  │ `deep.v1.Loop1`, which is on a cycle of references, so it can nest deeper
  │ still.
   ╭─[deep/v1/chain.proto:5:9]
 4 │
 5 │ message Level1 {
   ·         ───┬──
   ·            ╰── the chain starts here
 6 │   Level2 next = 1;
   ╰────
  help: Most protobuf runtimes refuse to parse a message nested more than 100
        deep, so a server or client on one of them fails on a message that
        fills this chain. elm-connect's reads count only the messages on a
        cycle of references, so they read it to its end, and a chain deep
        enough overflows the JavaScript stack. Shorten the chain to 100
        messages: merge levels into one message, or hold the deep part as
        `bytes`.
"#;
