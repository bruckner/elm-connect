//! The corpus cases `depth_cycles` and `depth_cycles_keep`, which hold every
//! shape of a cycle of references, generated again with their options and a
//! module prefix into `tests/Deep/` and `tests/DeepKeep/`, where
//! `tests/Proto/DepthTest.elm` reads each shape at the depth limit and past
//! it. `just bless` writes them.

mod common;

use std::fs;

use common::{case_parameter, compile_case, placeholder_header, repo_root};
use elm_connect_gen::{Options, generate};
use similar::TextDiff;

fn blessing() -> bool {
    std::env::var_os("ELM_CONNECT_BLESS").is_some_and(|v| v == "1")
}

/// The modules of `case` under its options and `module_prefix=prefix`, held
/// to the files under `tests/`, or written there when blessing.
fn current(case: &str, prefix: &str) -> Vec<String> {
    let case = repo_root().join("conformance/cases").join(case);
    let compiled = compile_case(&case);
    let parameter = match case_parameter(&case) {
        options if options.is_empty() => format!("module_prefix={prefix}"),
        options => format!("{options},module_prefix={prefix}"),
    };
    let options = Options::from_parameter(&parameter)
        .unwrap_or_else(|d| panic!("{}", elm_connect_gen::diagnostics::render_narrow(&d)));
    let names: Vec<&str> = compiled.names.iter().map(String::as_str).collect();
    let generated = generate(&compiled.compiler.descriptor_pool(), &names, &options)
        .unwrap_or_else(|d| panic!("{}", elm_connect_gen::diagnostics::render_narrow(&d)));
    generated
        .files
        .iter()
        .filter_map(|module| {
            let file = repo_root().join("tests").join(&module.path);
            let content = placeholder_header(&module.content);
            if blessing() {
                fs::create_dir_all(file.parent().expect("a parent")).expect("create");
                fs::write(&file, &content).expect("write");
                return None;
            }
            let want = fs::read_to_string(&file).unwrap_or_default();
            (want != content).then(|| {
                TextDiff::from_lines(want.as_str(), content.as_str())
                    .unified_diff()
                    .header(&module.path, &module.path)
                    .to_string()
            })
        })
        .collect()
}

#[test]
fn the_cycle_shapes_are_current() {
    let mut failures = current("depth_cycles", "Deep");
    failures.extend(current("depth_cycles_keep", "DeepKeep"));
    assert!(
        failures.is_empty(),
        "the cycle shapes under tests/Deep and tests/DeepKeep are stale; run `just bless`:\n{}",
        failures.join("\n")
    );
}
