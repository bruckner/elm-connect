//! The version numbers that must move together (design §8.1, §8.2): the
//! Cargo workspace's version, `elm.json`'s, the newest value of the
//! runtime's `Proto.Version`, which generated code names
//! (`elm_connect_gen::SENTINEL`), and the corpus's header placeholder.

use std::fs;
use std::path::{Path, PathBuf};

use elm_connect_gen::{HEADER_PREFIX, HEADER_VERSION_PLACEHOLDER, SENTINEL, VERSION};

mod common;
use common::{cases, files_under, is_diagnostics_case, repo_root};

fn read(path: &Path) -> String {
    fs::read_to_string(path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()))
}

/// The value of `key = "..."` in the `[section]` table of a TOML file, read
/// textually: the files are this repository's own, one key per line.
fn toml_string(path: &Path, section: &str, key: &str) -> String {
    let text = read(path);
    let mut inside = false;
    for line in text.lines() {
        let line = line.trim();
        if line.starts_with('[') {
            inside = line == format!("[{section}]");
            continue;
        }
        if !inside {
            continue;
        }
        if let Some((name, value)) = line.split_once('=')
            && name.trim() == key
        {
            let value = value.trim();
            return value
                .strip_prefix('"')
                .and_then(|v| v.split_once('"'))
                .map(|(v, _)| v.to_owned())
                .unwrap_or_else(|| panic!("{}: {key} is not a string: {value}", path.display()));
        }
    }
    panic!("{}: no {key} under [{section}]", path.display())
}

fn major_minor(version: &str) -> (u32, u32) {
    let mut parts = version.split('.');
    let mut next = || {
        parts
            .next()
            .and_then(|p| p.parse().ok())
            .unwrap_or_else(|| panic!("not a version: {version}"))
    };
    (next(), next())
}

/// `v{major}_{minor}` as numbers.
fn sentinel_version(name: &str) -> Option<(u32, u32)> {
    let (major, minor) = name.strip_prefix('v')?.split_once('_')?;
    Some((major.parse().ok()?, minor.parse().ok()?))
}

#[test]
fn the_crates_and_the_package_share_one_version() {
    let root = repo_root();
    let workspace = toml_string(&root.join("Cargo.toml"), "workspace.package", "version");
    assert_eq!(
        workspace, VERSION,
        "the crates build from the workspace's version"
    );
    let elm: serde_json::Value =
        serde_json::from_str(&read(&root.join("elm.json"))).expect("elm.json is JSON");
    assert_eq!(
        elm["version"].as_str(),
        Some(workspace.as_str()),
        "elm.json's version is the Cargo workspace's (design §8.1)"
    );
}

#[test]
fn proto_version_exposes_the_sentinel_and_every_earlier_minor() {
    let path = repo_root().join("src/Proto/Version.elm");
    let source = read(&path);
    let header = source
        .strip_prefix("module Proto.Version exposing (")
        .and_then(|rest| rest.split_once(')'))
        .map(|(list, _)| list)
        .unwrap_or_else(|| panic!("{}: no exposing list on its first line", path.display()));
    let exposed: Vec<&str> = header.split(',').map(str::trim).collect();
    let values: Vec<(u32, u32)> = exposed
        .iter()
        .filter(|name| **name != "Generated")
        .map(|name| sentinel_version(name).unwrap_or_else(|| panic!("exposes {name}")))
        .collect();

    let (major, minor) = major_minor(VERSION);
    assert_eq!(sentinel_version(SENTINEL), Some((major, minor)));
    // A major's first release is its .0, but for 0, whose first is 0.1.
    let first = if major == 0 { 1 } else { 0 };
    let mut want: Vec<(u32, u32)> = (first..=minor).map(|m| (major, m)).collect();
    let mut have = values.clone();
    want.sort();
    have.sort();
    assert_eq!(
        have, want,
        "Proto.Version exposes {exposed:?}; generated code names {SENTINEL}, so it must expose \
         that value and every earlier one of major {major}, and no other (design §8.2)"
    );
    for name in exposed.iter().filter(|name| **name != "Generated") {
        assert!(
            source.contains(&format!("\n{name} : Generated\n{name} =\n")),
            "{name} is exposed but not defined as a Generated value"
        );
    }
}

#[test]
fn the_corpus_placeholder_is_the_sentinels_release() {
    let (major, minor) = major_minor(VERSION);
    assert_eq!(HEADER_VERSION_PLACEHOLDER, format!("{major}.{minor}.X"));
    let header = format!("-- {HEADER_PREFIX}{HEADER_VERSION_PLACEHOLDER} ");
    let sentinel = format!("    Proto.Version.{SENTINEL}\n");
    let modules: Vec<PathBuf> = cases()
        .into_iter()
        .filter(|case| !is_diagnostics_case(case))
        .flat_map(|case| {
            let expected = case.join("expected");
            files_under(&expected)
                .into_iter()
                .filter(|path| path.ends_with(".elm"))
                .map(move |path| expected.join(path))
        })
        .collect();
    assert!(!modules.is_empty());
    let mut naming_the_sentinel = 0;
    for module in &modules {
        let text = read(module);
        assert!(
            text.starts_with(&header),
            "{} does not open with {header:?}; run `just bless`",
            module.display()
        );
        if text.contains("elmConnectVersion_ =\n") {
            naming_the_sentinel += 1;
            assert!(
                text.contains(&sentinel),
                "{} names another Proto.Version value than {SENTINEL}; run `just bless`",
                module.display()
            );
        }
    }
    assert!(
        naming_the_sentinel > 0,
        "no expected module names the sentinel"
    );
}
