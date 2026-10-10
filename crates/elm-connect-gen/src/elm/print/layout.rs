//! The block model elm-format lays code out with.
//!
//! A [`Block`] is one or more lines. Lines are built from text and *tabs*;
//! a tab advances to the next multiple of four columns (always at least
//! one column), so indentation inside a construct that starts at an odd
//! column snaps to elm-format's four-column grid. Two operations nest
//! blocks:
//!
//! - [`Block::indent`] puts a tab before every line.
//! - [`Block::prefix`] puts text before the first line and pads the
//!   following lines with as many spaces, which is how `{ `, `, `, `(` and
//!   `|> ` align what follows them.
//!
//! This mirrors `Box` in elm-format's source (`Line` of text, space and
//! tab; `prefix`; `indent`), which is why a few direct rules on top of it
//! reproduce elm-format's output without a general pretty printer.

/// One piece of a line.
#[derive(Debug, Clone)]
enum Seg {
    Text(String),
    Tab,
}

/// A line under construction.
#[derive(Debug, Clone, Default)]
struct Line(Vec<Seg>);

impl Line {
    fn text(s: &str) -> Self {
        Self(vec![Seg::Text(s.to_owned())])
    }

    fn render(&self, out: &mut String) {
        let start = out.len();
        let mut column = 0;
        for seg in &self.0 {
            match seg {
                Seg::Text(s) => {
                    out.push_str(s);
                    column += s.chars().count();
                }
                Seg::Tab => {
                    let width = 4 - column % 4;
                    out.extend(std::iter::repeat_n(' ', width));
                    column += width;
                }
            }
        }
        let trimmed = out[start..].trim_end().len();
        out.truncate(start + trimmed);
    }
}

/// One or more lines of laid-out code.
#[derive(Debug, Clone)]
pub(super) struct Block(Vec<Line>);

impl Block {
    /// A single line of text. The text must not contain a newline.
    pub(super) fn text(s: &str) -> Self {
        debug_assert!(!s.contains('\n'), "a block line cannot contain a newline");
        Self(vec![Line::text(s)])
    }

    /// An empty line, used to separate branches and bindings.
    pub(super) fn blank() -> Self {
        Self(vec![Line::default()])
    }

    /// Whether the block fits on one line.
    pub(super) fn is_single(&self) -> bool {
        self.0.len() == 1
    }

    /// The blocks one under another.
    pub(super) fn stack(blocks: impl IntoIterator<Item = Block>) -> Self {
        let lines: Vec<Line> = blocks.into_iter().flat_map(|b| b.0).collect();
        debug_assert!(!lines.is_empty(), "a block has at least one line");
        Self(lines)
    }

    /// The blocks one under another, separated by blank lines.
    pub(super) fn stack_spaced(blocks: impl IntoIterator<Item = Block>) -> Self {
        let mut lines = Vec::new();
        for (i, block) in blocks.into_iter().enumerate() {
            if i > 0 {
                lines.push(Line::default());
            }
            lines.extend(block.0);
        }
        Self(lines)
    }

    /// Single-line blocks joined on one line with `sep` between them.
    pub(super) fn row(blocks: impl IntoIterator<Item = Block>, sep: &str) -> Self {
        let mut line = Line::default();
        for (i, block) in blocks.into_iter().enumerate() {
            debug_assert!(block.is_single(), "row joins single-line blocks");
            if i > 0 && !sep.is_empty() {
                line.0.push(Seg::Text(sep.to_owned()));
            }
            line.0.extend(block.0.into_iter().flat_map(|l| l.0));
        }
        Self(vec![line])
    }

    /// The block one tab stop further in.
    pub(super) fn indent(self) -> Self {
        Self(
            self.0
                .into_iter()
                .map(|mut line| {
                    line.0.insert(0, Seg::Tab);
                    line
                })
                .collect(),
        )
    }

    /// `pre` before the first line; the other lines padded to match.
    pub(super) fn prefix(self, pre: &str) -> Self {
        let pad = " ".repeat(pre.chars().count());
        Self(
            self.0
                .into_iter()
                .enumerate()
                .map(|(i, mut line)| {
                    let lead = if i == 0 { pre.to_owned() } else { pad.clone() };
                    line.0.insert(0, Seg::Text(lead));
                    line
                })
                .collect(),
        )
    }

    /// `suffix` at the end of the last line.
    pub(super) fn suffix(mut self, suffix: &str) -> Self {
        if let Some(last) = self.0.last_mut() {
            last.0.push(Seg::Text(suffix.to_owned()));
        }
        self
    }

    /// The block as text starting at column zero, with no trailing
    /// newline and no trailing whitespace on any line.
    pub(super) fn render(&self) -> String {
        let mut out = String::new();
        for (i, line) in self.0.iter().enumerate() {
            if i > 0 {
                out.push('\n');
            }
            line.render(&mut out);
        }
        out
    }
}
