//! The corpus cases `depth_cycles`, which holds every shape of a cycle of
//! references, and `depth_cycles_keep`, two of them under
//! `unknown_fields=keep`, generated again with their options and the module
//! prefixes `Generated.Deep` and `Generated.DeepKeep`, so that
//! `tests/Proto/DepthTest.elm` can read each shape at the depth limit and
//! past it. They are written under `tests/Generated/`, which is gitignored
//! and rewritten by every run of this test, as the codec test's modules
//! are (`just tests-gen` runs both): the generated text is reviewed once,
//! in the corpus.

mod common;

use std::fs;

use common::{case_parameter, compile_case, files_under, repo_root};
use elm_connect_gen::{Options, generate};

/// Writes the modules of `case` under its options and `module_prefix=prefix`
/// into `tests/`, each only if it does not hold them already, so a run that
/// changes nothing leaves the Elm compiler's cache valid, and removes any
/// other module under the prefix's directory, left from an earlier
/// generator or proto, which would still compile into the Elm tests.
fn write(case: &str, prefix: &str) {
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
    let tests = repo_root().join("tests");
    let dir = prefix.replace('.', "/");
    let mut written = Vec::new();
    for module in &generated.files {
        let relative = module
            .path
            .strip_prefix(&format!("{dir}/"))
            .unwrap_or_else(|| panic!("{} is outside tests/{dir}", module.path));
        let file = tests.join(&module.path);
        if !fs::read_to_string(&file).is_ok_and(|have| have == module.content) {
            fs::create_dir_all(file.parent().expect("a parent")).expect("create");
            fs::write(&file, &module.content)
                .unwrap_or_else(|e| panic!("write {}: {e}", file.display()));
        }
        written.push(relative.to_owned());
    }
    let root = tests.join(&dir);
    for stale in files_under(&root)
        .into_iter()
        .filter(|path| !written.contains(path))
    {
        fs::remove_file(root.join(&stale)).expect("remove a stale module");
    }
}

#[test]
fn the_cycle_shapes_are_written() {
    write("depth_cycles", "Generated.Deep");
    write("depth_cycles_keep", "Generated.DeepKeep");
}
