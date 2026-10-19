//! The typed Elm syntax tree the generator emits.
//!
//! The tree covers only what generated code needs: record aliases, custom
//! types, annotated top-level values, section comments, and the
//! expressions and patterns their bodies use. It is not a general Elm AST.
//!
//! Invariants:
//!
//! - There is no parentheses node. The printer inserts parentheses from
//!   precedence ([`BinOp::precedence`], [`BinOp::associativity`]) and from
//!   the position an expression sits in, so a tree cannot be built with
//!   redundant or missing parentheses.
//! - Layout is the printer's decision (see [`mod@super::print`]), but for
//!   three hints by which the emitter asks for a layout elm-format would
//!   keep: [`Expr::InlineRecord`], [`Expr::InlineList`] and
//!   [`Expr::StackedApply`]. Each means what its plain form means.
//! - Names are stored as written in Elm: the tree does not validate that a
//!   value name is lowercase or that a constructor is uppercase. The
//!   naming layer is responsible for producing legal identifiers.

use std::fmt;

/// A dotted Elm module name such as `Json.Decode`.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct ModuleName(String);

impl ModuleName {
    /// Wrap a dotted module name. The name is taken as written.
    pub fn new(name: impl Into<String>) -> Self {
        Self(name.into())
    }

    /// The dotted name.
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for ModuleName {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl From<&str> for ModuleName {
    fn from(name: &str) -> Self {
        Self::new(name)
    }
}

/// One Elm source file.
#[derive(Debug, Clone, PartialEq)]
pub struct Module {
    /// A line comment printed above the `module` line, such as a
    /// generated-file notice: the text after `-- `, on one line.
    pub header: Option<String>,
    /// The module's name, matching its path under a source directory.
    pub name: ModuleName,
    /// The module documentation, printed as `{-| ... -}` under the header,
    /// as described on [`Decl::Value`].
    pub doc: Option<String>,
    /// What the module exposes.
    pub exposing: Exposing,
    /// Imports, in any order; the printer sorts and merges them.
    pub imports: Vec<Import>,
    /// Top-level declarations, printed in order.
    pub decls: Vec<Decl>,
}

/// An exposing list, on a module header or an import.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Exposing {
    /// `exposing (..)`.
    All,
    /// `exposing (a, B, C(..))`. The printer sorts the items.
    Explicit(Vec<Exposed>),
}

/// One item of an explicit exposing list.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Exposed {
    /// A value or function: `decodeNote`.
    Value(String),
    /// A type without its constructors: `Note`.
    Type(String),
    /// A custom type with its constructors: `Status(..)`.
    TypeWithCtors(String),
}

impl Exposed {
    /// The bare name, without any `(..)`.
    pub fn name(&self) -> &str {
        match self {
            Self::Value(name) | Self::Type(name) | Self::TypeWithCtors(name) => name,
        }
    }
}

/// An `import` line.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Import {
    /// The imported module.
    pub module: ModuleName,
    /// `as Alias`.
    pub alias: Option<String>,
    /// `exposing (...)`.
    pub exposing: Option<Exposing>,
}

/// A top-level declaration.
#[derive(Debug, Clone, PartialEq)]
pub enum Decl {
    /// `type alias Name a = body`; generated code uses it for records.
    TypeAlias {
        /// Documentation printed above the declaration.
        doc: Option<String>,
        /// The alias name.
        name: String,
        /// Type variables, in order.
        type_params: Vec<String>,
        /// The aliased type. A non-empty record prints one field per line.
        body: Type,
    },
    /// `type Name a = A | B Int`.
    CustomType {
        /// Documentation printed above the declaration.
        doc: Option<String>,
        /// The type name.
        name: String,
        /// Type variables, in order.
        type_params: Vec<String>,
        /// The constructors, in order. Elm requires at least one.
        variants: Vec<Variant>,
    },
    /// An annotated top-level value or function.
    Value {
        /// Documentation printed above the annotation, as Markdown.
        ///
        /// elm-format re-renders doc comments as Markdown (lists become
        /// `  - item`, `*em*` becomes `_em_`, and code blocks are
        /// formatted as Elm), so the text must already be in that
        /// canonical form; the printer only trims trailing whitespace and
        /// places `-}`: on the next line for a single paragraph, after a
        /// blank line when the text has several blocks.
        doc: Option<String>,
        /// The value name.
        name: String,
        /// The type annotation; every generated top-level value has one.
        annotation: Type,
        /// Argument patterns, for a function.
        params: Vec<Pattern>,
        /// The body.
        body: Expr,
    },
    /// A section banner such as `-- TYPES`. The string is the text after
    /// `-- `.
    Comment(String),
}

/// A constructor of a custom type.
#[derive(Debug, Clone, PartialEq)]
pub struct Variant {
    /// The constructor name.
    pub name: String,
    /// The constructor's argument types.
    pub args: Vec<Type>,
}

/// A type expression.
#[derive(Debug, Clone, PartialEq)]
pub enum Type {
    /// A named type, optionally qualified, with arguments: `Dict String Int`.
    Named {
        /// The qualifying module or alias, as it is to be printed.
        module: Option<ModuleName>,
        /// The type name.
        name: String,
        /// Type arguments.
        args: Vec<Type>,
    },
    /// A record type: `{ a : Int, b : String }`.
    Record(Vec<(String, Type)>),
    /// `()`.
    Unit,
    /// A tuple of two or three types.
    Tuple(Vec<Type>),
    /// `a -> b`.
    Function(Box<Type>, Box<Type>),
    /// A type variable: `a`, `msg`.
    Var(String),
}

/// An expression.
#[derive(Debug, Clone, PartialEq)]
pub enum Expr {
    /// A value or constructor reference, optionally qualified:
    /// `x`, `Json.Decode.string`, `Just`.
    Var {
        /// The qualifying module or alias, as it is to be printed.
        module: Option<ModuleName>,
        /// The name.
        name: String,
    },
    /// Function application: `f a b`.
    Apply(Box<Expr>, Vec<Expr>),
    /// Function application printed with one argument per line, the
    /// first on the function's line and the rest indented under it, even
    /// when every argument fits on one line; elm-format keeps an
    /// application written that way. Like [`Expr::Apply`] otherwise.
    StackedApply(Box<Expr>, Vec<Expr>),
    /// `\a b -> body`.
    Lambda(Vec<Pattern>, Box<Expr>),
    /// `case subject of` with its branches, in order.
    Case(Box<Expr>, Vec<(Pattern, Expr)>),
    /// `let bindings in body`.
    Let(Vec<LetBinding>, Box<Expr>),
    /// `if cond then a else b`. An `If` in the else branch prints as
    /// `else if`.
    If {
        /// The condition.
        cond: Box<Expr>,
        /// The value when the condition holds.
        then_branch: Box<Expr>,
        /// The value otherwise.
        else_branch: Box<Expr>,
    },
    /// A record literal: `{ a = 1, b = 2 }`.
    Record(Vec<(String, Expr)>),
    /// A record literal printed on one line when every field value fits on
    /// one, as elm-format keeps a record written that way, and like
    /// [`Expr::Record`] otherwise.
    InlineRecord(Vec<(String, Expr)>),
    /// `{ record | a = 1 }`. Elm only allows a variable as the record.
    RecordUpdate {
        /// The variable being updated.
        record: String,
        /// The new field values.
        fields: Vec<(String, Expr)>,
    },
    /// Field access: `expr.field`.
    Access(Box<Expr>, String),
    /// A field accessor function: `.field`.
    Accessor(String),
    /// A list literal. Unless it is empty it prints one item per line,
    /// even when it has one.
    List(Vec<Expr>),
    /// A list literal printed on one line when every item fits on one, as
    /// elm-format keeps a list written that way: `[ "sub", "field" ]`.
    InlineList(Vec<Expr>),
    /// A tuple of two or three expressions.
    Tuple(Vec<Expr>),
    /// `()`.
    Unit,
    /// A string literal; the printer escapes it.
    Str(String),
    /// An integer literal.
    Int(i64),
    /// A float literal. It must be finite: Elm has no literal for NaN or
    /// infinity.
    Float(f64),
    /// A character literal; the printer escapes it.
    Char(char),
    /// A binary operator application.
    BinOp {
        /// The operator.
        op: BinOp,
        /// The left operand.
        left: Box<Expr>,
        /// The right operand.
        right: Box<Expr>,
    },
    /// Unary minus: `-x`.
    Negate(Box<Expr>),
}

/// A binding inside a `let`.
#[derive(Debug, Clone, PartialEq)]
pub struct LetBinding {
    /// The bound name.
    pub name: String,
    /// An optional type annotation.
    pub annotation: Option<Type>,
    /// Argument patterns, for a local function.
    pub params: Vec<Pattern>,
    /// The bound expression.
    pub body: Expr,
}

/// A pattern, in a function parameter, lambda, or `case` branch.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Pattern {
    /// `_`.
    Wildcard,
    /// A variable binding.
    Var(String),
    /// A constructor pattern, optionally qualified: `Just x`, `Status.Active`.
    Ctor {
        /// The qualifying module or alias, as it is to be printed.
        module: Option<ModuleName>,
        /// The constructor name.
        name: String,
        /// Argument patterns.
        args: Vec<Pattern>,
    },
    /// A tuple pattern of two or three patterns.
    Tuple(Vec<Pattern>),
    /// A record destructuring: `{ a, b }`.
    Record(Vec<String>),
    /// A string literal pattern; the printer escapes it.
    Str(String),
    /// An integer literal pattern. Elm has no negative literal patterns.
    Int(u64),
    /// `()`.
    Unit,
}

/// The core binary operators generated code may use.
///
/// Precedence and associativity follow the `infix` declarations in elm/core
/// 1.0.5: `Basics.elm` for all but `::`, which `List.elm` declares.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum BinOp {
    /// `<|`: `infix right 0 (<|) = apL`.
    ApL,
    /// `|>`: `infix left 0 (|>) = apR`.
    ApR,
    /// `||`: `infix right 2 (||) = or`.
    Or,
    /// `&&`: `infix right 3 (&&) = and`.
    And,
    /// `==`: `infix non 4 (==) = eq`.
    Eq,
    /// `/=`: `infix non 4 (/=) = neq`.
    Neq,
    /// `<`: `infix non 4 (<) = lt`.
    Lt,
    /// `>`: `infix non 4 (>) = gt`.
    Gt,
    /// `<=`: `infix non 4 (<=) = le`.
    Le,
    /// `>=`: `infix non 4 (>=) = ge`.
    Ge,
    /// `++`: `infix right 5 (++) = append`.
    Append,
    /// `::`: `infix right 5 (::) = cons` (in `List.elm`).
    Cons,
    /// `+`: `infix left 6 (+) = add`.
    Add,
    /// `-`: `infix left 6 (-) = sub`.
    Sub,
    /// `*`: `infix left 7 (*) = mul`.
    Mul,
    /// `/`: `infix left 7 (/) = fdiv`.
    FDiv,
    /// `//`: `infix left 7 (//) = idiv`.
    IDiv,
    /// `^`: `infix right 8 (^) = pow`.
    Pow,
    /// `<<`: `infix left 9 (<<) = composeL`.
    ComposeL,
    /// `>>`: `infix right 9 (>>) = composeR`.
    ComposeR,
}

/// How a chain of operators of equal precedence groups.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Associativity {
    /// `a - b - c` is `(a - b) - c`.
    Left,
    /// `a ++ b ++ c` is `a ++ (b ++ c)`.
    Right,
    /// `a == b == c` is a syntax error.
    Non,
}

impl BinOp {
    /// Every operator, in declaration order.
    pub const ALL: [BinOp; 20] = [
        Self::ApL,
        Self::ApR,
        Self::Or,
        Self::And,
        Self::Eq,
        Self::Neq,
        Self::Lt,
        Self::Gt,
        Self::Le,
        Self::Ge,
        Self::Append,
        Self::Cons,
        Self::Add,
        Self::Sub,
        Self::Mul,
        Self::FDiv,
        Self::IDiv,
        Self::Pow,
        Self::ComposeL,
        Self::ComposeR,
    ];

    /// The operator as written in source.
    pub fn symbol(self) -> &'static str {
        match self {
            Self::ApL => "<|",
            Self::ApR => "|>",
            Self::Or => "||",
            Self::And => "&&",
            Self::Eq => "==",
            Self::Neq => "/=",
            Self::Lt => "<",
            Self::Gt => ">",
            Self::Le => "<=",
            Self::Ge => ">=",
            Self::Append => "++",
            Self::Cons => "::",
            Self::Add => "+",
            Self::Sub => "-",
            Self::Mul => "*",
            Self::FDiv => "/",
            Self::IDiv => "//",
            Self::Pow => "^",
            Self::ComposeL => "<<",
            Self::ComposeR => ">>",
        }
    }

    /// The precedence from the operator's `infix` declaration, 0 to 9;
    /// higher binds tighter.
    pub fn precedence(self) -> u8 {
        match self {
            Self::ApL | Self::ApR => 0,
            Self::Or => 2,
            Self::And => 3,
            Self::Eq | Self::Neq | Self::Lt | Self::Gt | Self::Le | Self::Ge => 4,
            Self::Append | Self::Cons => 5,
            Self::Add | Self::Sub => 6,
            Self::Mul | Self::FDiv | Self::IDiv => 7,
            Self::Pow => 8,
            Self::ComposeL | Self::ComposeR => 9,
        }
    }

    /// The associativity from the operator's `infix` declaration.
    pub fn associativity(self) -> Associativity {
        match self {
            Self::ApR | Self::Add | Self::Sub | Self::Mul | Self::FDiv | Self::IDiv => {
                Associativity::Left
            }
            Self::ComposeL => Associativity::Left,
            Self::ApL | Self::Or | Self::And | Self::Append | Self::Cons | Self::Pow => {
                Associativity::Right
            }
            Self::ComposeR => Associativity::Right,
            Self::Eq | Self::Neq | Self::Lt | Self::Gt | Self::Le | Self::Ge => Associativity::Non,
        }
    }
}
