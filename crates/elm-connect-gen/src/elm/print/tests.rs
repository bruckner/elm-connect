//! Exact output for each construct. The corpus in
//! `tests/elm_printer.rs` checks the same layouts against elm-format.

use super::{print_decl, print_expr, print_module, print_pattern, print_type};
use crate::elm::ast::{
    BinOp, Decl, Exposed, Exposing, Expr, Import, LetBinding, Module, ModuleName, Pattern, Type,
    Variant,
};
use crate::elm::build::*;

fn neg(e: Expr) -> Expr {
    Expr::Negate(Box::new(e))
}

#[test]
fn references() {
    assert_eq!(print_expr(&var("x")), "x");
    assert_eq!(
        print_expr(&qualified("Json.Decode", "string")),
        "Json.Decode.string"
    );
    assert_eq!(print_expr(&Expr::Accessor("name".into())), ".name");
    assert_eq!(print_expr(&access(access(var("a"), "b"), "c")), "a.b.c");
    assert_eq!(
        print_expr(&access(apply(var("f"), [var("x")]), "a")),
        "(f x).a"
    );
}

#[test]
fn literals() {
    assert_eq!(print_expr(&int(-3)), "-3");
    assert_eq!(print_expr(&Expr::Float(2.0)), "2.0");
    assert_eq!(print_expr(&Expr::Float(0.25)), "0.25");
    assert_eq!(print_expr(&Expr::Float(1e21)), "1000000000000000000000.0");
    assert_eq!(print_expr(&Expr::Unit), "()");
    assert_eq!(print_expr(&Expr::Char('\'')), r"'\''");
    assert_eq!(print_expr(&Expr::Char('"')), "'\"'");
}

#[test]
fn string_escapes() {
    assert_eq!(
        print_expr(&string("a\"b\\c\nd\te\rf")),
        r#""a\"b\\c\nd\te\u{000D}f""#
    );
    assert_eq!(
        print_expr(&string("\u{1}\u{7f}\u{a0}\u{ad}\u{feff}\u{e0001}")),
        r#""\u{0001}\u{007F}\u{00A0}\u{00AD}\u{FEFF}\u{E0001}""#
    );
    assert_eq!(print_expr(&string("é 😀 '")), "\"é 😀 '\"");
}

#[test]
#[should_panic(expected = "Elm has no literal")]
fn non_finite_float_panics() {
    print_expr(&Expr::Float(f64::NAN));
}

#[test]
fn application_parenthesizes_compound_arguments() {
    let e = apply(
        qualified("Json.Decode", "field"),
        [
            string("a"),
            apply(
                qualified("Json.Decode", "list"),
                [qualified("Json.Decode", "int")],
            ),
            neg(var("x")),
            lambda([pvar("y")], var("y")),
            binop(BinOp::Add, int(1), int(2)),
        ],
    );
    assert_eq!(
        print_expr(&e),
        r#"Json.Decode.field "a" (Json.Decode.list Json.Decode.int) -x (\y -> y) (1 + 2)"#
    );
}

#[test]
fn application_with_a_multiline_last_argument_keeps_the_others_on_the_first_line() {
    let e = apply(var("f"), [var("a"), list([int(1), int(2)])]);
    assert_eq!(print_expr(&e), "f a\n    [ 1\n    , 2\n    ]");
    let only = apply(var("f"), [list([int(1), int(2)])]);
    assert_eq!(print_expr(&only), "f\n    [ 1\n    , 2\n    ]");
}

#[test]
fn application_with_a_multiline_last_argument_keeps_only_the_first_on_the_first_line() {
    let e = apply(var("f"), [var("a"), var("b"), list([int(1), int(2)])]);
    assert_eq!(print_expr(&e), "f a\n    b\n    [ 1\n    , 2\n    ]");
}

#[test]
fn application_with_a_multiline_argument_before_the_last_puts_each_argument_on_a_line() {
    let e = apply(var("f"), [list([int(1), int(2)]), var("a")]);
    assert_eq!(print_expr(&e), "f\n    [ 1\n    , 2\n    ]\n    a");
}

#[test]
fn negation() {
    assert_eq!(print_expr(&neg(var("x"))), "-x");
    assert_eq!(print_expr(&neg(apply(var("f"), [var("x")]))), "-(f x)");
    assert_eq!(print_expr(&neg(neg(var("x")))), "negate -x");
    assert_eq!(print_expr(&neg(int(-1))), "negate -1");
}

#[test]
fn operators_parenthesize_by_precedence_and_associativity() {
    let (a, b, c) = (var("a"), var("b"), var("c"));
    let cases = [
        (
            binop(
                BinOp::Add,
                binop(BinOp::Mul, a.clone(), b.clone()),
                c.clone(),
            ),
            "a * b + c",
        ),
        (
            binop(
                BinOp::Mul,
                binop(BinOp::Add, a.clone(), b.clone()),
                c.clone(),
            ),
            "(a + b) * c",
        ),
        (
            binop(
                BinOp::Sub,
                binop(BinOp::Sub, a.clone(), b.clone()),
                c.clone(),
            ),
            "a - b - c",
        ),
        (
            binop(
                BinOp::Sub,
                a.clone(),
                binop(BinOp::Sub, b.clone(), c.clone()),
            ),
            "a - (b - c)",
        ),
        (
            binop(
                BinOp::Append,
                a.clone(),
                binop(BinOp::Append, b.clone(), c.clone()),
            ),
            "a ++ b ++ c",
        ),
        (
            binop(
                BinOp::Append,
                binop(BinOp::Append, a.clone(), b.clone()),
                c.clone(),
            ),
            "(a ++ b) ++ c",
        ),
        (
            binop(
                BinOp::Pow,
                a.clone(),
                binop(BinOp::Pow, b.clone(), c.clone()),
            ),
            "a ^ b ^ c",
        ),
        (
            binop(BinOp::Eq, binop(BinOp::Eq, a.clone(), b.clone()), c.clone()),
            "(a == b) == c",
        ),
        (
            binop(
                BinOp::Cons,
                a.clone(),
                binop(BinOp::Append, b.clone(), c.clone()),
            ),
            "a :: b ++ c",
        ),
        (
            binop(
                BinOp::ComposeR,
                binop(BinOp::ComposeL, a.clone(), b.clone()),
                c.clone(),
            ),
            "(a << b) >> c",
        ),
        (
            binop(
                BinOp::ApL,
                a.clone(),
                binop(BinOp::ApL, b.clone(), c.clone()),
            ),
            "a <| b <| c",
        ),
        (
            binop(
                BinOp::And,
                a.clone(),
                binop(BinOp::Or, b.clone(), c.clone()),
            ),
            "a && (b || c)",
        ),
        (
            binop(BinOp::Add, apply(var("f"), [a.clone()]), neg(b.clone())),
            "f a + -b",
        ),
    ];
    for (e, want) in cases {
        assert_eq!(print_expr(&e), want);
    }
}

#[test]
fn open_ended_operands_are_parenthesized_except_after_a_final_backward_pipe() {
    let l = || lambda([pvar("x")], var("x"));
    assert_eq!(
        print_expr(&binop(BinOp::ApL, var("f"), l())),
        r"f <| \x -> x"
    );
    assert_eq!(
        print_expr(&binop(BinOp::ApL, l(), var("y"))),
        r"(\x -> x) <| y"
    );
    assert_eq!(
        print_expr(&binop(BinOp::ComposeR, l(), l())),
        r"(\x -> x) >> (\x -> x)"
    );
}

#[test]
fn pipelines_put_each_step_on_a_line() {
    let e = pipeline(
        apply(qualified("D", "succeed"), [var("Note")]),
        [
            apply(var("andMap"), [var("a")]),
            apply(var("andMap"), [var("b")]),
        ],
    );
    assert_eq!(
        print_expr(&e),
        "D.succeed Note\n    |> andMap a\n    |> andMap b"
    );
}

#[test]
fn backward_pipe_with_a_multiline_right_side_ends_its_line() {
    let e = binop(BinOp::ApL, var("f"), list([int(1), int(2)]));
    assert_eq!(print_expr(&e), "f <|\n    [ 1\n    , 2\n    ]");
}

#[test]
fn multiline_operand_in_parentheses_snaps_to_the_tab_grid() {
    let e = pipe(
        var("x"),
        lambda([pvar("y")], case(var("y"), [(Pattern::Wildcard, int(1))])),
    );
    assert_eq!(
        print_expr(&e),
        "x\n    |> (\\y ->\n            case y of\n                _ ->\n                    1\n       )"
    );
}

#[test]
fn case_expression() {
    let e = case(
        var("s"),
        [
            (Pattern::Str("A".into()), int(1)),
            (Pattern::Wildcard, int(0)),
        ],
    );
    assert_eq!(
        print_expr(&e),
        "case s of\n    \"A\" ->\n        1\n\n    _ ->\n        0"
    );
}

#[test]
fn case_as_an_argument() {
    let e = apply(var("f"), [case(var("s"), [(Pattern::Wildcard, int(0))])]);
    assert_eq!(
        print_expr(&e),
        "f\n    (case s of\n        _ ->\n            0\n    )"
    );
}

#[test]
fn let_expression() {
    let e = let_in(
        [
            LetBinding {
                name: "f".into(),
                annotation: Some(ty_fn([ty("Int", [])], ty("Int", []))),
                params: vec![pvar("n")],
                body: var("n"),
            },
            LetBinding {
                name: "y".into(),
                annotation: None,
                params: vec![],
                body: int(1),
            },
        ],
        apply(var("f"), [var("y")]),
    );
    assert_eq!(
        print_expr(&e),
        "let\n    f : Int -> Int\n    f n =\n        n\n\n    y =\n        1\nin\nf y"
    );
}

#[test]
fn if_chain() {
    let e = if_then_else(var("a"), int(1), if_then_else(var("b"), int(2), int(3)));
    assert_eq!(
        print_expr(&e),
        "if a then\n    1\n\nelse if b then\n    2\n\nelse\n    3"
    );
}

#[test]
fn if_as_an_argument_aligns_else_with_if() {
    let e = apply(var("f"), [if_then_else(var("a"), int(1), int(2))]);
    assert_eq!(
        print_expr(&e),
        "f\n    (if a then\n        1\n\n     else\n        2\n    )"
    );
}

#[test]
fn lambda_parameters() {
    assert_eq!(
        print_expr(&lambda(
            [pvar("a"), pctor("Just", [pvar("b")]), Pattern::Wildcard],
            var("b")
        )),
        r"\a (Just b) _ -> b"
    );
}

#[test]
fn record_literals() {
    assert_eq!(print_expr(&record::<&str>([])), "{}");
    assert_eq!(
        print_expr(&record([("a", int(1)), ("b", string("x"))])),
        "{ a = 1\n, b = \"x\"\n}"
    );
    assert_eq!(
        print_expr(&Expr::RecordUpdate {
            record: "r".into(),
            fields: vec![("a".into(), int(1)), ("b".into(), int(2))],
        }),
        "{ r\n    | a = 1\n    , b = 2\n}"
    );
    assert_eq!(
        print_expr(&record([(
            "a",
            case(var("m"), [(Pattern::Wildcard, int(0))])
        )])),
        "{ a =\n    case m of\n        _ ->\n            0\n}"
    );
    assert_eq!(
        print_expr(&access(record([("a", int(1))]), "a")),
        "{ a = 1\n}.a"
    );
    assert_eq!(
        print_expr(&inline_record([("a", int(1)), ("b", string("x"))])),
        "{ a = 1, b = \"x\" }"
    );
    assert_eq!(
        print_expr(&inline_record([(
            "a",
            case(var("m"), [(Pattern::Wildcard, int(0))])
        )])),
        "{ a =\n    case m of\n        _ ->\n            0\n}"
    );
}

#[test]
fn lists_and_tuples() {
    assert_eq!(print_expr(&list([])), "[]");
    assert_eq!(print_expr(&list([int(1)])), "[ 1 ]");
    assert_eq!(print_expr(&list([int(1), int(2)])), "[ 1\n, 2\n]");
    assert_eq!(print_expr(&tuple2(string("a"), int(1))), "( \"a\", 1 )");
    assert_eq!(
        print_expr(&tuple2(var("a"), list([int(1), int(2)]))),
        "( a\n, [ 1\n  , 2\n  ]\n)"
    );
}

#[test]
fn type_expressions() {
    let int_t = || ty("Int", []);
    assert_eq!(
        print_type(&ty_qualified(
            "Dict",
            "Dict",
            [ty("String", []), ty("List", [int_t()])]
        )),
        "Dict.Dict String (List Int)"
    );
    assert_eq!(
        print_type(&ty_fn([ty_fn([int_t()], int_t()), ty_var("a")], Type::Unit)),
        "(Int -> Int) -> a -> ()"
    );
    assert_eq!(
        print_type(&ty("Maybe", [ty_fn([int_t()], int_t())])),
        "Maybe (Int -> Int)"
    );
    assert_eq!(
        print_type(&Type::Tuple(vec![int_t(), ty("Maybe", [int_t()])])),
        "( Int, Maybe Int )"
    );
    assert_eq!(
        print_type(&Type::Record(vec![("a".into(), int_t())])),
        "{ a : Int }"
    );
    assert_eq!(print_type(&Type::Record(vec![])), "{}");
}

#[test]
fn pattern_forms() {
    assert_eq!(
        print_pattern(&Pattern::Ctor {
            module: Some(ModuleName::new("Notes.V1")),
            name: "Active".into(),
            args: vec![pctor("Just", [pvar("x")]), Pattern::Int(3)],
        }),
        "Notes.V1.Active (Just x) 3"
    );
    assert_eq!(
        print_pattern(&Pattern::Tuple(vec![
            Pattern::Unit,
            Pattern::Str("s".into())
        ])),
        "( (), \"s\" )"
    );
    assert_eq!(
        print_pattern(&Pattern::Record(vec!["a".into(), "b".into()])),
        "{ a, b }"
    );
}

#[test]
fn type_alias_record() {
    let decl = Decl::TypeAlias {
        doc: Some("A note.".into()),
        name: "Note".into(),
        type_params: vec![],
        body: Type::Record(vec![
            ("name".into(), ty("String", [])),
            ("tags".into(), ty("List", [ty("String", [])])),
        ]),
    };
    assert_eq!(
        print_decl(&decl),
        "{-| A note.\n-}\ntype alias Note =\n    { name : String\n    , tags : List String\n    }"
    );
}

#[test]
fn custom_type() {
    let decl = Decl::CustomType {
        doc: None,
        name: "Tree".into(),
        type_params: vec!["a".into()],
        variants: vec![
            Variant {
                name: "Leaf".into(),
                args: vec![],
            },
            Variant {
                name: "Node".into(),
                args: vec![ty("Tree", [ty_var("a")]), ty_var("a")],
            },
        ],
    };
    assert_eq!(
        print_decl(&decl),
        "type Tree a\n    = Leaf\n    | Node (Tree a) a"
    );
}

#[test]
fn doc_comments_close_after_a_blank_line_when_there_are_several_blocks() {
    let value = |doc: &str| Decl::Value {
        doc: Some(doc.into()),
        name: "x".into(),
        annotation: ty("Int", []),
        params: vec![],
        body: int(1),
    };
    assert_eq!(
        print_decl(&value("One.\n")),
        "{-| One.\n-}\nx : Int\nx =\n    1"
    );
    assert_eq!(
        print_decl(&value("One.  \n\n    code\n")),
        "{-| One.\n\n    code\n\n-}\nx : Int\nx =\n    1"
    );
}

#[test]
fn module_layout() {
    let import = |module: &str, alias: Option<&str>, exposing: Option<Exposing>| Import {
        module: ModuleName::new(module),
        alias: alias.map(str::to_owned),
        exposing,
    };
    let value = |name: &str| Decl::Value {
        doc: None,
        name: name.into(),
        annotation: ty("Int", []),
        params: vec![],
        body: int(1),
    };
    let module = Module {
        header: None,
        name: ModuleName::new("Notes.V1"),
        doc: Some("Notes.".into()),
        exposing: Exposing::Explicit(vec![
            Exposed::Value("b".into()),
            Exposed::TypeWithCtors("Status".into()),
            Exposed::Value("a".into()),
        ]),
        imports: vec![
            import("Json.Encode", None, None),
            import(
                "Dict",
                None,
                Some(Exposing::Explicit(vec![Exposed::Type("Dict".into())])),
            ),
            import("Json.Decode", Some("D"), None),
            import("Dict", None, None),
        ],
        decls: vec![
            Decl::Comment("VALUES".into()),
            value("a"),
            value("b"),
            Decl::Comment("MORE".into()),
            Decl::Comment("STILL MORE".into()),
            value("c"),
        ],
    };
    let want = "\
module Notes.V1 exposing (Status(..), a, b)

{-| Notes.
-}

import Dict exposing (Dict)
import Json.Decode as D
import Json.Encode



-- VALUES


a : Int
a =
    1


b : Int
b =
    1



-- MORE
-- STILL MORE


c : Int
c =
    1
";
    assert_eq!(print_module(&module), want);
}

#[test]
fn module_without_imports_starting_with_a_comment() {
    let module = Module {
        header: None,
        name: ModuleName::new("A"),
        doc: None,
        exposing: Exposing::All,
        imports: vec![],
        decls: vec![Decl::Comment("X".into())],
    };
    assert_eq!(print_module(&module), "module A exposing (..)\n\n-- X\n");
}

#[test]
fn a_header_comment_sits_two_blank_lines_above_the_module_line() {
    let module = Module {
        header: Some("Generated. Do not edit.".into()),
        name: ModuleName::new("A"),
        doc: None,
        exposing: Exposing::All,
        imports: vec![],
        decls: vec![],
    };
    assert_eq!(
        print_module(&module),
        "-- Generated. Do not edit.\n\n\nmodule A exposing (..)\n"
    );
}

#[test]
fn negation_spelled_negate_is_parenthesized_as_an_argument() {
    assert_eq!(
        print_expr(&apply(var("f"), [neg(neg(var("x"))), neg(var("y"))])),
        "f (negate -x) -y"
    );
}
