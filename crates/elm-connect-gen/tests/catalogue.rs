//! `docs/diagnostics.md` lists every diagnostic code: one table row per
//! code, and no row for a code the generator does not have, so adding or
//! renaming a code without its row fails here.

use std::collections::BTreeSet;
use std::path::Path;

use elm_connect_gen::diagnostics::Code;

/// The code of each row of the catalogue's table whose first cell is a
/// code in backticks (`` | `naming::type_collision` | ``), in order. A
/// family's heading row has its name in bold and is not one.
fn catalogued() -> Vec<String> {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../docs/diagnostics.md");
    let text =
        std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()));
    text.lines()
        .filter_map(|line| line.strip_prefix("| `"))
        .filter_map(|rest| rest.split_once("` |"))
        .map(|(code, _)| code.to_owned())
        .collect()
}

#[test]
fn the_catalogue_lists_every_code_once() {
    let rows = catalogued();
    let listed: BTreeSet<&str> = rows.iter().map(String::as_str).collect();
    assert_eq!(listed.len(), rows.len(), "a code has two rows: {rows:?}");
    let codes: BTreeSet<&str> = Code::ALL.iter().map(|code| code.as_str()).collect();
    assert_eq!(codes.len(), Code::ALL.len(), "two codes render alike");
    let missing: Vec<&&str> = codes.difference(&listed).collect();
    let extra: Vec<&&str> = listed.difference(&codes).collect();
    assert!(
        missing.is_empty() && extra.is_empty(),
        "docs/diagnostics.md lacks a row for {missing:?} and has a row for {extra:?}, \
         which is no code"
    );
}

#[test]
fn each_code_is_listed_under_its_family() {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../docs/diagnostics.md");
    let text = std::fs::read_to_string(path).expect("the catalogue");
    let mut family = None;
    for line in text.lines() {
        if let Some(heading) = line.strip_prefix("| **`") {
            family = heading.split_once("`**").map(|(name, _)| name.to_owned());
        } else if let Some((code, _)) = line.strip_prefix("| `").and_then(|r| r.split_once("` |")) {
            let family = family.as_deref().expect("a family heading before any code");
            assert!(code.starts_with(family), "{code} is listed under {family}");
        }
    }
}
