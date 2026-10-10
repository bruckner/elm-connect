//! Small constructors so emitter code reads like the Elm it produces.
//!
//! ```
//! use elm_connect_gen::elm::build::*;
//!
//! // Json.Decode.field "name" Json.Decode.string
//! let field = apply(
//!     qualified("Json.Decode", "field"),
//!     [string("name"), qualified("Json.Decode", "string")],
//! );
//! // Json.Decode.succeed Note |> andMap field
//! let decoder = pipe(
//!     apply(qualified("Json.Decode", "succeed"), [var("Note")]),
//!     apply(var("andMap"), [field]),
//! );
//! # let _ = decoder;
//! ```

use super::ast::{BinOp, Expr, LetBinding, ModuleName, Pattern, Type};

// Expressions.

/// An unqualified value or constructor: `x`, `Just`.
pub fn var(name: impl Into<String>) -> Expr {
    Expr::Var {
        module: None,
        name: name.into(),
    }
}

/// A qualified value or constructor: `Json.Decode.string`.
pub fn qualified(module: impl Into<ModuleName>, name: impl Into<String>) -> Expr {
    Expr::Var {
        module: Some(module.into()),
        name: name.into(),
    }
}

/// `f a b`. With no arguments this is `f` itself.
pub fn apply(f: Expr, args: impl IntoIterator<Item = Expr>) -> Expr {
    let args: Vec<Expr> = args.into_iter().collect();
    if args.is_empty() {
        f
    } else {
        Expr::Apply(Box::new(f), args)
    }
}

/// `left op right`.
pub fn binop(op: BinOp, left: Expr, right: Expr) -> Expr {
    Expr::BinOp {
        op,
        left: Box::new(left),
        right: Box::new(right),
    }
}

/// `value |> f`.
pub fn pipe(value: Expr, f: Expr) -> Expr {
    binop(BinOp::ApR, value, f)
}

/// `start |> step1 |> step2 ...`.
pub fn pipeline(start: Expr, steps: impl IntoIterator<Item = Expr>) -> Expr {
    steps.into_iter().fold(start, pipe)
}

/// `\params -> body`.
pub fn lambda(params: impl IntoIterator<Item = Pattern>, body: Expr) -> Expr {
    Expr::Lambda(params.into_iter().collect(), Box::new(body))
}

/// `case subject of` with the given branches.
pub fn case(subject: Expr, branches: impl IntoIterator<Item = (Pattern, Expr)>) -> Expr {
    Expr::Case(Box::new(subject), branches.into_iter().collect())
}

/// `let bindings in body`.
pub fn let_in(bindings: impl IntoIterator<Item = LetBinding>, body: Expr) -> Expr {
    Expr::Let(bindings.into_iter().collect(), Box::new(body))
}

/// `if cond then a else b`.
pub fn if_then_else(cond: Expr, then_branch: Expr, else_branch: Expr) -> Expr {
    Expr::If {
        cond: Box::new(cond),
        then_branch: Box::new(then_branch),
        else_branch: Box::new(else_branch),
    }
}

/// A record literal.
pub fn record<N: Into<String>>(fields: impl IntoIterator<Item = (N, Expr)>) -> Expr {
    Expr::Record(fields.into_iter().map(|(n, e)| (n.into(), e)).collect())
}

/// `expr.field`.
pub fn access(expr: Expr, field: impl Into<String>) -> Expr {
    Expr::Access(Box::new(expr), field.into())
}

/// A list literal.
pub fn list(items: impl IntoIterator<Item = Expr>) -> Expr {
    Expr::List(items.into_iter().collect())
}

/// `( a, b )`.
pub fn tuple2(a: Expr, b: Expr) -> Expr {
    Expr::Tuple(vec![a, b])
}

/// A string literal.
pub fn string(s: impl Into<String>) -> Expr {
    Expr::Str(s.into())
}

/// An integer literal.
pub fn int(i: i64) -> Expr {
    Expr::Int(i)
}

// Types.

/// An unqualified named type: `ty("List", [ty("Int", [])])`.
pub fn ty(name: impl Into<String>, args: impl IntoIterator<Item = Type>) -> Type {
    Type::Named {
        module: None,
        name: name.into(),
        args: args.into_iter().collect(),
    }
}

/// A qualified named type: `Json.Decode.Decoder Note`.
pub fn ty_qualified(
    module: impl Into<ModuleName>,
    name: impl Into<String>,
    args: impl IntoIterator<Item = Type>,
) -> Type {
    Type::Named {
        module: Some(module.into()),
        name: name.into(),
        args: args.into_iter().collect(),
    }
}

/// `a -> b -> result`, curried from the argument types.
pub fn ty_fn(args: impl IntoIterator<Item = Type>, result: Type) -> Type {
    let args: Vec<Type> = args.into_iter().collect();
    args.into_iter().rev().fold(result, |acc, arg| {
        Type::Function(Box::new(arg), Box::new(acc))
    })
}

/// A type variable.
pub fn ty_var(name: impl Into<String>) -> Type {
    Type::Var(name.into())
}

// Patterns.

/// A variable pattern.
pub fn pvar(name: impl Into<String>) -> Pattern {
    Pattern::Var(name.into())
}

/// An unqualified constructor pattern.
pub fn pctor(name: impl Into<String>, args: impl IntoIterator<Item = Pattern>) -> Pattern {
    Pattern::Ctor {
        module: None,
        name: name.into(),
        args: args.into_iter().collect(),
    }
}
