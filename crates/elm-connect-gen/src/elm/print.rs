//! Print the Elm AST as source text.
//!
//! Invariant: the output of [`print_module`] is in the canonical layout of
//! elm-format 0.8.8, so `elm-format --validate` accepts it unchanged.
//!
//! elm-format keeps an author's choice between one line and several for
//! most constructs; here the printer is the author and decides by fixed
//! rules rather than by line width:
//!
//! - `case`, `let` and `if` always span lines.
//! - Non-empty records and record updates put one field per line.
//! - Lists of more than one element put one element per line.
//! - A chain containing `|>` puts each operator at the start of its own
//!   line, indented one step.
//! - Anything else stays on one line unless a part of it spans lines; then
//!   it breaks the way elm-format would (an application puts each
//!   argument on its own line, a lambda puts its body under it, and so on).
//!
//! Parentheses come from precedence and position, never from the tree:
//! application binds tightest, operators follow their `infix` declarations
//! ([`BinOp::precedence`]), and `\`, `case`, `let` and `if` reach as far
//! right as they can, so they are wrapped wherever something could follow.
//!
//! Layout uses the block model in the private `layout` module, a port of the one inside
//! elm-format.
//!
//! # Panics
//!
//! Printing panics on an [`Expr::Float`] that is NaN or infinite; Elm has
//! no literal for either.

mod layout;
#[cfg(test)]
mod tests;

use std::collections::BTreeMap;
use std::fmt::Write as _;

use self::layout::Block;
use super::ast::{
    Associativity, BinOp, Decl, Exposed, Exposing, Expr, Import, LetBinding, Module, ModuleName,
    Pattern, Type,
};

/// Print a whole module, ending in a single newline.
pub fn print_module(module: &Module) -> String {
    // elm-format puts two blank lines between a comment above the header
    // and the header.
    let mut out = match &module.header {
        Some(comment) => format!("-- {comment}\n\n\n"),
        None => String::new(),
    };
    let _ = writeln!(
        out,
        "module {} exposing {}",
        module.name,
        exposing(&module.exposing)
    );
    if let Some(doc) = &module.doc {
        out.push('\n');
        out.push_str(&doc_comment(doc));
        out.push('\n');
    }
    let imports = merge_imports(&module.imports);
    if !imports.is_empty() {
        out.push('\n');
        for line in &imports {
            out.push_str(line);
            out.push('\n');
        }
    }
    let mut previous: Option<&Decl> = None;
    for decl in &module.decls {
        let is_comment = matches!(decl, Decl::Comment(_));
        // elm-format's spacing: a section comment gets three blank lines
        // above it (one if it directly follows a header without imports)
        // and two below; consecutive comments touch; declarations are two
        // blank lines apart.
        let blank_lines = match previous {
            None if is_comment && imports.is_empty() => 1,
            None if is_comment => 3,
            None => 2,
            Some(Decl::Comment(_)) if is_comment => 0,
            Some(_) if is_comment => 3,
            Some(_) => 2,
        };
        out.extend(std::iter::repeat_n('\n', blank_lines));
        out.push_str(&print_decl(decl));
        out.push('\n');
        previous = Some(decl);
    }
    out
}

/// Print one declaration, with its doc comment, without a trailing newline.
pub fn print_decl(decl: &Decl) -> String {
    match decl {
        Decl::Comment(text) => format!("-- {text}"),
        Decl::TypeAlias {
            doc,
            name,
            type_params,
            body,
        } => {
            let body = match body {
                Type::Record(fields) if !fields.is_empty() => record_type_block(fields),
                other => Block::text(&ty(other, TypeCtx::Top)),
            };
            let decl = Block::stack([
                Block::text(&format!("type alias {} =", head(name, type_params))),
                body.indent(),
            ]);
            with_doc(doc.as_deref(), decl.render())
        }
        Decl::CustomType {
            doc,
            name,
            type_params,
            variants,
        } => {
            let variants = variants.iter().enumerate().map(|(i, variant)| {
                let lead = if i == 0 { "= " } else { "| " };
                let parts = std::iter::once(variant.name.clone())
                    .chain(variant.args.iter().map(|t| ty(t, TypeCtx::Arg)));
                Block::text(&format!("{lead}{}", parts.collect::<Vec<_>>().join(" "))).indent()
            });
            let decl = Block::stack(
                std::iter::once(Block::text(&format!("type {}", head(name, type_params))))
                    .chain(variants),
            );
            with_doc(doc.as_deref(), decl.render())
        }
        Decl::Value {
            doc,
            name,
            annotation,
            params,
            body,
        } => with_doc(
            doc.as_deref(),
            definition(name, Some(annotation), params, body).render(),
        ),
    }
}

/// Print an expression as it would appear as a definition body at
/// column zero.
pub fn print_expr(expr: &Expr) -> String {
    expression(expr).render()
}

/// Print a type on one line.
pub fn print_type(t: &Type) -> String {
    ty(t, TypeCtx::Top)
}

/// Print a pattern as it would appear in a `case` branch.
pub fn print_pattern(p: &Pattern) -> String {
    pattern(p, false)
}

// Module header.

fn exposing(exposing: &Exposing) -> String {
    match exposing {
        Exposing::All => "(..)".to_owned(),
        Exposing::Explicit(items) => {
            // elm-format sorts an exposing list (by code point, so types
            // come before values) unless `@docs` lines order it.
            let mut items: Vec<&Exposed> = items.iter().collect();
            items.sort_by(|a, b| a.name().cmp(b.name()).then(a.cmp(b)));
            items.dedup();
            let items: Vec<String> = items
                .into_iter()
                .map(|item| match item {
                    Exposed::Value(name) | Exposed::Type(name) => name.clone(),
                    Exposed::TypeWithCtors(name) => format!("{name}(..)"),
                })
                .collect();
            format!("({})", items.join(", "))
        }
    }
}

/// Imports as elm-format leaves them: sorted by module name, with every
/// import of one module merged into one line (the last alias wins, the
/// exposing lists are unioned).
fn merge_imports(imports: &[Import]) -> Vec<String> {
    let mut merged: BTreeMap<&str, (Option<&str>, Option<Exposing>)> = BTreeMap::new();
    for import in imports {
        let entry = merged.entry(import.module.as_str()).or_default();
        if let Some(alias) = &import.alias {
            entry.0 = Some(alias);
        }
        entry.1 = match (entry.1.take(), &import.exposing) {
            (None, new) => new.clone(),
            (old, None) => old,
            (Some(Exposing::All), _) | (_, Some(Exposing::All)) => Some(Exposing::All),
            (Some(Exposing::Explicit(mut old)), Some(Exposing::Explicit(new))) => {
                old.extend(new.iter().cloned());
                Some(Exposing::Explicit(old))
            }
        };
    }
    merged
        .into_iter()
        .map(|(module, (alias, exposed))| {
            let mut line = format!("import {module}");
            if let Some(alias) = alias {
                let _ = write!(line, " as {alias}");
            }
            if let Some(exposed) = exposed {
                let _ = write!(line, " exposing {}", exposing(&exposed));
            }
            line
        })
        .collect()
}

/// `{-| doc -}` as elm-format closes it: `-}` on the line after a single
/// paragraph, and after a blank line when there are several blocks.
fn doc_comment(doc: &str) -> String {
    let doc: Vec<&str> = doc.trim_end().lines().map(str::trim_end).collect();
    let doc = doc.join("\n");
    let close = if doc.contains("\n\n") {
        "\n\n-}"
    } else {
        "\n-}"
    };
    format!("{{-| {doc}{close}")
}

fn with_doc(doc: Option<&str>, decl: String) -> String {
    match doc {
        Some(doc) => format!("{}\n{decl}", doc_comment(doc)),
        None => decl,
    }
}

fn head(name: &str, params: &[String]) -> String {
    std::iter::once(name)
        .chain(params.iter().map(String::as_str))
        .collect::<Vec<_>>()
        .join(" ")
}

/// `name : annotation` (if any), `name params =`, and the body indented.
fn definition(name: &str, annotation: Option<&Type>, params: &[Pattern], body: &Expr) -> Block {
    let mut lines = Vec::new();
    if let Some(annotation) = annotation {
        lines.push(Block::text(&format!(
            "{name} : {}",
            ty(annotation, TypeCtx::Top)
        )));
    }
    let params: String = params
        .iter()
        .map(|p| format!(" {}", pattern(p, true)))
        .collect();
    lines.push(Block::text(&format!("{name}{params} =")));
    lines.push(expression(body).indent());
    Block::stack(lines)
}

// Types. Types print on one line, except a record that is the body of a
// type alias.

#[derive(Clone, Copy, PartialEq)]
enum TypeCtx {
    /// Nothing around it needs parentheses.
    Top,
    /// The left of `->`: a function needs parentheses.
    FnArg,
    /// An argument of a type constructor: functions and applied types need
    /// parentheses.
    Arg,
}

fn ty(t: &Type, ctx: TypeCtx) -> String {
    match t {
        Type::Var(name) => name.clone(),
        Type::Unit => "()".to_owned(),
        Type::Named { module, name, args } => {
            let mut s = qualify(module.as_ref(), name);
            for arg in args {
                s.push(' ');
                s.push_str(&ty(arg, TypeCtx::Arg));
            }
            if !args.is_empty() && ctx == TypeCtx::Arg {
                format!("({s})")
            } else {
                s
            }
        }
        Type::Record(fields) if fields.is_empty() => "{}".to_owned(),
        Type::Record(fields) => {
            let fields: Vec<String> = fields
                .iter()
                .map(|(name, t)| format!("{name} : {}", ty(t, TypeCtx::Top)))
                .collect();
            format!("{{ {} }}", fields.join(", "))
        }
        Type::Tuple(items) => {
            let items: Vec<String> = items.iter().map(|t| ty(t, TypeCtx::Top)).collect();
            format!("( {} )", items.join(", "))
        }
        Type::Function(arg, result) => {
            let s = format!(
                "{} -> {}",
                ty(arg, TypeCtx::FnArg),
                ty(result, TypeCtx::Top)
            );
            if ctx == TypeCtx::Top {
                s
            } else {
                format!("({s})")
            }
        }
    }
}

fn record_type_block(fields: &[(String, Type)]) -> Block {
    let fields = fields.iter().enumerate().map(|(i, (name, t))| {
        let lead = if i == 0 { "{ " } else { ", " };
        Block::text(&format!("{lead}{name} : {}", ty(t, TypeCtx::Top)))
    });
    Block::stack(fields.chain([Block::text("}")]))
}

fn qualify(module: Option<&ModuleName>, name: &str) -> String {
    match module {
        Some(module) => format!("{module}.{name}"),
        None => name.to_owned(),
    }
}

// Patterns. Patterns always fit on one line.

/// `arg` is true where a constructor with arguments needs parentheses:
/// function and lambda parameters, and constructor arguments.
fn pattern(p: &Pattern, arg: bool) -> String {
    match p {
        Pattern::Wildcard => "_".to_owned(),
        Pattern::Var(name) => name.clone(),
        Pattern::Unit => "()".to_owned(),
        Pattern::Int(i) => i.to_string(),
        Pattern::Str(s) => string_literal(s),
        Pattern::Record(fields) if fields.is_empty() => "{}".to_owned(),
        Pattern::Record(fields) => format!("{{ {} }}", fields.join(", ")),
        Pattern::Tuple(items) => {
            let items: Vec<String> = items.iter().map(|p| pattern(p, false)).collect();
            format!("( {} )", items.join(", "))
        }
        Pattern::Ctor { module, name, args } => {
            let mut s = qualify(module.as_ref(), name);
            for a in args {
                s.push(' ');
                s.push_str(&pattern(a, true));
            }
            if arg && !args.is_empty() {
                format!("({s})")
            } else {
                s
            }
        }
    }
}

// Expressions.

/// Where an expression sits, for deciding on parentheses.
#[derive(Clone, Copy)]
enum Position {
    /// The function being applied.
    Func,
    /// An argument of an application.
    Arg,
    /// The record in `record.field`.
    AccessTarget,
    /// The operand of unary minus.
    Negated,
    /// An operand in an operator chain. `open_end` is true for the last
    /// operand after `<|`, where elm-format leaves a lambda, `case`, `let`
    /// or `if` bare.
    Operand { open_end: bool },
}

fn needs_parens(expr: &Expr, position: Position) -> bool {
    // `\`, `case`, `let` and `if` swallow everything to their right.
    let open = matches!(
        expr,
        Expr::Lambda(..) | Expr::Case(..) | Expr::Let(..) | Expr::If { .. }
    );
    // An application, including a negation that prints as `negate e`.
    let applied = match expr {
        Expr::Apply(..) => true,
        Expr::Negate(inner) => starts_negative(inner),
        _ => false,
    };
    let compound = open || applied || matches!(expr, Expr::BinOp { .. });
    match position {
        // elm-format writes a negation as an argument without parentheses
        // (`f -x`), and strips them if given.
        Position::Arg => compound,
        Position::Func | Position::Negated => compound || matches!(expr, Expr::Negate(_)),
        // A record literal or update is a closed term; elm-format strips
        // parentheses from `({ a = 1 }).a`.
        Position::AccessTarget => !matches!(
            expr,
            Expr::Var { .. } | Expr::Access(..) | Expr::Record(_) | Expr::RecordUpdate { .. }
        ),
        // Operator children are parenthesized by `flatten`, not here.
        Position::Operand { open_end } => open && !open_end,
    }
}

fn expression_at(expr: &Expr, position: Position) -> Block {
    let block = expression(expr);
    if needs_parens(expr, position) {
        parenthesize(block)
    } else {
        block
    }
}

/// Whether `expr` prints with a leading `-`.
fn starts_negative(expr: &Expr) -> bool {
    match expr {
        Expr::Negate(_) => true,
        Expr::Int(i) => *i < 0,
        Expr::Float(f) => f.is_sign_negative(),
        _ => false,
    }
}

/// `(` before; `)` after on the same line, or under the `(` if the block
/// spans lines.
fn parenthesize(block: Block) -> Block {
    if block.is_single() {
        block.prefix("(").suffix(")")
    } else {
        Block::stack([block.prefix("("), Block::text(")")])
    }
}

fn expression(expr: &Expr) -> Block {
    match expr {
        Expr::Var { module, name } => Block::text(&qualify(module.as_ref(), name)),
        Expr::Unit => Block::text("()"),
        Expr::Str(s) => Block::text(&string_literal(s)),
        Expr::Char(c) => Block::text(&char_literal(*c)),
        Expr::Int(i) => Block::text(&i.to_string()),
        Expr::Float(f) => Block::text(&float_literal(*f)),
        Expr::Accessor(field) => Block::text(&format!(".{field}")),
        Expr::Access(target, field) => {
            expression_at(target, Position::AccessTarget).suffix(&format!(".{field}"))
        }
        // `-(-x)` is what the tree says, but elm-format 0.8.8 rewrites it
        // to `--x`, a line comment. `negate` is what unary minus means, so
        // a negation of something negative is spelled with it.
        Expr::Negate(inner) if starts_negative(inner) => expression(&Expr::Apply(
            Box::new(Expr::Var {
                module: None,
                name: "negate".to_owned(),
            }),
            vec![inner.as_ref().clone()],
        )),
        Expr::Negate(inner) => expression_at(inner, Position::Negated).prefix("-"),
        Expr::Apply(f, args) => {
            let f = expression_at(f, Position::Func);
            let args: Vec<Block> = args
                .iter()
                .map(|a| expression_at(a, Position::Arg))
                .collect();
            if f.is_single() && args.iter().all(Block::is_single) {
                Block::row(std::iter::once(f).chain(args), " ")
            } else {
                Block::stack(std::iter::once(f).chain(args.into_iter().map(Block::indent)))
            }
        }
        Expr::Lambda(params, body) => {
            let params: Vec<String> = params.iter().map(|p| pattern(p, true)).collect();
            let head = format!("\\{} ->", params.join(" "));
            let body = expression(body);
            if body.is_single() {
                Block::row([Block::text(&head), body], " ")
            } else {
                Block::stack([Block::text(&head), body.indent()])
            }
        }
        Expr::Case(subject, branches) => {
            let subject = expression(subject);
            let head = if subject.is_single() {
                Block::row([Block::text("case"), subject, Block::text("of")], " ")
            } else {
                Block::stack([Block::text("case"), subject.indent(), Block::text("of")])
            };
            let branches = branches.iter().map(|(p, body)| {
                Block::stack([
                    Block::text(&format!("{} ->", pattern(p, false))),
                    expression(body).indent(),
                ])
            });
            Block::stack([head, Block::stack_spaced(branches).indent()])
        }
        Expr::Let(bindings, body) => {
            let bindings = bindings.iter().map(
                |LetBinding {
                     name,
                     annotation,
                     params,
                     body,
                 }| definition(name, annotation.as_ref(), params, body),
            );
            Block::stack([
                Block::text("let"),
                Block::stack_spaced(bindings).indent(),
                Block::text("in"),
                expression(body),
            ])
        }
        Expr::If { .. } => if_chain(expr),
        Expr::Record(fields) if fields.is_empty() => Block::text("{}"),
        Expr::Record(fields) => {
            let fields = fields.iter().enumerate().map(|(i, (name, value))| {
                field(name, value).prefix(if i == 0 { "{ " } else { ", " })
            });
            Block::stack(fields.chain([Block::text("}")]))
        }
        Expr::RecordUpdate { record, fields } => {
            let fields = fields.iter().enumerate().map(|(i, (name, value))| {
                field(name, value)
                    .prefix(if i == 0 { "| " } else { ", " })
                    .indent()
            });
            Block::stack(
                std::iter::once(Block::text(&format!("{{ {record}")))
                    .chain(fields)
                    .chain([Block::text("}")]),
            )
        }
        Expr::List(items) => sequence(items, "[", "]", items.len() > 1),
        Expr::Tuple(items) => sequence(items, "(", ")", false),
        Expr::BinOp { .. } => operator_chain(expr),
    }
}

/// `name = value`, or the value under `name =` if it spans lines.
fn field(name: &str, value: &Expr) -> Block {
    let value = expression(value);
    if value.is_single() {
        value.prefix(&format!("{name} = "))
    } else {
        Block::stack([Block::text(&format!("{name} =")), value.indent()])
    }
}

/// A list or tuple: `[ a, b ]` on one line, or one item per line with
/// leading commas.
fn sequence(items: &[Expr], open: &str, close: &str, force_multiline: bool) -> Block {
    if items.is_empty() {
        return Block::text(&format!("{open}{close}"));
    }
    let items: Vec<Block> = items.iter().map(expression).collect();
    if !force_multiline && items.iter().all(Block::is_single) {
        return Block::row(items, ", ")
            .prefix(&format!("{open} "))
            .suffix(&format!(" {close}"));
    }
    let lines = items.into_iter().enumerate().map(|(i, item)| {
        if i == 0 {
            item.prefix(&format!("{open} "))
        } else {
            item.prefix(", ")
        }
    });
    Block::stack(lines.chain([Block::text(close)]))
}

/// `if`, with an `if` in the else branch printed as `else if`.
fn if_chain(expr: &Expr) -> Block {
    let mut parts = Vec::new();
    let mut keyword = "if";
    let mut rest = expr;
    while let Expr::If {
        cond,
        then_branch,
        else_branch,
    } = rest
    {
        let cond = expression(cond);
        let head = if cond.is_single() {
            Block::row([Block::text(keyword), cond, Block::text("then")], " ")
        } else {
            Block::stack([Block::text(keyword), cond.indent(), Block::text("then")])
        };
        parts.push(head);
        parts.push(expression(then_branch).indent());
        parts.push(Block::blank());
        keyword = "else if";
        rest = else_branch;
    }
    parts.push(Block::text("else"));
    parts.push(expression(rest).indent());
    Block::stack(parts)
}

/// Whether `child`, as the `left` or right operand of `parent`, must be
/// parenthesized to parse back as the same tree.
fn operand_needs_parens(parent: BinOp, child: BinOp, left: bool) -> bool {
    let (p, c) = (parent.precedence(), child.precedence());
    if p != c {
        return c < p;
    }
    let side = if left {
        Associativity::Left
    } else {
        Associativity::Right
    };
    // Equal precedence groups only toward the operators' shared
    // associativity; Elm rejects every other mix.
    !(parent.associativity() == side && child.associativity() == side)
}

/// The operator tree as elm-format sees it: a flat chain of operands
/// separated by operators, where any operand that is itself an operator
/// application is one that needs parentheses.
fn flatten<'a>(
    expr: &'a Expr,
    chain: &mut Vec<(Option<BinOp>, &'a Expr)>,
    op_before: Option<BinOp>,
) {
    let Expr::BinOp { op, left, right } = expr else {
        chain.push((op_before, expr));
        return;
    };
    match left.as_ref() {
        Expr::BinOp { op: child, .. } if !operand_needs_parens(*op, *child, true) => {
            flatten(left, chain, op_before);
        }
        _ => chain.push((op_before, left)),
    }
    match right.as_ref() {
        Expr::BinOp { op: child, .. } if !operand_needs_parens(*op, *child, false) => {
            flatten(right, chain, Some(*op));
        }
        _ => chain.push((Some(*op), right)),
    }
}

fn operator_chain(expr: &Expr) -> Block {
    let mut chain = Vec::new();
    flatten(expr, &mut chain, None);
    let last = chain.len() - 1;
    let operands: Vec<(Option<BinOp>, Block)> = chain
        .iter()
        .enumerate()
        .map(|(i, (op, operand))| {
            let block = if matches!(operand, Expr::BinOp { .. }) {
                parenthesize(expression(operand))
            } else {
                let open_end = i == last && *op == Some(BinOp::ApL);
                expression_at(operand, Position::Operand { open_end })
            };
            (*op, block)
        })
        .collect();
    let multiline = operands
        .iter()
        .any(|(op, block)| *op == Some(BinOp::ApR) || !block.is_single());
    if !multiline {
        let parts = operands.into_iter().flat_map(|(op, block)| {
            op.map(|op| Block::text(op.symbol()))
                .into_iter()
                .chain([block])
        });
        return Block::row(parts, " ");
    }
    stack_chain(operands)
}

/// elm-format's multi-line operator layout: each operator starts a line
/// one step in, except `<|`, which ends its line and indents everything
/// after it.
fn stack_chain(operands: Vec<(Option<BinOp>, Block)>) -> Block {
    let mut operands = operands.into_iter();
    let (_, mut acc) = operands.next().expect("an operator chain has operands");
    while let Some((op, block)) = operands.next() {
        let op = op.expect("every operand after the first follows an operator");
        if op == BinOp::ApL {
            let head = if acc.is_single() {
                acc.suffix(" <|")
            } else {
                Block::stack([acc, Block::text("<|")])
            };
            let tail = stack_chain(std::iter::once((None, block)).chain(operands).collect());
            return Block::stack([head, tail.indent()]);
        }
        acc = Block::stack([acc, block.prefix(&format!("{} ", op.symbol())).indent()]);
    }
    acc
}

// Literals.

/// A string literal with Elm's escapes, as elm-format writes them: `\"`,
/// `\\`, `\n` and `\t` by name, every other character that is not
/// printable or is whitespace other than a space as `\u{XXXX}`, and
/// everything else literally.
fn string_literal(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('"');
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            other => escape_char(other, &mut out),
        }
    }
    out.push('"');
    out
}

/// A character literal, escaped as in strings except that `'` is escaped
/// and `"` is not.
fn char_literal(c: char) -> String {
    let mut out = String::from("'");
    match c {
        '\'' => out.push_str("\\'"),
        other => escape_char(other, &mut out),
    }
    out.push('\'');
    out
}

fn escape_char(c: char, out: &mut String) {
    match c {
        '\\' => out.push_str("\\\\"),
        '\n' => out.push_str("\\n"),
        '\t' => out.push_str("\\t"),
        c if needs_hex_escape(c) => {
            let _ = write!(out, "\\u{{{:04X}}}", u32::from(c));
        }
        c => out.push(c),
    }
}

/// elm-format hex-escapes characters Haskell's `isPrint` rejects and
/// whitespace other than a space. `isPrint` rejects the general categories
/// Cc, Cf, Zl, Zp, Co, Cs and Cn. Rust's standard library exposes Cc
/// (`is_control`) and, through `is_whitespace`, Zl and Zp; Cf, Co and the
/// noncharacters of Cn are listed here. Other unassigned code points (Cn)
/// are not detected and print literally.
fn needs_hex_escape(c: char) -> bool {
    c.is_control() || (c.is_whitespace() && c != ' ') || is_format(c) || is_private_or_nonchar(c)
}

/// General category Cf (format), Unicode 15.1.
fn is_format(c: char) -> bool {
    matches!(
        u32::from(c),
        0x00AD
            | 0x0600..=0x0605
            | 0x061C
            | 0x06DD
            | 0x070F
            | 0x0890..=0x0891
            | 0x08E2
            | 0x180E
            | 0x200B..=0x200F
            | 0x202A..=0x202E
            | 0x2060..=0x2064
            | 0x2066..=0x206F
            | 0xFEFF
            | 0xFFF9..=0xFFFB
            | 0x110BD
            | 0x110CD
            | 0x13430..=0x1343F
            | 0x1BCA0..=0x1BCA3
            | 0x1D173..=0x1D17A
            | 0xE0001
            | 0xE0020..=0xE007F
    )
}

/// General category Co (private use), and the noncharacters of Cn.
fn is_private_or_nonchar(c: char) -> bool {
    let n = u32::from(c);
    matches!(n, 0xE000..=0xF8FF | 0xF0000..=0xFFFFD | 0x100000..=0x10FFFD | 0xFDD0..=0xFDEF)
        || n & 0xFFFE == 0xFFFE
}

/// A float in decimal notation: the shortest digits that round-trip,
/// never an exponent, always with a fractional part (`1.0`, `0.001`,
/// `100000000000000000000.0`), which is what elm-format keeps for a
/// literal written without an exponent.
fn float_literal(f: f64) -> String {
    assert!(f.is_finite(), "Elm has no literal for {f}");
    let mut s = f.to_string();
    if !s.contains('.') {
        s.push_str(".0");
    }
    s
}
