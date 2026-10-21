//! The printer against the real tools: a corpus of modules shaped like
//! generated code must be byte-for-byte what elm-format 0.8.8 produces
//! (`elm-format --validate`) and must compile with `elm make` against
//! elm/core and elm/json.
//!
//! Both tools come from `mise.toml`; the tests fail, rather than skip,
//! when either is missing from PATH.

use std::fs;
use std::io::{ErrorKind, Write as _};
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};

use elm_connect_gen::elm::ast::{
    BinOp, Decl, Exposed, Exposing, Expr, Import, LetBinding, Module, ModuleName, Pattern, Type,
    Variant,
};
use elm_connect_gen::elm::build::*;
use elm_connect_gen::elm::print::print_module;

// Running the tools.

fn run(cmd: &mut Command, stdin: Option<&str>) -> Output {
    let program = cmd.get_program().to_string_lossy().into_owned();
    cmd.stdin(if stdin.is_some() {
        Stdio::piped()
    } else {
        Stdio::null()
    })
    .stdout(Stdio::piped())
    .stderr(Stdio::piped());
    let mut child = match cmd.spawn() {
        Ok(child) => child,
        Err(e) if e.kind() == ErrorKind::NotFound => panic!(
            "`{program}` is not on PATH. It is pinned in mise.toml: run `mise install` and \
             run the tests through mise (`just test`, or `mise exec -- cargo test`)."
        ),
        Err(e) => panic!("could not start `{program}`: {e}"),
    };
    if let Some(input) = stdin {
        child
            .stdin
            .take()
            .expect("stdin is piped")
            .write_all(input.as_bytes())
            .expect("write to stdin");
    }
    child.wait_with_output().expect("wait for the tool")
}

fn scratch(name: &str) -> PathBuf {
    let dir = Path::new(env!("CARGO_TARGET_TMPDIR")).join(name);
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).expect("create scratch directory");
    dir
}

/// Write each module to `src/` under `root`, at the path its name implies.
fn write_modules(root: &Path, modules: &[(String, String)]) -> Vec<PathBuf> {
    modules
        .iter()
        .map(|(name, source)| {
            let path = root
                .join("src")
                .join(format!("{}.elm", name.replace('.', "/")));
            fs::create_dir_all(path.parent().expect("module path has a parent"))
                .expect("create module directory");
            fs::write(&path, source).expect("write module");
            path
        })
        .collect()
}

/// The first line where `ours` and `theirs` differ, with context.
fn first_difference(ours: &str, theirs: &str) -> String {
    let ours: Vec<&str> = ours.lines().collect();
    let theirs: Vec<&str> = theirs.lines().collect();
    let at = ours
        .iter()
        .zip(&theirs)
        .position(|(a, b)| a != b)
        .unwrap_or(ours.len().min(theirs.len()));
    let from = at.saturating_sub(3);
    let show = |lines: &[&str]| {
        lines
            .iter()
            .enumerate()
            .skip(from)
            .take(at - from + 4)
            .map(|(i, l)| format!("{:>4} | {l}", i + 1))
            .collect::<Vec<_>>()
            .join("\n")
    };
    format!(
        "first difference at line {}\n--- printer\n{}\n--- elm-format\n{}",
        at + 1,
        show(&ours),
        show(&theirs)
    )
}

fn assert_canonical(modules: &[(String, String)], scratch_name: &str) {
    let root = scratch(scratch_name);
    let paths = write_modules(&root, modules);
    for ((name, source), path) in modules.iter().zip(&paths) {
        // `--stdin` shows what elm-format would have written instead, which
        // `--validate` does not.
        let formatted = run(Command::new("elm-format").arg("--stdin"), Some(source));
        assert!(
            formatted.status.success(),
            "elm-format could not parse {name}:\n{}\n{source}",
            String::from_utf8_lossy(&formatted.stderr)
        );
        let formatted = String::from_utf8(formatted.stdout).expect("elm-format prints UTF-8");
        assert!(
            *source == formatted,
            "{name} is not in elm-format's layout; {}",
            first_difference(source, &formatted)
        );
        let validate = run(Command::new("elm-format").arg("--validate").arg(path), None);
        assert!(
            validate.status.success(),
            "elm-format --validate rejected {name}:\n{}{}",
            String::from_utf8_lossy(&validate.stdout),
            String::from_utf8_lossy(&validate.stderr)
        );
    }
}

fn assert_compiles(modules: &[(String, String)], scratch_name: &str) {
    let root = scratch(scratch_name);
    // The harness's dependencies, with this scratch project's `src` as the
    // only source directory.
    let harness = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../conformance/harness/elm.json");
    let harness = fs::read_to_string(&harness).expect("read the harness elm.json");
    let sources = harness
        .find("\"source-directories\"")
        .and_then(|start| Some(start..start + harness[start..].find(']')? + 1))
        .expect("the harness elm.json lists source directories");
    let mut elm_json = harness.clone();
    elm_json.replace_range(sources, "\"source-directories\": [\"src\"]");
    fs::write(root.join("elm.json"), elm_json).expect("write elm.json");
    let paths = write_modules(&root, modules);
    // A bare `elm make` resolves dependencies and writes elm-stuff before
    // the real build, avoiding the first-build d.dat race the Justfile
    // describes. Its failure (no input files) is expected.
    let _ = run(Command::new("elm").arg("make").current_dir(&root), None);
    let build = run(
        Command::new("elm")
            .arg("make")
            .args(&paths)
            .arg("--output=/dev/null")
            .current_dir(&root),
        None,
    );
    assert!(
        build.status.success(),
        "elm make rejected the corpus:\n{}{}",
        String::from_utf8_lossy(&build.stdout),
        String::from_utf8_lossy(&build.stderr)
    );
}

// The corpus.

const ENCODE: &str = "Json.Encode";
const DECODE: &str = "Json.Decode";

fn import(module: &str, alias: Option<&str>, exposing: Option<Exposing>) -> Import {
    Import {
        module: ModuleName::new(module),
        alias: alias.map(str::to_owned),
        exposing,
    }
}

fn value(name: &str, annotation: Type, params: Vec<Pattern>, body: Expr) -> Decl {
    Decl::Value {
        doc: None,
        name: name.to_owned(),
        annotation,
        params,
        body,
    }
}

fn int_t() -> Type {
    ty("Int", [])
}

fn string_t() -> Type {
    ty("String", [])
}

fn variant(name: &str, args: Vec<Type>) -> Variant {
    Variant {
        name: name.to_owned(),
        args,
    }
}

fn types_module() -> Module {
    let note_fields = vec![
        ("name", string_t()),
        ("title", string_t()),
        ("revision", int_t()),
        ("pinned", ty("Bool", [])),
        ("score", ty("Float", [])),
        ("tags", ty("List", [string_t()])),
        ("parent", ty("Maybe", [ty("NoteRef", [])])),
        (
            "counts",
            ty_qualified("Dict", "Dict", [string_t(), int_t()]),
        ),
        ("status", ty("Status", [])),
        ("bounds", Type::Tuple(vec![int_t(), int_t()])),
    ];
    Module {
        header: None,
        name: ModuleName::new("Gen.Types"),
        doc: Some("Types for `notes.v1`.\n\n    code stays verbatim\n".to_owned()),
        exposing: Exposing::Explicit(vec![
            Exposed::Type("Note".into()),
            Exposed::TypeWithCtors("Status".into()),
            Exposed::Type("NoteRef".into()),
            Exposed::TypeWithCtors("Tree".into()),
            Exposed::Type("Empty".into()),
            Exposed::Type("Handler".into()),
        ]),
        imports: vec![import("Dict", None, None)],
        decls: vec![
            Decl::Comment("TYPES".into()),
            Decl::TypeAlias {
                doc: Some("A note, with ten fields.".into()),
                name: "Note".into(),
                type_params: vec![],
                body: Type::Record(
                    note_fields
                        .into_iter()
                        .map(|(n, t)| (n.to_owned(), t))
                        .collect(),
                ),
            },
            Decl::TypeAlias {
                doc: None,
                name: "NoteRef".into(),
                type_params: vec![],
                body: Type::Record(vec![("name".into(), string_t())]),
            },
            Decl::TypeAlias {
                doc: None,
                name: "Empty".into(),
                type_params: vec![],
                body: Type::Record(vec![]),
            },
            Decl::CustomType {
                doc: Some("Lifecycle.".into()),
                name: "Status".into(),
                type_params: vec![],
                variants: vec![
                    variant("StatusUnspecified", vec![]),
                    variant("StatusActive", vec![]),
                    variant("StatusArchived", vec![ty("Maybe", [int_t()])]),
                ],
            },
            Decl::CustomType {
                doc: None,
                name: "Tree".into(),
                type_params: vec!["a".into()],
                variants: vec![
                    variant("Leaf", vec![]),
                    variant(
                        "Node",
                        vec![
                            ty("Tree", [ty_var("a")]),
                            ty_var("a"),
                            ty("Tree", [ty_var("a")]),
                        ],
                    ),
                ],
            },
            Decl::TypeAlias {
                doc: None,
                name: "Handler".into(),
                type_params: vec!["msg".into()],
                body: ty_fn(
                    [ty_fn([string_t()], ty_var("msg")), ty("List", [int_t()])],
                    ty("Maybe", [ty_var("msg")]),
                ),
            },
        ],
    }
}

fn types(name: &str) -> Expr {
    qualified("Gen.Types", name)
}

fn types_t(name: &str) -> Type {
    ty_qualified("Gen.Types", name, [])
}

fn codecs_module() -> Module {
    let encode = |f: &str| qualified(ENCODE, f);
    let decode = |f: &str| qualified(DECODE, f);
    let note = || var("note");
    let field_of = |f: &str| access(note(), f);

    // Json.Encode.object [ ( "name", Json.Encode.string note.name ), ... ]
    let encode_note = apply(
        encode("object"),
        [list([
            tuple2(string("name"), apply(encode("string"), [field_of("name")])),
            tuple2(
                string("revision"),
                apply(encode("int"), [field_of("revision")]),
            ),
            tuple2(
                string("tags"),
                apply(encode("list"), [encode("string"), field_of("tags")]),
            ),
            tuple2(
                string("parent"),
                apply(
                    var("Maybe.withDefault"),
                    [
                        encode("null"),
                        apply(var("Maybe.map"), [var("encodeNoteRef"), field_of("parent")]),
                    ],
                ),
            ),
            tuple2(
                string("status"),
                apply(var("encodeStatus"), [field_of("status")]),
            ),
        ])],
    );

    // decodeNote = Json.Decode.succeed Note |> andMap (...) |> ...
    let step = |name: &str, decoder: Expr| {
        apply(
            var("andMap"),
            [apply(decode("field"), [string(name), decoder])],
        )
    };
    let decode_note = pipeline(
        apply(decode("succeed"), [types("Note")]),
        [
            step("name", decode("string")),
            step("title", decode("string")),
            step("revision", decode("int")),
            step("pinned", decode("bool")),
            step("score", decode("float")),
            step("tags", apply(decode("list"), [decode("string")])),
            step(
                "parent",
                apply(
                    decode("maybe"),
                    [apply(
                        decode("lazy"),
                        [lambda([Pattern::Wildcard], var("decodeNoteRef"))],
                    )],
                ),
            ),
            step("counts", apply(decode("dict"), [decode("int")])),
            step("status", var("decodeStatus")),
            step(
                "bounds",
                apply(
                    decode("map2"),
                    [
                        var("Tuple.pair"),
                        apply(decode("index"), [int(0), decode("int")]),
                        apply(decode("index"), [int(1), decode("int")]),
                    ],
                ),
            ),
        ],
    );

    let status = |name: &str| Pattern::Ctor {
        module: Some("Gen.Types".into()),
        name: name.to_owned(),
        args: vec![],
    };
    let encode_status = apply(
        encode("string"),
        [case(
            var("status"),
            [
                (status("StatusUnspecified"), string("STATUS_UNSPECIFIED")),
                (status("StatusActive"), string("STATUS_ACTIVE")),
                (
                    Pattern::Ctor {
                        module: Some("Gen.Types".into()),
                        name: "StatusArchived".into(),
                        args: vec![Pattern::Wildcard],
                    },
                    string("STATUS_ARCHIVED"),
                ),
            ],
        )],
    );

    // Json.Decode.string |> Json.Decode.andThen (\s -> case s of ...)
    let decode_status = pipe(
        decode("string"),
        apply(
            decode("andThen"),
            [lambda(
                [pvar("s")],
                case(
                    var("s"),
                    [
                        (
                            Pattern::Str("STATUS_ACTIVE".into()),
                            apply(decode("succeed"), [types("StatusActive")]),
                        ),
                        (
                            Pattern::Str("STATUS_ARCHIVED".into()),
                            apply(
                                decode("succeed"),
                                [apply(types("StatusArchived"), [var("Nothing")])],
                            ),
                        ),
                        (
                            Pattern::Wildcard,
                            apply(decode("succeed"), [types("StatusUnspecified")]),
                        ),
                    ],
                ),
            )],
        ),
    );

    let decode_note_ref = apply(
        decode("map"),
        [
            lambda([pvar("name")], record([("name", var("name"))])),
            apply(decode("field"), [string("name"), decode("string")]),
        ],
    );

    Module {
        header: Some(
            "Generated by elm-connect from notes.proto. Do not edit; regenerate instead.".into(),
        ),
        name: ModuleName::new("Gen.Codecs"),
        doc: None,
        exposing: Exposing::All,
        imports: vec![
            import(ENCODE, None, None),
            import("Gen.Types", None, None),
            import(DECODE, None, None),
            import(ENCODE, None, None),
        ],
        decls: vec![
            Decl::Comment("ENCODE".into()),
            Decl::Value {
                doc: Some("Encode a note as proto3 JSON.".into()),
                name: "encodeNote".into(),
                annotation: ty_fn([types_t("Note")], ty_qualified(ENCODE, "Value", [])),
                params: vec![pvar("note")],
                body: encode_note,
            },
            value(
                "encodeNoteRef",
                ty_fn([types_t("NoteRef")], ty_qualified(ENCODE, "Value", [])),
                vec![Pattern::Record(vec!["name".into()])],
                apply(
                    encode("object"),
                    [list([tuple2(
                        string("name"),
                        apply(encode("string"), [var("name")]),
                    )])],
                ),
            ),
            value(
                "encodeStatus",
                ty_fn([types_t("Status")], ty_qualified(ENCODE, "Value", [])),
                vec![pvar("status")],
                encode_status,
            ),
            Decl::Comment("DECODE".into()),
            value(
                "decodeNote",
                ty_qualified(DECODE, "Decoder", [types_t("Note")]),
                vec![],
                decode_note,
            ),
            value(
                "decodeNoteRef",
                ty_qualified(DECODE, "Decoder", [types_t("NoteRef")]),
                vec![],
                decode_note_ref,
            ),
            value(
                "decodeStatus",
                ty_qualified(DECODE, "Decoder", [types_t("Status")]),
                vec![],
                decode_status,
            ),
            value(
                "andMap",
                ty_fn(
                    [
                        ty_qualified(DECODE, "Decoder", [ty_var("a")]),
                        ty_qualified(DECODE, "Decoder", [ty_fn([ty_var("a")], ty_var("b"))]),
                    ],
                    ty_qualified(DECODE, "Decoder", [ty_var("b")]),
                ),
                vec![],
                apply(
                    decode("map2"),
                    [lambda(
                        [pvar("value"), pvar("f")],
                        apply(var("f"), [var("value")]),
                    )],
                ),
            ),
        ],
    }
}

fn exprs_module() -> Module {
    let int_fn = |n: usize| ty_fn(std::iter::repeat_n(int_t(), n), int_t());
    let float = |f: f64| Expr::Float(f);
    let x = || var("x");
    let y = || var("y");
    let decls = vec![
        value(
            "escapes",
            string_t(),
            vec![],
            string(
                "quote \" backslash \\ newline \n tab \t return \r nul \u{0} del \u{7f} \
                 nbsp \u{a0} shy \u{ad} zwsp \u{200b} bom \u{feff} line \u{2028} \
                 private \u{e000} accent \u{e9} emoji \u{1f600} apostrophe '",
            ),
        ),
        value(
            "chars",
            ty("List", [ty("Char", [])]),
            vec![],
            list(
                [
                    'a',
                    '\'',
                    '"',
                    '\\',
                    '\n',
                    '\t',
                    '\r',
                    '\u{a0}',
                    '\u{e9}',
                    '\u{1f600}',
                ]
                .map(Expr::Char),
            ),
        ),
        value(
            "floats",
            ty("List", [ty("Float", [])]),
            vec![],
            list([
                float(0.0),
                float(1.0),
                float(1.5),
                float(-2.25),
                float(0.001),
                float(1e20),
                float(1.234_567_890_123_456_8e29),
                float(5e-324),
            ]),
        ),
        value(
            "ints",
            ty("List", [int_t()]),
            vec![],
            list([int(0), int(-1), int(i64::MAX), int(i64::MIN + 1)]),
        ),
        value("single", ty("List", [int_t()]), vec![], list([int(1)])),
        value(
            "lastArgumentSpansLines",
            ty("List", [int_t()]),
            vec![],
            apply(
                var("List.map2"),
                [
                    var("max"),
                    list([int(1), int(2)]),
                    apply(
                        var("List.map"),
                        [apply(var("max"), [int(0)]), list([int(3), int(4)])],
                    ),
                ],
            ),
        ),
        value(
            "stackedApplication",
            ty("List", [int_t()]),
            vec![],
            apply(
                var("List.reverse"),
                [stacked_apply(
                    var("List.map2"),
                    [var("max"), inline_list([int(1)]), list([])],
                )],
            ),
        ),
        value(
            "lastArgumentIsALambda",
            ty_fn([ty("List", [int_t()])], ty("List", [int_t()])),
            vec![],
            apply(
                var("List.map"),
                [lambda(
                    [pvar("x")],
                    case(var("x"), [(Pattern::Wildcard, int(0))]),
                )],
            ),
        ),
        value(
            "leadingArgumentsThenALambda",
            ty("List", [int_t()]),
            vec![],
            apply(
                var("List.foldl"),
                [
                    lambda(
                        [pvar("x"), pvar("acc")],
                        case(var("x"), [(Pattern::Wildcard, var("acc"))]),
                    ),
                    list([]),
                    list([int(1), int(2)]),
                ],
            ),
        ),
        value(
            "twoLeadingArgumentsThenAList",
            ty("List", [int_t()]),
            vec![],
            apply(
                var("List.foldl"),
                [var("(::)"), list([]), list([int(1), int(2)])],
            ),
        ),
        value(
            "nested",
            ty("Maybe", [int_t()]),
            vec![],
            apply(
                var("Maybe.map"),
                [
                    apply(var("max"), [apply(var("negate"), [int(1)])]),
                    apply(
                        var("List.head"),
                        [apply(
                            var("List.map"),
                            [apply(var("min"), [int(3)]), list([int(4)])],
                        )],
                    ),
                ],
            ),
        ),
        value(
            "negation",
            int_fn(1),
            vec![pvar("x")],
            binop(
                BinOp::Sub,
                binop(
                    BinOp::Sub,
                    apply(var("max"), [Expr::Negate(Box::new(x())), int(-1)]),
                    Expr::Negate(Box::new(apply(var("abs"), [x()]))),
                ),
                apply(
                    var("max"),
                    [
                        Expr::Negate(Box::new(Expr::Negate(Box::new(x())))),
                        Expr::Negate(Box::new(int(-2))),
                    ],
                ),
            ),
        ),
        value(
            "arithmetic",
            int_fn(2),
            vec![pvar("x"), pvar("y")],
            binop(
                BinOp::Mul,
                binop(BinOp::Add, x(), y()),
                binop(
                    BinOp::Sub,
                    x(),
                    binop(
                        BinOp::Sub,
                        y(),
                        binop(BinOp::Pow, int(2), binop(BinOp::Pow, x(), int(2))),
                    ),
                ),
            ),
        ),
        value(
            "logic",
            ty_fn([int_t(), int_t()], ty("Bool", [])),
            vec![pvar("x"), pvar("y")],
            binop(
                BinOp::Or,
                binop(
                    BinOp::And,
                    binop(BinOp::Eq, x(), y()),
                    binop(BinOp::Le, binop(BinOp::Add, x(), int(1)), y()),
                ),
                apply(var("not"), [binop(BinOp::Neq, x(), int(0))]),
            ),
        ),
        value(
            "lists",
            ty("List", [string_t()]),
            vec![],
            binop(
                BinOp::Append,
                binop(
                    BinOp::Cons,
                    string("a"),
                    binop(BinOp::Cons, string("b"), list([])),
                ),
                binop(BinOp::Append, list([string("c")]), Expr::List(vec![])),
            ),
        ),
        value(
            "composed",
            int_fn(1),
            vec![],
            binop(
                BinOp::ComposeL,
                binop(BinOp::ComposeR, apply(var("max"), [int(1)]), var("negate")),
                apply(var("min"), [int(9)]),
            ),
        ),
        value(
            "backwards",
            ty("Maybe", [int_t()]),
            vec![],
            binop(
                BinOp::ApL,
                var("Just"),
                binop(BinOp::ApL, apply(var("max"), [int(1)]), int(2)),
            ),
        ),
        value(
            "backwardsLambda",
            ty("List", [int_t()]),
            vec![],
            binop(
                BinOp::ApL,
                apply(
                    var("List.map"),
                    [lambda([pvar("x")], binop(BinOp::Add, x(), int(1)))],
                ),
                list([int(1), int(2)]),
            ),
        ),
        value(
            "backwardsOpenEnd",
            int_fn(1),
            vec![],
            binop(
                BinOp::ApL,
                var("identity"),
                lambda(
                    [pvar("x")],
                    case(x(), [(Pattern::Int(0), int(1)), (Pattern::Wildcard, x())]),
                ),
            ),
        ),
        value(
            "pipedLambda",
            int_fn(1),
            vec![pvar("y")],
            pipe(
                pipe(y(), lambda([pvar("x")], binop(BinOp::Mul, x(), int(2)))),
                lambda([pvar("x")], case(x(), [(Pattern::Wildcard, x())])),
            ),
        ),
        value(
            "pipedCase",
            int_fn(1),
            vec![pvar("y")],
            binop(
                BinOp::Add,
                case(
                    y(),
                    [
                        (Pattern::Int(0), int(1)),
                        (Pattern::Int(7), int(2)),
                        (Pattern::Wildcard, y()),
                    ],
                ),
                int(1),
            ),
        ),
        value(
            "letIn",
            int_fn(1),
            vec![pvar("y")],
            let_in(
                [
                    LetBinding {
                        name: "double".into(),
                        annotation: Some(int_fn(1)),
                        params: vec![pvar("n")],
                        body: binop(BinOp::Mul, var("n"), int(2)),
                    },
                    LetBinding {
                        name: "z".into(),
                        annotation: None,
                        params: vec![],
                        body: apply(var("double"), [y()]),
                    },
                    LetBinding {
                        name: "w".into(),
                        annotation: None,
                        params: vec![],
                        body: if_then_else(
                            binop(BinOp::Gt, var("z"), int(0)),
                            int(1),
                            if_then_else(binop(BinOp::Lt, var("z"), int(0)), int(-1), int(0)),
                        ),
                    },
                ],
                binop(BinOp::Add, var("z"), var("w")),
            ),
        ),
        value(
            "ifArg",
            int_fn(1),
            vec![pvar("y")],
            apply(
                var("max"),
                [
                    if_then_else(binop(BinOp::Gt, y(), int(0)), y(), int(0)),
                    apply(
                        var("Maybe.withDefault"),
                        [int(0), apply(var("List.head"), [list([y()])])],
                    ),
                ],
            ),
        ),
        value(
            "letArg",
            int_fn(1),
            vec![pvar("y")],
            apply(
                var("negate"),
                [let_in(
                    [LetBinding {
                        name: "z".into(),
                        annotation: None,
                        params: vec![],
                        body: y(),
                    }],
                    var("z"),
                )],
            ),
        ),
        value(
            "records",
            ty_fn(
                [types_t("NoteRef")],
                Type::Tuple(vec![
                    types_t("NoteRef"),
                    ty("List", [string_t()]),
                    ty("List", [string_t()]),
                ]),
            ),
            vec![pvar("ref")],
            Expr::Tuple(vec![
                Expr::RecordUpdate {
                    record: "ref".into(),
                    fields: vec![(
                        "name".into(),
                        binop(BinOp::Append, access(var("ref"), "name"), string("!")),
                    )],
                },
                list([
                    access(record([("name", string("n"))]), "name"),
                    access(
                        Expr::RecordUpdate {
                            record: "ref".into(),
                            fields: vec![("name".into(), string("m"))],
                        },
                        "name",
                    ),
                ]),
                apply(
                    var("List.map"),
                    [Expr::Accessor("name".into()), list([var("ref")])],
                ),
            ]),
        ),
        value(
            "recordField",
            ty_fn(
                [ty("Maybe", [int_t()])],
                Type::Record(vec![
                    ("a".into(), int_t()),
                    ("b".into(), ty("List", [int_t()])),
                ]),
            ),
            vec![pvar("m")],
            record([
                (
                    "a",
                    case(
                        var("m"),
                        [
                            (pctor("Just", [pvar("n")]), var("n")),
                            (pctor("Nothing", []), int(0)),
                        ],
                    ),
                ),
                ("b", list([int(1), int(2)])),
            ]),
        ),
        value(
            "patterns",
            ty_fn(
                [Type::Tuple(vec![
                    ty("Maybe", [ty("Maybe", [int_t()])]),
                    Type::Unit,
                ])],
                int_t(),
            ),
            vec![Pattern::Tuple(vec![pvar("m"), Pattern::Unit])],
            case(
                var("m"),
                [
                    (pctor("Just", [pctor("Just", [pvar("n")])]), var("n")),
                    (pctor("Just", [pctor("Nothing", [])]), int(1)),
                    (Pattern::Wildcard, int(0)),
                ],
            ),
        ),
        value(
            "unit",
            ty_fn([Type::Unit], Type::Unit),
            vec![Pattern::Unit],
            Expr::Unit,
        ),
        value(
            "lambdaInRecordList",
            ty("List", [ty_fn([int_t()], int_t())]),
            vec![],
            list([
                lambda([pvar("x")], x()),
                lambda([pvar("x")], case(x(), [(Pattern::Wildcard, int(0))])),
            ]),
        ),
    ];
    Module {
        header: None,
        name: ModuleName::new("Gen.Exprs"),
        doc: Some("Expressions.".into()),
        exposing: Exposing::Explicit(vec![Exposed::Value("escapes".into())]),
        imports: vec![import(
            "Gen.Types",
            None,
            Some(Exposing::Explicit(vec![Exposed::Type("NoteRef".into())])),
        )],
        decls,
    }
}

/// A module with no imports whose first declaration is a section comment,
/// and a trailing comment.
fn bare_module() -> Module {
    Module {
        header: None,
        name: ModuleName::new("Gen.Bare"),
        doc: None,
        exposing: Exposing::All,
        imports: vec![],
        decls: vec![
            Decl::Comment("ONE".into()),
            Decl::Comment("TWO".into()),
            value("answer", int_t(), vec![], int(42)),
            Decl::Comment("END".into()),
        ],
    }
}

/// Random trees of operators and applications over `Int`, from a fixed
/// seed: the printer must parenthesize each so it parses (elm-format) and
/// type-checks (elm make), and without parentheses elm-format would drop.
fn random_module() -> Module {
    struct Rng(u64);
    impl Rng {
        fn below(&mut self, n: u64) -> u64 {
            // Knuth's MMIX linear congruential generator.
            self.0 = self
                .0
                .wrapping_mul(6_364_136_223_846_793_005)
                .wrapping_add(1_442_695_040_888_963_407);
            (self.0 >> 33) % n
        }
    }
    const OPS: [BinOp; 7] = [
        BinOp::Add,
        BinOp::Sub,
        BinOp::Mul,
        BinOp::IDiv,
        BinOp::Pow,
        BinOp::ApR,
        BinOp::ApL,
    ];
    fn gen_expr(rng: &mut Rng, depth: u32) -> Expr {
        if depth == 0 {
            return match rng.below(4) {
                0 => var("x"),
                1 => int(i64::try_from(rng.below(5)).expect("small")),
                2 => Expr::Negate(Box::new(var("x"))),
                _ => int(-3),
            };
        }
        match rng.below(8) {
            0 => apply(
                var("max"),
                [gen_expr(rng, depth - 1), gen_expr(rng, depth - 1)],
            ),
            1 => apply(var("negate"), [gen_expr(rng, depth - 1)]),
            2 => Expr::Negate(Box::new(apply(var("abs"), [gen_expr(rng, depth - 1)]))),
            3 => lambda_applied(rng, depth),
            _ => {
                let op = OPS[usize::try_from(rng.below(OPS.len() as u64)).expect("small")];
                let (a, b) = (gen_expr(rng, depth - 1), gen_expr(rng, depth - 1));
                match op {
                    BinOp::ApR => pipe(a, apply(var("max"), [b])),
                    BinOp::ApL => binop(BinOp::ApL, apply(var("min"), [a]), b),
                    op => binop(op, a, b),
                }
            }
        }
    }
    fn lambda_applied(rng: &mut Rng, depth: u32) -> Expr {
        let f = lambda(
            [pvar("y")],
            binop(BinOp::Add, var("y"), gen_expr(rng, depth - 1)),
        );
        let arg = gen_expr(rng, depth - 1);
        if rng.below(2) == 0 {
            apply(f, [arg])
        } else {
            pipe(arg, f)
        }
    }
    let mut rng = Rng(0x5eed);
    let decls = (0..60)
        .map(|i| {
            let depth = 1 + u32::try_from(rng.below(4)).expect("small");
            value(
                &format!("r{i}"),
                ty_fn([int_t()], int_t()),
                vec![pvar("x")],
                gen_expr(&mut rng, depth),
            )
        })
        .collect();
    Module {
        header: None,
        name: ModuleName::new("Gen.Random"),
        doc: None,
        exposing: Exposing::All,
        imports: vec![],
        decls,
    }
}

/// Doc comments the printer puts in elm-format's Markdown: every construct
/// elm-format rewrites, and every hazard the printer departs from it on
/// (`elm::markdown`), as proto comments may hold them.
const DOCS: &[&str] = &[
    "Items:\n\n* one\n* two\n\nMixed:\n\n+ one\n- two\n\n  continued",
    "Steps:\n\n3. three\n4) four\n\n10. ten\n11. eleven",
    "Some *em*, _em_, **strong**, __strong__, ***both***.",
    "snake_case, 2*3*4, notes/* and a \\ backslash and a ` tick",
    "Intro.\n\nHeading\n=======\n\n## Sub ##\n\nText.",
    "# A heading first",
    "Indented:\n\n    GET /v1/notes\n    x = 1\n\nAfter.",
    "```\nGET /v1/{name=notes/*}\n```\n\n```elm\nx = { a = 1 }\n```\n\n~~~proto\nmessage M {}\n~~~",
    "Empty:\n\n```text\n```",
    "```\nunclosed",
    "* item\n```elm\nx = 1\n```\n``` \nnever closed, then blank lines\n\n\n\n\n\n\n\n\n\n",
    "~~~\n```\n~~~",
    "| a | b |\n|---|---|\n| 1 | 2 |\n\na | b",
    "line one  \nline two\twith a tab",
    "<b>bold</b> &amp; <div>x</div>\n\n<div>\nblock\n</div>",
    "[text](https://example.com/a_b), https://example.com/bare and <https://a.b>",
    "[text][r]\n\n[r]: https://example.com \"T\"\n\n[s]: /u junk",
    "Text.\n@docs foo, bar\nmore\n\n  @docs indented",
    "Closes -} and opens {- and {-| and -}-}.",
    "-} at the start",
    "> quoted\n> text\n>\n> # heading",
    "- item\n\n  # heading in an item\n\n  Setext in an item\n  ---",
    "a\n\n***\n\nb\n\n- - -",
    "A line of two hundred characters, which elm-format leaves as it is rather than \
     wrapping it, since it reflows no paragraph of a doc comment at all, however long \
     it runs: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
    "Non-ASCII: café, naïve, “quotes”, — and ✓.",
];

/// A module whose doc and values' docs are [`DOCS`].
fn docs_module() -> Module {
    Module {
        header: None,
        name: ModuleName::new("Gen.Docs"),
        doc: Some(DOCS[0].to_owned()),
        exposing: Exposing::All,
        imports: vec![],
        decls: DOCS
            .iter()
            .enumerate()
            .map(|(index, doc)| Decl::Value {
                doc: Some((*doc).to_owned()),
                name: format!("doc{index}"),
                annotation: int_t(),
                params: Vec::new(),
                body: int(i64::try_from(index).expect("few")),
            })
            .collect(),
    }
}

fn corpus() -> Vec<(String, String)> {
    [
        types_module(),
        codecs_module(),
        exprs_module(),
        bare_module(),
        random_module(),
        docs_module(),
    ]
    .iter()
    .map(|m| (m.name.to_string(), print_module(m)))
    .collect()
}

#[test]
fn corpus_is_in_elm_format_layout() {
    assert_canonical(&corpus(), "elm-printer-format");
}

#[test]
fn corpus_compiles() {
    assert_compiles(&corpus(), "elm-printer-make");
}
