// Portions of this file are a port of elm-format 0.8.8: its vendored
// Markdown parser (`elm-format-markdown`, a fork of Cheapskate, Copyright (c)
// 2013 John MacFarlane and Copyright (c) 2017 Aaron VonderHaar) and its
// Markdown printer (`ElmFormat.Render.Markdown`, Copyright (c) 2015-2023 Aaron
// VonderHaar and the elm-format contributors), both under the BSD 3-Clause
// License. The licenses are in `third_party/elm-format/` beside this crate's
// manifest, and the repository's THIRD_PARTY.md names the material.

//! Doc comments as elm-format leaves them.
//!
//! elm-format parses a doc comment as Markdown and prints it back in its
//! own spelling: `*` and `+` bullets become `  - `, ordered lists are
//! renumbered from `1.  `, `*em*` becomes `_em_`, `\`, `` ` ``, `_` and `*`
//! in text are backslash-escaped, setext headings become `#` headings with
//! blank lines around them, a bare URL becomes `<url>`, tabs become spaces
//! and trailing whitespace goes (design §3). Generated code must already
//! be in that form, or `elm-format --validate` rejects it, so
//! [`canonical`] does what elm-format does: it parses with a port of the
//! Markdown parser elm-format 0.8.8 vendors (Cheapskate, as modified for
//! elm-format) and prints as elm-format's `ElmFormat.Render.Markdown` does,
//! until the text no longer changes.
//!
//! Where elm-format would lose or rewrite text, the port departs from it
//! in favor of a form elm-format keeps as is:
//!
//! - A code block elm-format would format as Elm (indented, or fenced
//!   without a language or with `elm`) is fenced as `text`, which
//!   elm-format leaves alone: a proto comment's code is not Elm, and what
//!   reformatting would make of it cannot be known without elm-format.
//!   An empty code block is dropped (elm-format fails on one), so are a
//!   code block's trailing blank lines (elm-format drops one a run), and
//!   a code line that would close the fence gets a leading space.
//! - A line starting `@docs`, which elm-format would turn into a list of
//!   names, has `@docs` set as code: `` `@docs` ``.
//! - A heading inside a list item, after its first block, which
//!   elm-format would move out of the list on its next run, becomes a
//!   paragraph of strong text.
//! - A link reference definition elm-format cannot read back
//!   (`[label]: url` followed by anything but a title), which it would
//!   drop or print as `[??]: ??`, is kept as a `text` code block.
//!
//! Elm comments nest, so the text never holds `{-` or `-}`: [`canonical`]
//! writes them `{ -` and `- }`.

use std::fmt::Write as _;

/// The Markdown of a doc comment as elm-format would print it between
/// `{-|` and `-}`: blocks separated by blank lines, the blank lines
/// elm-format puts before a first block that is not a paragraph and after
/// several blocks included, each line without trailing whitespace, ending
/// in a newline. Empty for a text without blocks.
pub fn canonical(text: &str) -> String {
    settle(text, false)
}

/// The blocks of [`canonical`] without its leading and trailing blank
/// lines: the form of a comment to place among other blocks.
pub fn blocks(text: &str) -> String {
    settle(text, false).trim_matches('\n').to_owned()
}

/// [`blocks`] for a list item, which cannot hold a heading after its first
/// block ([`headings_in_items`]): every heading a paragraph of strong text.
pub fn item_blocks(text: &str) -> String {
    settle(text, true).trim_matches('\n').to_owned()
}

/// [`canonical`], with every heading a paragraph of strong text when
/// `no_headings`.
fn settle(text: &str, no_headings: bool) -> String {
    let mut current = escape_comment(text);
    for _ in 0..ROUNDS {
        let next = escape_comment(&round(&current, no_headings));
        if next == current {
            return current;
        }
        current = next;
    }
    // elm-format's form of the text moves on every round: keep the text,
    // as code, which settles in one.
    let mut current = code_block_text(&escape_comment(text));
    for _ in 0..ROUNDS {
        let next = escape_comment(&round(&current, false));
        if next == current {
            break;
        }
        current = next;
    }
    current
}

/// Whether the first block of `text`, in elm-format's form, is a
/// paragraph.
pub fn starts_with_paragraph(text: &str) -> bool {
    let canonical = canonical(text);
    !canonical.is_empty() && !canonical.starts_with('\n')
}

/// How many rounds of parsing and printing [`canonical`] tries before it
/// gives up on a fixed point. Every case found settles in three.
const ROUNDS: usize = 8;

/// `text` with every `{-` written `{ -` and every `-}` written `- }`, so it
/// neither opens nor closes an Elm comment.
fn escape_comment(text: &str) -> String {
    let mut text = text.to_owned();
    while text.contains("{-") || text.contains("-}") {
        text = text.replace("{-", "{ -").replace("-}", "- }");
    }
    text
}

/// One round of elm-format: parse, then print, without trailing
/// whitespace.
fn round(text: &str, no_headings: bool) -> String {
    let blocks = headings_in_items(parse(text), no_headings);
    let printed = format_markdown(&blocks);
    let mut out = String::with_capacity(printed.len());
    for line in printed.split_inclusive('\n') {
        let (body, newline) = match line.strip_suffix('\n') {
            Some(body) => (body, "\n"),
            None => (line, ""),
        };
        out.push_str(body.trim_end());
        out.push_str(newline);
    }
    out
}

/// `blocks` with every heading inside a list item that follows another
/// of the item's blocks made a paragraph of strong text, and every heading
/// of `blocks` itself when `strong`. elm-format prints such a heading
/// after two blank lines, which end the item, so the heading would move
/// out of the list on its next run.
fn headings_in_items(blocks: Vec<Block>, strong: bool) -> Vec<Block> {
    blocks
        .into_iter()
        .map(|block| heading_in_items(block, strong))
        .collect()
}

/// One block of [`headings_in_items`].
fn heading_in_items(block: Block, strong: bool) -> Block {
    match block {
        Block::Header(_, inlines) if strong => Block::Para(vec![Inline::Strong(inlines)]),
        Block::Blockquote(blocks) => Block::Blockquote(headings_in_items(blocks, false)),
        Block::List {
            tight,
            numbered,
            items,
        } => Block::List {
            tight,
            numbered,
            items: items
                .into_iter()
                .map(|item| {
                    item.into_iter()
                        .enumerate()
                        .map(|(index, block)| heading_in_items(block, index > 0))
                        .collect()
                })
                .collect(),
        },
        block => block,
    }
}

/// `text` as one `text` code block.
fn code_block_text(text: &str) -> String {
    let lines: Vec<String> = text.lines().map(str::to_owned).collect();
    let code = fence_safe(&lines.join("\n"));
    if code.trim().is_empty() {
        return String::new();
    }
    format!("```text\n{code}\n```\n")
}

// The syntax tree, as Cheapskate's.

#[derive(Clone, Debug, PartialEq)]
enum Block {
    Para(Vec<Inline>),
    Header(usize, Vec<Inline>),
    Blockquote(Vec<Block>),
    List {
        tight: bool,
        numbered: bool,
        items: Vec<Vec<Block>>,
    },
    Code {
        lang: String,
        code: String,
    },
    Html(String),
    HRule,
    References(Vec<(String, String, String)>),
}

#[derive(Clone, Debug, PartialEq)]
enum Inline {
    Str(String),
    Space,
    SoftBreak,
    LineBreak,
    Emph(Vec<Inline>),
    Strong(Vec<Inline>),
    Code(String),
    Link(Vec<Inline>, Target, String),
    Image(Vec<Inline>, String, String),
    Entity(String),
    RawHtml(String),
}

#[derive(Clone, Debug, PartialEq)]
enum Target {
    Url(String),
    Ref(String),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ListType {
    Bullet(char),
    Numbered(char, u64),
}

impl ListType {
    fn matches(self, other: ListType) -> bool {
        match (self, other) {
            (ListType::Bullet(a), ListType::Bullet(b)) => a == b,
            (ListType::Numbered(a, _), ListType::Numbered(b, _)) => a == b,
            _ => false,
        }
    }

    fn marker_width(self) -> usize {
        match self {
            ListType::Bullet(_) => 1,
            ListType::Numbered(_, n) if n < 10 => 2,
            ListType::Numbered(_, n) if n < 100 => 3,
            ListType::Numbered(_, n) if n < 1000 => 4,
            ListType::Numbered(..) => 5,
        }
    }
}

// The parser state: a backtracking cursor over characters that counts
// lines and columns from 1, as Cheapskate's does.

#[derive(Clone)]
struct Cursor<'a> {
    chars: &'a [char],
    pos: usize,
    column: usize,
    last: Option<char>,
}

impl<'a> Cursor<'a> {
    fn new(chars: &'a [char]) -> Self {
        Cursor {
            chars,
            pos: 0,
            column: 1,
            last: None,
        }
    }

    fn peek(&self) -> Option<char> {
        self.chars.get(self.pos).copied()
    }

    fn at_end(&self) -> bool {
        self.pos >= self.chars.len()
    }

    fn rest(&self) -> &'a [char] {
        &self.chars[self.pos.min(self.chars.len())..]
    }

    fn bump(&mut self) -> Option<char> {
        let c = self.peek()?;
        self.pos += 1;
        self.column = if c == '\n' { 1 } else { self.column + 1 };
        self.last = Some(c);
        Some(c)
    }

    fn satisfy(&mut self, f: impl Fn(char) -> bool) -> Option<char> {
        match self.peek() {
            Some(c) if f(c) => self.bump(),
            _ => None,
        }
    }

    fn char(&mut self, c: char) -> Option<char> {
        self.satisfy(|x| x == c)
    }

    fn take_while(&mut self, f: impl Fn(char) -> bool) -> String {
        let mut out = String::new();
        while let Some(c) = self.peek() {
            if !f(c) {
                break;
            }
            self.bump();
            out.push(c);
        }
        out
    }

    fn take_while1(&mut self, f: impl Fn(char) -> bool) -> Option<String> {
        let out = self.take_while(f);
        (!out.is_empty()).then_some(out)
    }

    fn take_rest(&mut self) -> String {
        self.take_while(|_| true)
    }

    fn string(&mut self, s: &str) -> Option<()> {
        let wanted: Vec<char> = s.chars().collect();
        if self.rest().starts_with(&wanted) {
            for _ in 0..wanted.len() {
                self.bump();
            }
            Some(())
        } else {
            None
        }
    }

    fn up_to(&mut self, n: usize, f: impl Fn(char) -> bool) -> String {
        let mut out = String::new();
        while out.chars().count() < n {
            match self.peek() {
                Some(c) if f(c) => {
                    self.bump();
                    out.push(c);
                }
                _ => break,
            }
        }
        out
    }

    fn end(&self) -> Option<()> {
        self.at_end().then_some(())
    }

    /// `f`, or nothing consumed when it fails.
    fn attempt<T>(&mut self, f: impl FnOnce(&mut Self) -> Option<T>) -> Option<T> {
        let saved = self.clone();
        let result = f(self);
        if result.is_none() {
            *self = saved;
        }
        result
    }

    /// Whether `f` would succeed here; consumes nothing.
    fn looking_at<T>(&self, f: impl FnOnce(&mut Self) -> Option<T>) -> bool {
        let mut probe = self.clone();
        f(&mut probe).is_some()
    }
}

fn is_whitespace(c: char) -> bool {
    matches!(c, ' ' | '\t' | '\n' | '\r')
}

/// Cheapskate's escapable characters: ASCII punctuation and symbols.
fn is_escapable(c: char) -> bool {
    c.is_ascii_punctuation()
}

fn is_ascii_alnum(c: char) -> bool {
    c.is_ascii_alphanumeric()
}

/// Haskell's `isAlphaNum`: a letter or a number of any script.
fn is_alnum(c: char) -> bool {
    c.is_alphanumeric()
}

// Scanners over one line.

fn scan_spaces(c: &mut Cursor) {
    c.take_while(|x| x == ' ');
}

fn scan_nonindent_space(c: &mut Cursor) {
    c.up_to(3, |x| x == ' ');
}

fn scan_blankline(c: &mut Cursor) -> Option<()> {
    c.attempt(|c| {
        scan_spaces(c);
        c.end()
    })
}

fn scan_spaces_to_column(c: &mut Cursor, column: usize) -> Option<()> {
    c.attempt(|c| {
        let n = column.saturating_sub(c.column);
        for _ in 0..n {
            c.char(' ')?;
        }
        Some(())
    })
}

fn scan_blockquote_start(c: &mut Cursor) -> Option<()> {
    c.attempt(|c| {
        c.char('>')?;
        c.char(' ');
        Some(())
    })
}

fn scan_reference(c: &Cursor) -> bool {
    c.looking_at(|c| {
        link_label(c)?;
        c.char(':')
    })
}

fn scan_hrule_line(c: &mut Cursor) -> Option<()> {
    c.attempt(|c| {
        let rule = c.satisfy(|x| matches!(x, '*' | '_' | '-'))?;
        for _ in 0..2 {
            scan_spaces(c);
            c.char(rule)?;
        }
        c.take_while(|x| x == ' ' || x == rule);
        c.end()
    })
}

fn parse_atx_header_start(c: &mut Cursor) -> Option<usize> {
    c.attempt(|c| {
        c.char('#')?;
        let hashes = c.up_to(5, |x| x == '#');
        if c.peek().is_some_and(|x| x != ' ') {
            return None;
        }
        Some(hashes.chars().count() + 1)
    })
}

fn parse_setext_header_line(c: &mut Cursor) -> Option<usize> {
    c.attempt(|c| {
        let d = c.satisfy(|x| x == '-' || x == '=')?;
        c.take_while(|x| x == d);
        scan_blankline(c)?;
        Some(if d == '=' { 1 } else { 2 })
    })
}

// Containers and leaves, as Cheapskate's first pass builds them.

#[derive(Clone, Debug, PartialEq)]
enum ContainerType {
    Document,
    BlockQuote,
    ListItem {
        marker_column: usize,
        padding: usize,
        list_type: ListType,
    },
    FencedCode {
        start_column: usize,
        fence: String,
        info: String,
    },
    IndentedCode,
    RawHtmlBlock,
    Reference,
}

#[derive(Clone, Debug)]
struct Container {
    kind: ContainerType,
    children: Vec<Elt>,
}

#[derive(Clone, Debug)]
enum Elt {
    C(Container),
    L(Leaf),
}

#[derive(Clone, Debug)]
enum Leaf {
    TextLine(String),
    BlankLine(String),
    AtxHeader(usize, String),
    SetextHeader(usize, String),
    Rule,
}

fn is_text_line(elt: Option<&Elt>) -> bool {
    matches!(elt, Some(Elt::L(Leaf::TextLine(_))))
}

fn is_blank_line(elt: &Elt) -> bool {
    matches!(elt, Elt::L(Leaf::BlankLine(_)))
}

/// Cheapskate's `tabFilter`: tabs to spaces, to a stop every four columns.
fn expand_tabs(line: &str) -> String {
    let mut out = String::with_capacity(line.len());
    let mut width = 0;
    for c in line.chars() {
        if c == '\t' {
            let n = 4 - width % 4;
            out.extend(std::iter::repeat_n(' ', n));
            width += n;
        } else {
            out.push(c);
            width += 1;
        }
    }
    out
}

/// The container stack of the first pass, the document at the bottom.
struct Stack {
    containers: Vec<Container>,
}

impl Stack {
    fn top(&mut self) -> &mut Container {
        self.containers.last_mut().expect("the document")
    }

    fn close_container(&mut self) {
        if self.containers.len() < 2 {
            return;
        }
        let top = self.containers.pop().expect("a container");
        let parent = self.top();
        match &top.kind {
            ContainerType::Reference => {
                let text: Vec<String> = top.children.iter().map(extract_text).collect();
                let joined = text.join("\n");
                if reference(joined.trim()).is_some() {
                    parent.children.push(Elt::C(top));
                } else {
                    // Cheapskate drops what it cannot read: keep it as code.
                    parent.children.push(Elt::C(Container {
                        kind: ContainerType::FencedCode {
                            start_column: 1,
                            fence: "```".into(),
                            info: "text".into(),
                        },
                        children: top.children,
                    }));
                }
            }
            ContainerType::ListItem { .. } => {
                let mut item = top;
                if item.children.last().is_some_and(is_blank_line) {
                    let blank = item.children.pop().expect("a blank line");
                    let empty = item.children.is_empty();
                    parent.children.push(Elt::C(item));
                    if !empty {
                        parent.children.push(blank);
                    }
                } else {
                    parent.children.push(Elt::C(item));
                }
            }
            _ => parent.children.push(Elt::C(top)),
        }
    }

    fn add_leaf(&mut self, leaf: Leaf) {
        let blank = matches!(leaf, Leaf::BlankLine(_));
        let top = self.top();
        if blank
            && matches!(top.kind, ContainerType::ListItem { .. })
            && top.children.last().is_some_and(is_blank_line)
        {
            // Two blank lines end a list item.
            self.close_container();
            self.add_leaf(leaf);
            return;
        }
        self.top().children.push(Elt::L(leaf));
    }

    fn add_container(&mut self, kind: ContainerType) {
        self.containers.push(Container {
            kind,
            children: Vec::new(),
        });
    }

    fn add_new(&mut self, new: Vec<ContainerType>, leaf: Leaf) {
        let fenced = matches!(new.last(), Some(ContainerType::FencedCode { .. }));
        for kind in new {
            self.add_container(kind);
        }
        if !(fenced && matches!(leaf, Leaf::BlankLine(_))) {
            self.add_leaf(leaf);
        }
    }
}

/// Whether the line at `cursor` continues `container`, consuming what
/// marks it so.
fn container_continue(container: &Container, c: &mut Cursor) -> Option<()> {
    match &container.kind {
        ContainerType::BlockQuote => c.attempt(|c| {
            scan_nonindent_space(c);
            scan_blockquote_start(c)
        }),
        ContainerType::IndentedCode => c.attempt(|c| {
            for _ in 0..4 {
                c.char(' ')?;
            }
            Some(())
        }),
        ContainerType::FencedCode { start_column, .. } => scan_spaces_to_column(c, *start_column),
        ContainerType::RawHtmlBlock => (!c.looking_at(scan_blankline)).then_some(()),
        ContainerType::ListItem {
            marker_column,
            padding,
            ..
        } => scan_blankline(c).or_else(|| {
            c.attempt(|c| {
                scan_spaces_to_column(c, marker_column + 1)?;
                c.up_to(padding.saturating_sub(1), |x| x == ' ');
                Some(())
            })
        }),
        ContainerType::Reference => {
            if c.looking_at(scan_blankline)
                || c.looking_at(|c| {
                    scan_nonindent_space(c);
                    scan_reference(c).then_some(())
                })
            {
                None
            } else {
                Some(())
            }
        }
        ContainerType::Document => Some(()),
    }
}

fn container_start(c: &mut Cursor) -> Option<ContainerType> {
    c.attempt(|c| {
        scan_nonindent_space(c);
        if scan_blockquote_start(c).is_some() {
            return Some(ContainerType::BlockQuote);
        }
        parse_list_marker(c)
    })
}

fn verbatim_container_start(c: &mut Cursor, last_line_is_text: bool) -> Option<ContainerType> {
    c.attempt(|c| {
        scan_nonindent_space(c);
        if let Some(fence) = parse_code_fence(c) {
            return Some(fence);
        }
        if last_line_is_text {
            return None;
        }
        if c.attempt(|c| {
            c.char(' ')?;
            (!c.looking_at(scan_blankline)).then_some(())
        })
        .is_some()
        {
            return Some(ContainerType::IndentedCode);
        }
        if c.looking_at(parse_html_block_start) {
            return Some(ContainerType::RawHtmlBlock);
        }
        if scan_reference(c) {
            return Some(ContainerType::Reference);
        }
        None
    })
}

fn parse_code_fence(c: &mut Cursor) -> Option<ContainerType> {
    c.attempt(|c| {
        let column = c.column;
        let fence = c
            .take_while1(|x| x == '`')
            .or_else(|| c.take_while1(|x| x == '~'))?;
        if fence.chars().count() < 3 {
            return None;
        }
        scan_spaces(c);
        let info = c.take_while(|x| x != '`' && x != '~');
        c.end()?;
        Some(ContainerType::FencedCode {
            start_column: column,
            fence,
            info,
        })
    })
}

const BLOCK_HTML_TAGS: &[&str] = &[
    "article",
    "header",
    "aside",
    "hgroup",
    "blockquote",
    "hr",
    "body",
    "li",
    "br",
    "map",
    "button",
    "object",
    "canvas",
    "ol",
    "caption",
    "output",
    "col",
    "p",
    "colgroup",
    "pre",
    "dd",
    "progress",
    "div",
    "section",
    "dl",
    "table",
    "dt",
    "tbody",
    "embed",
    "textarea",
    "fieldset",
    "tfoot",
    "figcaption",
    "th",
    "figure",
    "thead",
    "footer",
    "tr",
    "form",
    "ul",
    "h1",
    "h2",
    "h3",
    "h4",
    "h5",
    "h6",
    "video",
];

fn parse_html_block_start(c: &mut Cursor) -> Option<()> {
    if let Some((name, _)) = c.attempt(html_tag) {
        return BLOCK_HTML_TAGS.contains(&name.as_str()).then_some(());
    }
    c.string("<!--").or_else(|| c.string("-->"))
}

fn parse_list_marker(c: &mut Cursor) -> Option<ContainerType> {
    c.attempt(|c| {
        let column = c.column;
        let list_type = parse_bullet(c).or_else(|| parse_list_number(c))?;
        // One space before a blank or indented code, else every space.
        let padding = if scan_blankline(c).is_some()
            || c.attempt(|c| {
                c.char(' ')?;
                c.looking_at(|c| {
                    for _ in 0..4 {
                        c.char(' ')?;
                    }
                    Some(())
                })
                .then_some(())
            })
            .is_some()
        {
            1
        } else {
            c.take_while(|x| x == ' ').chars().count()
        };
        if padding == 0 {
            return None;
        }
        Some(ContainerType::ListItem {
            marker_column: column,
            padding: padding + list_type.marker_width(),
            list_type,
        })
    })
}

fn parse_bullet(c: &mut Cursor) -> Option<ListType> {
    c.attempt(|c| {
        let bullet = c.satisfy(|x| matches!(x, '+' | '*' | '-'))?;
        if bullet != '+' {
            let rule = c.looking_at(|c| {
                for _ in 0..2 {
                    scan_spaces(c);
                    c.char(bullet)?;
                }
                c.take_while(|x| x == ' ' || x == bullet);
                c.end()
            });
            if rule {
                return None;
            }
        }
        Some(ListType::Bullet(bullet))
    })
}

fn parse_list_number(c: &mut Cursor) -> Option<ListType> {
    c.attempt(|c| {
        let digits = c.take_while1(|x| x.is_ascii_digit())?;
        let wrap = c.satisfy(|x| x == '.' || x == ')')?;
        let number = digits.parse::<u64>().unwrap_or(u64::MAX);
        Some(ListType::Numbered(wrap, number))
    })
}

fn text_line_or_blank(c: &mut Cursor) -> Leaf {
    let text = c.take_rest();
    if text.chars().all(is_whitespace) {
        Leaf::BlankLine(text)
    } else {
        Leaf::TextLine(text)
    }
}

fn leaf(c: &mut Cursor, last_line_is_text: bool) -> Leaf {
    scan_nonindent_space(c);
    if let Some(level) = parse_atx_header_start(c) {
        let text = c.take_rest();
        return Leaf::AtxHeader(level, remove_atx_suffix(&text).trim().to_owned());
    }
    if last_line_is_text && let Some(level) = parse_setext_header_line(c) {
        return Leaf::SetextHeader(level, String::new());
    }
    if scan_hrule_line(c).is_some() {
        return Leaf::Rule;
    }
    text_line_or_blank(c)
}

fn remove_atx_suffix(text: &str) -> String {
    let trimmed = text.trim_end_matches([' ', '#']);
    if trimmed.is_empty() {
        String::new()
    } else if trimmed.ends_with('\\') {
        format!("{trimmed}#")
    } else {
        trimmed.to_owned()
    }
}

fn try_new_containers(
    line: &[char],
    offset: usize,
    last_line_is_text: bool,
) -> (Vec<ContainerType>, Leaf) {
    let mut c = Cursor::new(line);
    c.column = offset + 1;
    let mut containers = Vec::new();
    while let Some(container) = container_start(&mut c) {
        containers.push(container);
    }
    match verbatim_container_start(&mut c, last_line_is_text) {
        Some(verbatim) => {
            containers.push(verbatim);
            (containers, text_line_or_blank(&mut c))
        }
        None => (containers, leaf(&mut c, last_line_is_text)),
    }
}

fn process_line(stack: &mut Stack, text: &str) {
    let line: Vec<char> = text.chars().collect();
    // The continuation scanners of the open containers, the document's
    // first: the text after those that match, and how many do not.
    let mut c = Cursor::new(&line);
    let mut unmatched = 0;
    for (index, container) in stack.containers.iter().enumerate() {
        if container_continue(container, &mut c).is_none() {
            unmatched = stack.containers.len() - index;
            break;
        }
    }
    let offset = c.pos;
    let rest: Vec<char> = line[offset..].to_vec();
    let rest_text: String = rest.iter().collect();

    let top = stack.containers.last().expect("the document");
    let last_line_is_text = unmatched == 0 && is_text_line(top.children.last());
    let kind = top.kind.clone();
    match kind {
        ContainerType::RawHtmlBlock | ContainerType::IndentedCode if unmatched == 0 => {
            stack.add_leaf(Leaf::TextLine(rest_text));
        }
        ContainerType::FencedCode { fence, .. } => {
            if rest_text.starts_with(&fence) {
                stack.close_container();
            } else {
                stack.add_leaf(Leaf::TextLine(rest_text));
            }
        }
        ContainerType::Reference => {
            let (new, leaf) = try_new_containers(&rest, offset, last_line_is_text);
            stack.close_container();
            stack.add_new(new, leaf);
        }
        kind => {
            let (new, leaf) = try_new_containers(&rest, offset, last_line_is_text);
            let after_text = is_text_line(stack.containers.last().expect("top").children.last());
            match (new.is_empty(), leaf) {
                (true, Leaf::TextLine(t))
                    if unmatched > 0 && after_text && kind != ContainerType::IndentedCode =>
                {
                    stack.add_leaf(Leaf::TextLine(t));
                }
                (true, Leaf::SetextHeader(level, _)) if unmatched == 0 => {
                    // Only offered after a text line, which it replaces.
                    let top = stack.top();
                    if let Some(Elt::L(Leaf::TextLine(t))) = top.children.last().cloned() {
                        top.children.pop();
                        top.children.push(Elt::L(Leaf::SetextHeader(level, t)));
                    }
                }
                (_, leaf) => {
                    for _ in 0..unmatched {
                        stack.close_container();
                    }
                    stack.add_new(new, leaf);
                }
            }
        }
    }
}

fn extract_text(elt: &Elt) -> String {
    match elt {
        Elt::L(Leaf::TextLine(t)) => t.clone(),
        _ => String::new(),
    }
}

/// Parses `text` as elm-format's Markdown parser does.
fn parse(text: &str) -> Vec<Block> {
    let mut stack = Stack {
        containers: vec![Container {
            kind: ContainerType::Document,
            children: Vec::new(),
        }],
    };
    for line in text.lines() {
        process_line(&mut stack, &expand_tabs(line));
    }
    while stack.containers.len() > 1 {
        stack.close_container();
    }
    let document = stack.containers.pop().expect("the document");
    process_elts(&document.children)
}

/// A paragraph line as written, but with a leading `@docs` set as code.
fn without_docs(line: &str) -> String {
    match line.strip_prefix("@docs") {
        Some(rest) => format!("`@docs`{rest}"),
        None => line.to_owned(),
    }
}

fn process_elts(elts: &[Elt]) -> Vec<Block> {
    let mut blocks = Vec::new();
    let mut i = 0;
    while i < elts.len() {
        match &elts[i] {
            Elt::L(Leaf::TextLine(first)) => {
                let mut lines = vec![without_docs(first.trim_start())];
                i += 1;
                while let Some(Elt::L(Leaf::TextLine(t))) = elts.get(i) {
                    lines.push(without_docs(t.trim_start()));
                    i += 1;
                }
                let text = lines.join("\n");
                blocks.push(Block::Para(parse_inlines(text.trim_end())));
            }
            Elt::L(Leaf::BlankLine(_)) => i += 1,
            Elt::L(Leaf::AtxHeader(level, t) | Leaf::SetextHeader(level, t)) => {
                blocks.push(Block::Header(*level, parse_inlines(t)));
                i += 1;
            }
            Elt::L(Leaf::Rule) => {
                blocks.push(Block::HRule);
                i += 1;
            }
            Elt::C(container) => match &container.kind {
                ContainerType::Document => i += 1,
                ContainerType::BlockQuote => {
                    blocks.push(Block::Blockquote(process_elts(&container.children)));
                    i += 1;
                }
                ContainerType::ListItem { list_type, .. } => {
                    let list_type = *list_type;
                    let mut items = vec![&container.children];
                    let mut between_blank = false;
                    let mut j = i + 1;
                    loop {
                        match (elts.get(j), elts.get(j + 1)) {
                            (Some(Elt::C(next)), _) if same_list(next, list_type) => {
                                items.push(&next.children);
                                j += 1;
                            }
                            (Some(blank), Some(Elt::C(next)))
                                if is_blank_line(blank) && same_list(next, list_type) =>
                            {
                                between_blank = true;
                                items.push(&next.children);
                                j += 2;
                            }
                            _ => break,
                        }
                    }
                    let tight =
                        !between_blank && items.iter().all(|item| !item.iter().any(is_blank_line));
                    blocks.push(Block::List {
                        tight,
                        numbered: matches!(list_type, ListType::Numbered(..)),
                        items: items.into_iter().map(|item| process_elts(item)).collect(),
                    });
                    i = j;
                }
                ContainerType::FencedCode { info, .. } => {
                    let code: Vec<String> = container.children.iter().map(extract_text).collect();
                    let lang = info.split(' ').next().unwrap_or_default().to_owned();
                    blocks.push(Block::Code {
                        lang,
                        code: code.join("\n"),
                    });
                    i += 1;
                }
                ContainerType::IndentedCode => {
                    let mut lines: Vec<String> = Vec::new();
                    while let Some(elt) = elts.get(i) {
                        match elt {
                            Elt::L(Leaf::BlankLine(t)) => {
                                lines.push(t.chars().skip(1).collect());
                            }
                            Elt::C(Container {
                                kind: ContainerType::IndentedCode,
                                children,
                            }) => lines.extend(children.iter().map(extract_text)),
                            _ => break,
                        }
                        i += 1;
                    }
                    while lines.last().is_some_and(|l| l.chars().all(|c| c == ' ')) {
                        lines.pop();
                    }
                    blocks.push(Block::Code {
                        lang: String::new(),
                        code: lines.join("\n"),
                    });
                }
                ContainerType::RawHtmlBlock => {
                    let lines: Vec<String> = container.children.iter().map(extract_text).collect();
                    blocks.push(Block::Html(lines.join("\n")));
                    i += 1;
                }
                ContainerType::Reference => {
                    let mut lines: Vec<String> = Vec::new();
                    while let Some(Elt::C(Container {
                        kind: ContainerType::Reference,
                        children,
                    })) = elts.get(i)
                    {
                        lines.extend(children.iter().map(extract_text));
                        i += 1;
                    }
                    let references: Option<Vec<_>> =
                        lines.iter().map(|line| reference(line.trim())).collect();
                    match references {
                        Some(references) => blocks.push(Block::References(references)),
                        // A definition over several lines prints as
                        // `[??]: ??`: keep it as code.
                        None => blocks.push(Block::Code {
                            lang: "text".into(),
                            code: lines.join("\n"),
                        }),
                    }
                }
            },
        }
    }
    blocks
}

fn same_list(container: &Container, list_type: ListType) -> bool {
    matches!(container.kind, ContainerType::ListItem { list_type: other, .. } if other.matches(list_type))
}

// Inlines.

fn parse_inlines(text: &str) -> Vec<Inline> {
    let chars: Vec<char> = text.chars().collect();
    let mut c = Cursor::new(&chars);
    let mut out = Vec::new();
    while let Some(mut inlines) = inline(&mut c) {
        out.append(&mut inlines);
    }
    out
}

fn inline(c: &mut Cursor) -> Option<Vec<Inline>> {
    if c.at_end() {
        return None;
    }
    c.attempt(ascii_str)
        .or_else(|| c.attempt(space).map(|s| vec![s]))
        .or_else(|| c.attempt(|c| enclosure(c, '*')))
        .or_else(|| {
            c.attempt(|c| {
                if c.last.is_some_and(is_alnum) {
                    return None;
                }
                enclosure(c, '_')
            })
        })
        .or_else(|| c.attempt(|c| code(c).map(|(code, _)| vec![code])))
        .or_else(|| c.attempt(link))
        .or_else(|| c.attempt(image))
        .or_else(|| c.attempt(raw_html).map(|h| vec![h]))
        .or_else(|| c.attempt(autolink))
        .or_else(|| c.attempt(entity).map(|e| vec![e]))
        .or_else(|| c.attempt(sym))
}

const SCHEMES: &[&str] = &[
    "coap",
    "doi",
    "javascript",
    "aaa",
    "aaas",
    "about",
    "acap",
    "cap",
    "cid",
    "crid",
    "data",
    "dav",
    "dict",
    "dns",
    "file",
    "ftp",
    "geo",
    "go",
    "gopher",
    "h323",
    "http",
    "https",
    "iax",
    "icap",
    "im",
    "imap",
    "info",
    "ipp",
    "iris",
    "iris.beep",
    "iris.xpc",
    "iris.xpcs",
    "iris.lwz",
    "ldap",
    "mailto",
    "mid",
    "msrp",
    "msrps",
    "mtqp",
    "mupdate",
    "news",
    "nfs",
    "ni",
    "nih",
    "nntp",
    "opaquelocktoken",
    "pop",
    "pres",
    "rtsp",
    "service",
    "session",
    "shttp",
    "sieve",
    "sip",
    "sips",
    "sms",
    "snmp",
    "soap.beep",
    "soap.beeps",
    "tag",
    "tel",
    "telnet",
    "tftp",
    "thismessage",
    "tn3270",
    "tip",
    "tv",
    "urn",
    "vemmi",
    "ws",
    "wss",
    "xcon",
    "xcon-userid",
    "xmlrpc.beep",
    "xmlrpc.beeps",
    "xmpp",
    "z39.50r",
    "z39.50s",
    "adiumxtra",
    "afp",
    "afs",
    "aim",
    "apt",
    "attachment",
    "aw",
    "beshare",
    "bitcoin",
    "bolo",
    "callto",
    "chrome",
    "chrome-extension",
    "com-eventbrite-attendee",
    "content",
    "cvs",
    "dlna-playsingle",
    "dlna-playcontainer",
    "dtn",
    "dvb",
    "ed2k",
    "facetime",
    "feed",
    "finger",
    "fish",
    "gg",
    "git",
    "gizmoproject",
    "gtalk",
    "hcp",
    "icon",
    "ipn",
    "irc",
    "irc6",
    "ircs",
    "itms",
    "jar",
    "jms",
    "keyparc",
    "lastfm",
    "ldaps",
    "magnet",
    "maps",
    "market",
    "message",
    "mms",
    "ms-help",
    "msnim",
    "mumble",
    "mvn",
    "notes",
    "oid",
    "palm",
    "paparazzi",
    "platform",
    "proxy",
    "psyc",
    "query",
    "res",
    "resource",
    "rmi",
    "rsync",
    "rtmp",
    "secondlife",
    "sftp",
    "sgn",
    "skype",
    "smb",
    "soldat",
    "spotify",
    "ssh",
    "steam",
    "svn",
    "teamspeak",
    "things",
    "udp",
    "unreal",
    "ut2004",
    "ventrilo",
    "view-source",
    "webcal",
    "wtai",
    "wyciwyg",
    "xfire",
    "xri",
    "ymsgr",
];

/// Whether `s` is one of Cheapskate's URI schemes, in lower or upper case.
fn is_scheme(s: &str) -> bool {
    SCHEMES
        .iter()
        .any(|scheme| *scheme == s || scheme.to_uppercase() == s)
}

fn ascii_str(c: &mut Cursor) -> Option<Vec<Inline>> {
    let t = c.take_while1(is_ascii_alnum)?;
    if c.peek() == Some(':') && is_scheme(&t) {
        return uri(c, &t);
    }
    Some(vec![Inline::Str(t)])
}

fn uri(c: &mut Cursor, scheme: &str) -> Option<Vec<Inline>> {
    c.char(':')?;
    let mut open = 0usize;
    let mut x = String::new();
    while let Some(ch) = c.peek() {
        let go = match ch {
            ' ' | '\n' => false,
            '(' => {
                open += 1;
                true
            }
            ')' if open > 0 => {
                open -= 1;
                true
            }
            ')' => false,
            '+' | '/' => true,
            ch if ch.is_whitespace() => false,
            _ => true,
        };
        if !go {
            break;
        }
        c.bump();
        x.push(ch);
    }
    let last = x.chars().last()?;
    if ".;?!:,".contains(last) {
        let mut init = x.clone();
        init.pop();
        let mut out = auto_link(&format!("{scheme}:{init}"));
        out.push(Inline::Str(last.to_string()));
        Some(out)
    } else {
        Some(auto_link(&format!("{scheme}:{x}")))
    }
}

fn auto_link(t: &str) -> Vec<Inline> {
    let chars: Vec<char> = t.chars().collect();
    let mut c = Cursor::new(&chars);
    let mut inlines = Vec::new();
    while !c.at_end() {
        if let Some(s) = c.take_while1(|x| x != '&') {
            inlines.push(Inline::Str(s));
        } else if let Some(e) = c.attempt(entity) {
            inlines.push(e);
        } else {
            c.bump();
            inlines.push(Inline::Str("&".into()));
        }
    }
    vec![Inline::Link(
        inlines,
        Target::Url(t.to_owned()),
        String::new(),
    )]
}

fn space(c: &mut Cursor) -> Option<Inline> {
    let ss = c.take_while1(is_whitespace)?;
    Some(if ss.contains('\n') {
        if ss.starts_with("  ") {
            Inline::LineBreak
        } else {
            Inline::SoftBreak
        }
    } else {
        Inline::Space
    })
}

fn sym(c: &mut Cursor) -> Option<Vec<Inline>> {
    let ch = c.bump()?;
    if ch == '\\' {
        if let Some(escaped) = c.satisfy(is_escapable) {
            return Some(vec![Inline::Str(escaped.to_string())]);
        }
        if c.char('\n').is_some() {
            return Some(vec![Inline::LineBreak]);
        }
        return Some(vec![Inline::Str("\\".into())]);
    }
    Some(vec![Inline::Str(ch.to_string())])
}

fn enclosure(c: &mut Cursor, delim: char) -> Option<Vec<Inline>> {
    let cs = c.take_while1(|x| x == delim)?;
    if let Some(s) = c.attempt(space) {
        return Some(vec![Inline::Str(cs), s]);
    }
    match cs.chars().count() {
        3 => Some(three(c, delim)),
        2 => Some(two(c, delim, Vec::new())),
        1 => Some(one(c, delim, Vec::new())),
        _ => Some(vec![Inline::Str(cs)]),
    }
}

fn single(make: fn(Vec<Inline>) -> Inline, inlines: Vec<Inline>) -> Vec<Inline> {
    if inlines.is_empty() {
        Vec::new()
    } else {
        vec![make(inlines)]
    }
}

fn one(c: &mut Cursor, delim: char, prefix: Vec<Inline>) -> Vec<Inline> {
    let mut contents = Vec::new();
    loop {
        let step = c
            .attempt(|c| {
                if c.peek() == Some(delim) {
                    return None;
                }
                inline(c)
            })
            .or_else(|| {
                c.attempt(|c| {
                    c.char(delim)?;
                    c.char(delim)?;
                    if c.peek() == Some(delim) {
                        return None;
                    }
                    Some(two(c, delim, Vec::new()))
                })
            });
        match step {
            Some(mut inlines) => contents.append(&mut inlines),
            None => break,
        }
    }
    let mut all = prefix;
    all.append(&mut contents);
    if c.char(delim).is_some() {
        single(Inline::Emph, all)
    } else {
        let mut out = vec![Inline::Str(delim.to_string())];
        out.append(&mut all);
        out
    }
}

fn two(c: &mut Cursor, delim: char, prefix: Vec<Inline>) -> Vec<Inline> {
    let ender: String = [delim, delim].iter().collect();
    let mut contents = Vec::new();
    loop {
        let step = c.attempt(|c| {
            if c.looking_at(|c| c.string(&ender)) {
                return None;
            }
            inline(c)
        });
        match step {
            Some(mut inlines) => contents.append(&mut inlines),
            None => break,
        }
    }
    let mut all = prefix;
    all.append(&mut contents);
    if c.string(&ender).is_some() {
        single(Inline::Strong, all)
    } else {
        let mut out = vec![Inline::Str(ender)];
        out.append(&mut all);
        out
    }
}

fn three(c: &mut Cursor, delim: char) -> Vec<Inline> {
    let mut contents = Vec::new();
    loop {
        let step = c.attempt(|c| {
            if c.peek() == Some(delim) {
                return None;
            }
            inline(c)
        });
        match step {
            Some(mut inlines) => contents.append(&mut inlines),
            None => break,
        }
    }
    let pair: String = [delim, delim].iter().collect();
    if c.string(&pair).is_some() {
        return one(c, delim, single(Inline::Strong, contents));
    }
    if c.char(delim).is_some() {
        return two(c, delim, single(Inline::Emph, contents));
    }
    let mut out = vec![Inline::Str([delim, delim, delim].iter().collect())];
    out.append(&mut contents);
    out
}

/// A code span and the text it was written as.
fn code(c: &mut Cursor) -> Option<(Inline, String)> {
    let ticks = c.take_while1(|x| x == '`')?;
    let mut contents = String::new();
    loop {
        if c.attempt(|c| {
            c.string(&ticks)?;
            (c.peek() != Some('`')).then_some(())
        })
        .is_some()
        {
            break;
        }
        let run = c
            .take_while1(|x| x != '`')
            .or_else(|| c.take_while1(|x| x == '`'))?;
        contents.push_str(&run);
    }
    let raw = format!("{ticks}{contents}{ticks}");
    Some((Inline::Code(contents.trim().to_owned()), raw))
}

fn link_label(c: &mut Cursor) -> Option<String> {
    c.attempt(|c| {
        c.char('[')?;
        let mut out = String::new();
        loop {
            if c.char(']').is_some() {
                return Some(out);
            }
            if let Some(s) = c.take_while1(|x| x != '`' && x != '[' && x != ']' && x != '\\') {
                out.push_str(&s);
            } else if let Some(e) = c.attempt(escaped) {
                out.push(e);
            } else if let Some(inner) = link_label(c) {
                out.push('[');
                out.push_str(&inner);
                out.push(']');
            } else if let Some((_, raw)) = c.attempt(code) {
                out.push_str(&raw);
            } else {
                return None;
            }
        }
    })
}

fn escaped(c: &mut Cursor) -> Option<char> {
    c.char('\\')?;
    c.satisfy(is_escapable)
}

fn link_url(c: &mut Cursor) -> Option<String> {
    if c.char('<').is_some() {
        let mut out = String::new();
        loop {
            if c.char('>').is_some() {
                return Some(out);
            }
            let ch = c
                .attempt(|c| c.satisfy(|x| x != '\\' && x != '\r' && x != '\n'))
                .or_else(|| {
                    c.attempt(|c| {
                        c.char('\\')?;
                        c.satisfy(|x| is_escapable(x) && x != '\r' && x != '\n')
                    })
                })?;
            out.push(ch);
        }
    }
    let mut out = String::new();
    while let Some(chunk) = url_chunk(c) {
        out.push_str(&chunk);
    }
    Some(out)
}

fn url_chunk(c: &mut Cursor) -> Option<String> {
    if let Some(s) = c.take_while1(|x| !matches!(x, ' ' | '\n' | '(' | ')' | '\\')) {
        return Some(s);
    }
    if let Some(e) = c.attempt(escaped) {
        return Some(e.to_string());
    }
    c.attempt(|c| {
        c.char('(')?;
        let mut inner = String::new();
        loop {
            if c.char(')').is_some() {
                return Some(format!("({inner})"));
            }
            inner.push_str(&url_chunk(c)?);
        }
    })
}

fn link_title(c: &mut Cursor) -> Option<String> {
    c.attempt(|c| {
        let open = c.satisfy(|x| x == '"' || x == '\'' || x == '(')?;
        match c.peek() {
            None => return None,
            Some(x) if is_whitespace(x) || x == ')' => return None,
            _ => {}
        }
        let close = if open == '(' { ')' } else { open };
        let mut out = String::new();
        loop {
            if c.attempt(|c| {
                c.char(close)?;
                (!c.peek().is_some_and(is_alnum)).then_some(())
            })
            .is_some()
            {
                return Some(out);
            }
            if let Some(s) = c.take_while1(|x| x != close && x != '\\') {
                out.push_str(&s);
            } else if let Some(e) = c.attempt(escaped) {
                out.push(e);
            } else {
                let nested = link_title(c)?;
                out.push(open);
                out.push_str(&nested);
                out.push(close);
            }
        }
    })
}

fn link(c: &mut Cursor) -> Option<Vec<Inline>> {
    let label = link_label(c)?;
    let text = parse_inlines(&label);
    if let Some(inline) = c.attempt(|c| {
        c.char('(')?;
        scan_spaces(c);
        let url = link_url(c)?;
        let title = c
            .attempt(|c| {
                scan_spnl(c);
                let title = link_title(c)?;
                scan_spaces(c);
                Some(title)
            })
            .unwrap_or_default();
        c.char(')')?;
        Some(Inline::Link(text.clone(), Target::Url(url), title))
    }) {
        return Some(vec![inline]);
    }
    let reference = c
        .attempt(|c| {
            scan_spnl(c);
            link_label(c)
        })
        .unwrap_or(label);
    Some(vec![Inline::Link(
        text,
        Target::Ref(reference),
        String::new(),
    )])
}

fn scan_spnl(c: &mut Cursor) {
    scan_spaces(c);
    if c.char('\n').is_some() {
        scan_spaces(c);
    }
}

fn image(c: &mut Cursor) -> Option<Vec<Inline>> {
    c.char('!')?;
    match c.attempt(link) {
        Some(inlines) => match inlines.as_slice() {
            [Inline::Link(text, Target::Url(url), title)] => Some(vec![Inline::Image(
                text.clone(),
                url.clone(),
                title.clone(),
            )]),
            _ => {
                let mut out = vec![Inline::Str("!".into())];
                out.extend(inlines);
                Some(out)
            }
        },
        None => Some(vec![Inline::Str("!".into())]),
    }
}

/// An HTML tag: its lowercased name and its text as written.
fn html_tag(c: &mut Cursor) -> Option<(String, String)> {
    c.char('<')?;
    let closing = c.char('/').is_some();
    let name = c.take_while1(|x| is_ascii_alnum(x) || x == '?' || x == '!')?;
    let mut attrs = String::new();
    while let Some(attr) = c.attempt(|c| {
        let ss = c.take_while(char::is_whitespace);
        let x = c.satisfy(char::is_alphabetic)?;
        let xs = c.take_while(|y| is_ascii_alnum(y) || y == ':');
        c.char('=')?;
        let v = c
            .attempt(|c| quoted(c, '"'))
            .or_else(|| c.attempt(|c| quoted(c, '\'')))
            .or_else(|| c.take_while1(is_alnum))
            .unwrap_or_default();
        Some(format!("{ss}{x}{xs}={v}"))
    }) {
        attrs.push_str(&attr);
    }
    let finish = c.take_while(|x| x.is_whitespace() || x == '/');
    c.char('>')?;
    let slash = if closing { "/" } else { "" };
    Some((
        name.to_lowercase(),
        format!("<{slash}{name}{attrs}{finish}>"),
    ))
}

fn quoted(c: &mut Cursor, q: char) -> Option<String> {
    c.char(q)?;
    let contents = c.take_while(|x| x != q);
    c.char(q)?;
    Some(format!("{q}{contents}{q}"))
}

fn raw_html(c: &mut Cursor) -> Option<Inline> {
    if let Some((_, text)) = c.attempt(html_tag) {
        return Some(Inline::RawHtml(text));
    }
    c.attempt(|c| {
        c.string("<!--")?;
        let mut out = String::from("<!--");
        loop {
            if c.string("-->").is_some() {
                out.push_str("-->");
                return Some(Inline::RawHtml(out));
            }
            out.push(c.bump()?);
        }
    })
}

fn autolink(c: &mut Cursor) -> Option<Vec<Inline>> {
    c.char('<')?;
    let s = c.take_while1(|x| x != ':' && x != '@')?;
    let rest = c.take_while1(|x| x != '>' && x != ' ')?;
    c.char('>')?;
    let whole = format!("{s}{rest}");
    if rest.starts_with('@') {
        Some(vec![Inline::Link(
            vec![Inline::Str(whole.clone())],
            Target::Url(format!("mailto:{whole}")),
            String::new(),
        )])
    } else if is_scheme(&s) {
        Some(auto_link(&whole))
    } else {
        None
    }
}

fn entity(c: &mut Cursor) -> Option<Inline> {
    c.char('&')?;
    let body = c
        .take_while1(|x| x.is_ascii_alphabetic())
        .or_else(|| {
            c.attempt(|c| {
                c.char('#')?;
                Some(format!("#{}", c.take_while1(|x| x.is_ascii_digit())?))
            })
        })
        .or_else(|| {
            c.attempt(|c| {
                c.char('#')?;
                let x = c.satisfy(|x| x == 'x' || x == 'X')?;
                let digits = c.take_while1(|x| x.is_ascii_hexdigit())?;
                Some(format!("#{x}{digits}"))
            })
        })?;
    c.char(';')?;
    Some(Inline::Entity(format!("&{body};")))
}

/// A link reference definition, `[label]: url "title"`.
fn reference(text: &str) -> Option<(String, String, String)> {
    let chars: Vec<char> = text.chars().collect();
    let mut c = Cursor::new(&chars);
    let label = link_label(&mut c)?;
    c.char(':')?;
    scan_spnl(&mut c);
    let url = link_url(&mut c)?;
    let title = c
        .attempt(|c| {
            scan_spnl(c);
            link_title(c)
        })
        .unwrap_or_default();
    c.end()?;
    Some((label, url, title))
}

// Printing, as elm-format's `ElmFormat.Render.Markdown`.

fn format_markdown(blocks: &[Block]) -> String {
    let initial = match blocks.first() {
        Some(Block::Para(inlines)) => matches!(
            inlines.as_slice(),
            [Inline::Str(a), Inline::Str(b), ..] if a == "@" && b == "docs"
        ),
        None => false,
        Some(_) => true,
    };
    let trailing = match blocks.len() {
        0 => false,
        1 => initial,
        _ => true,
    };
    format_blocks(blocks, false, initial, trailing)
}

fn format_blocks(blocks: &[Block], list_item: bool, initial: bool, trailing: bool) -> String {
    let mut out = String::new();
    if initial {
        out.push_str("\n\n");
    }
    let joined = list_item && matches!(blocks, [Block::Para(_), Block::List { .. }]);
    for (index, block) in blocks.iter().enumerate() {
        if index > 0 && !joined {
            out.push('\n');
        }
        out.push_str(&format_block(block));
    }
    if trailing {
        out.push('\n');
    }
    out
}

/// Haskell's `unlines . prefix first rest . lines`.
fn prefix_lines(text: &str, first: &str, rest: &str) -> String {
    let mut out = String::new();
    for (index, line) in text.lines().enumerate() {
        out.push_str(if index == 0 { first } else { rest });
        out.push_str(line);
        out.push('\n');
    }
    out
}

fn format_block(block: &Block) -> String {
    match block {
        Block::Para(inlines) => format!("{}\n", format_inlines(inlines, true)),
        Block::Header(level, inlines) => format!(
            "\n{} {}\n",
            "#".repeat(*level),
            format_inlines(inlines, true)
        ),
        Block::Blockquote(blocks) => {
            prefix_lines(&format_blocks(blocks, false, false, false), "> ", "> ")
        }
        Block::List {
            tight,
            numbered,
            items,
        } => {
            let rendered: Vec<String> = items
                .iter()
                .enumerate()
                .map(|(index, item)| {
                    let body = format_blocks(item, true, false, false);
                    if *numbered {
                        let number = index + 1;
                        let marker = if number < 10 {
                            format!("{number}.  ")
                        } else {
                            format!("{number}. ")
                        };
                        prefix_lines(&body, &marker, "    ")
                    } else {
                        prefix_lines(&body, "  - ", "    ")
                    }
                })
                .collect();
            rendered.join(if *tight { "" } else { "\n" })
        }
        Block::Code { lang, code } => {
            // Without its trailing blank lines, which elm-format drops one
            // run at a time; empty, which elm-format fails on, nothing.
            let lines: Vec<&str> = code.split('\n').collect();
            let Some(last) = lines.iter().rposition(|line| !line.trim().is_empty()) else {
                return String::new();
            };
            let lang = if lang.is_empty() || lang == "elm" {
                "text"
            } else {
                lang
            };
            let code = fence_safe(&lines[..=last].join("\n"));
            format!("```{lang}\n{code}\n```\n")
        }
        Block::Html(text) => format!("{text}\n"),
        Block::HRule => "---\n".to_owned(),
        Block::References(references) => {
            let mut out = String::new();
            for (label, url, title) in references {
                let _ = write!(out, "[{label}]: {url}");
                if !title.is_empty() {
                    let _ = write!(out, " \"{title}\"");
                }
                out.push('\n');
            }
            out
        }
    }
}

/// `code` with a space before every line that would close its fence.
fn fence_safe(code: &str) -> String {
    code.split('\n')
        .map(|line| {
            if line.starts_with("```") || line.starts_with("~~~") {
                format!(" {line}")
            } else {
                line.to_owned()
            }
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fn format_inlines(inlines: &[Inline], fix: bool) -> String {
    inlines
        .iter()
        .map(|inline| format_inline(inline, fix))
        .collect()
}

fn format_inline(inline: &Inline, fix: bool) -> String {
    match inline {
        Inline::Str(text) => {
            if fix {
                let mut out = String::with_capacity(text.len());
                for c in text.chars() {
                    match c {
                        '\\' => out.push_str("\\\\"),
                        '`' => out.push_str("\\`"),
                        '_' => out.push_str("\\_"),
                        '*' => out.push_str("\\*"),
                        c => out.push(c),
                    }
                }
                out
            } else {
                text.clone()
            }
        }
        Inline::Space => " ".into(),
        Inline::SoftBreak | Inline::LineBreak => "\n".into(),
        Inline::Emph(inlines) => format!("_{}_", format_inlines(inlines, true)),
        Inline::Strong(inlines) => format!("**{}**", format_inlines(inlines, true)),
        Inline::Code(text) => {
            let longest = text
                .split(|c| c != '`')
                .map(str::len)
                .max()
                .unwrap_or_default();
            if longest == 0 {
                format!("`{text}`")
            } else {
                let delimiter = "`".repeat(longest + 1);
                format!("{delimiter} {text} {delimiter}")
            }
        }
        Inline::Link(inlines, Target::Url(url), title) => {
            let text = format_inlines(inlines, fix);
            let raw = format_inlines(inlines, false);
            if raw == *url && title.is_empty() && is_absolute_url(url) {
                if fix { format!("<{url}>") } else { url.clone() }
            } else {
                let title = if title.is_empty() {
                    String::new()
                } else {
                    format!(" \"{title}\"")
                };
                format!("[{text}]({url}{title})")
            }
        }
        Inline::Link(inlines, Target::Ref(reference), _) => {
            let text = format_inlines(inlines, fix);
            if text == *reference || reference.is_empty() {
                format!("[{text}]")
            } else {
                format!("[{text}][{reference}]")
            }
        }
        Inline::Image(inlines, url, title) => {
            let title = if title.is_empty() {
                String::new()
            } else {
                format!(" \"{title}\"")
            };
            format!("![{}]({url}{title})", format_inlines(inlines, fix))
        }
        Inline::Entity(text) | Inline::RawHtml(text) => text.clone(),
    }
}

/// CommonMark's absolute URI: a scheme of two or more characters, then
/// `:`.
fn is_absolute_url(url: &str) -> bool {
    let Some((scheme, _)) = url.split_once(':') else {
        return false;
    };
    let mut chars = scheme.chars();
    chars.next().is_some_and(|c| c.is_ascii_alphabetic())
        && scheme.len() >= 2
        && chars.all(|c| c.is_ascii_alphanumeric() || matches!(c, '+' | '.' | '-'))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Comments that exercise each construct elm-format rewrites, and each
    /// hazard the port departs from elm-format on.
    const SAMPLES: &[&str] = &[
        "Items:\n\n* one\n* two",
        "Items:\n\n+ one\n- two\n\n  continued",
        "Steps:\n\n3. three\n4) four",
        "Some *em*, _em_, **strong**, __strong__, ***both***.",
        "snake_case, 2*3*4, notes/* and a \\ backslash and a ` tick",
        "Intro.\n\nHeading\n=======\n\n## Sub ##\n\nText.",
        "Example:\n\n    GET /v1/notes\n    x = 1\n\nAfter.",
        "```\nGET /v1/{name=notes/*}\n```\n\n```elm\nx = { a = 1 }\n```\n\n~~~proto\nmessage M {}\n~~~",
        "```text\n```",
        "```\nunclosed",
        "```\ncode\n\n\n\n\n\n\n\n\n\n\n",
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
        "Non-ASCII: café, naïve, “quotes”, — and ✓.",
        "  \n\n   ",
        "",
    ];

    #[test]
    fn canonical_text_is_a_fixed_point() {
        for sample in SAMPLES {
            let once = canonical(sample);
            assert_eq!(canonical(&once), once, "{sample:?}");
            let blocks = blocks(sample);
            assert_eq!(super::blocks(&blocks), blocks, "{sample:?}");
            let item = item_blocks(sample);
            assert_eq!(item_blocks(&item), item, "{sample:?}");
        }
    }

    #[test]
    fn nothing_opens_or_closes_an_elm_comment() {
        for sample in SAMPLES {
            let text = canonical(sample);
            assert!(!text.contains("{-") && !text.contains("-}"), "{text}");
        }
        assert_eq!(escape_comment("a {-| b -}-} c"), "a { -| b - }- } c");
        assert_eq!(escape_comment("{-}"), "{ - }");
    }

    #[test]
    fn lists_take_elm_formats_markers() {
        assert_eq!(
            canonical("Items:\n\n* one\n+ two"),
            "Items:\n\n  - one\n\n  - two\n\n"
        );
        assert_eq!(
            canonical("Items:\n\n* one\n* two"),
            "Items:\n\n  - one\n  - two\n\n"
        );
        assert_eq!(
            canonical("Steps:\n\n3. three\n4. four"),
            "Steps:\n\n1.  three\n2.  four\n\n"
        );
    }

    #[test]
    fn text_is_escaped_and_emphasis_respelled() {
        assert_eq!(
            canonical("Some *em* and __strong__."),
            "Some _em_ and **strong**.\n"
        );
        // elm-format reads `*3*` as emphasis and prints `_3_`, which it
        // then reads as text: the fixed point escapes it.
        assert_eq!(
            canonical("snake_case, 2*3*4, notes/*, \\ and `"),
            "snake\\_case, 2\\_3\\_4, notes/\\*, \\\\ and \\`\n"
        );
        assert_eq!(
            canonical("See https://example.com/a_b."),
            "See <https://example.com/a_b>.\n"
        );
        assert_eq!(canonical("a\tb  \nc"), "a b\nc\n");
    }

    #[test]
    fn headings_are_atx_after_blank_lines() {
        assert_eq!(
            canonical("Intro.\n\nHeading\n=======\n\nText."),
            "Intro.\n\n\n# Heading\n\nText.\n\n"
        );
        assert_eq!(canonical("# Only"), "\n\n\n# Only\n\n");
    }

    #[test]
    fn code_elm_format_would_reformat_is_fenced_as_text() {
        assert_eq!(
            canonical("Example:\n\n    GET /v1/notes"),
            "Example:\n\n```text\nGET /v1/notes\n```\n\n"
        );
        assert_eq!(
            canonical("```elm\nx = 1\n```"),
            "\n\n```text\nx = 1\n```\n\n"
        );
        assert_eq!(
            canonical("~~~proto\nmessage M {}\n~~~"),
            "\n\n```proto\nmessage M {}\n```\n\n"
        );
        // Empty, which elm-format fails on, it is dropped; a line that
        // would close the fence is indented.
        assert_eq!(canonical("A.\n\n```text\n```"), "A.\n");
        assert_eq!(canonical("~~~\n```\n~~~"), "\n\n```text\n ```\n```\n\n");
        assert_eq!(
            canonical("```\nnever closed"),
            "\n\n```text\nnever closed\n```\n\n"
        );
        // elm-format drops a code block's trailing blank lines one a run.
        assert_eq!(
            canonical("```\ncode\n\n\n  \n```"),
            "\n\n```text\ncode\n```\n\n"
        );
        assert_eq!(
            canonical("```\ncode\n\n\n\n\n\n\n\n\n\n\n\n"),
            "\n\n```text\ncode\n```\n\n"
        );
    }

    #[test]
    fn docs_lines_stay_text() {
        assert_eq!(
            canonical("Text.\n@docs foo, bar"),
            "Text.\n`@docs` foo, bar\n"
        );
    }

    #[test]
    fn unreadable_references_stay_as_code() {
        assert_eq!(canonical("[r]: /u \"T\""), "\n\n[r]: /u \"T\"\n\n");
        assert_eq!(
            canonical("[r]: /u junk"),
            "\n\n```text\n[r]: /u junk\n```\n\n"
        );
    }

    #[test]
    fn headings_in_list_items_become_strong_text() {
        assert_eq!(
            canonical("- item\n\n  # heading"),
            "\n\n  - item\n\n    **heading**\n\n"
        );
        assert_eq!(item_blocks("# heading\n\ntext"), "**heading**\n\ntext");
        assert_eq!(blocks("# heading\n\ntext"), "# heading\n\ntext");
    }

    /// The links generated docs carry, each as the generator writes it,
    /// which must be its own elm-format form: a code span as link text, a
    /// page and an anchor, an anchor alone, an absolute URL, an anchor
    /// ending in `_`; in a list item, at the end of a line and before a
    /// line break.
    const LINKS: &[&str] = &[
        "[`message notes.v1.Note`](Notes-V1-Note#descriptor)",
        "Describes [`Notes.V1.Note`](Notes-V1#Note).",
        "Encodes a [`Node_`](#Node_) as proto3 JSON.",
        "`rpc Get(A) returns (B)`.\n\
         Connect: `POST /s.v1.S/Get`.\n\
         Transcode: no HTTP rule, follows the Connect path.\n\n\
         Described by [`descriptorGet`](#descriptorGet).",
        "`rpc Get(A) returns (B)`.\n\
         Connect: `POST /s.v1.S/Get`.\n\
         Transcode:\n\n\
         \x20 - binding 0: `GET /v1/a`;\n\
         \x20 - binding 1: `GET /v1/b`, body `*`.\n\n\
         Described by [`descriptorGet`](#descriptorGet).",
        "Holds a [`Proto.Any.Any`](https://github.com/bruckner/elm-connect/blob/\
         0.1.0/src/Proto/Any.elm).",
        "[`message s.v1.M`](S-V1-M#descriptor)\n\n\
         \x20 - [`descriptor`](S-V1-M#descriptor_): The a. Required.\n\
         \x20 - [`type_`](S-V1-M#type_)\n\
         \x20 - [`kind`](S-V1-M#kind): See [`MKind`](#MKind).",
        "Text then a link at the end of a line [`a`](#a)\nand more.",
    ];

    #[test]
    fn generated_links_are_their_own_elm_format_form() {
        for sample in LINKS {
            assert_eq!(blocks(sample), *sample, "{sample:?}");
            assert_eq!(item_blocks(sample), *sample, "{sample:?}");
        }
    }

    #[test]
    fn a_paragraph_first_is_known() {
        assert!(starts_with_paragraph("Text.\n\n- a"));
        assert!(!starts_with_paragraph("- a\n\nText."));
        assert!(!starts_with_paragraph("# H"));
        assert!(!starts_with_paragraph(""));
    }
}
