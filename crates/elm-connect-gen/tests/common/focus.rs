//! Focused cases (`conformance/README.md`, "Focused cases"): a case whose
//! `focus.txt` names the top-level declarations, or whole modules, it is
//! about pins only those, in one excerpt, `expected/focused.txt`, instead
//! of every module it generates.
//!
//! The excerpt is cut from elm-format's layout by text: every top-level
//! declaration starts at column 0 after a blank line, and lines inside a
//! block comment or a triple-quoted string do not count as starting one.

use std::collections::BTreeMap;
use std::fs;
use std::io::ErrorKind;
use std::path::Path;

/// The optional file in a case, beside `options.txt`, that focuses it.
pub const FOCUS: &str = "focus.txt";
/// The file in a focused case's `expected/` that holds its excerpt.
pub const FOCUSED: &str = "focused.txt";

/// What a focus list keeps of one module.
#[derive(Debug, PartialEq)]
pub enum Keep {
    /// The whole module.
    Module,
    /// These top-level declarations, in this order; `module` is the module
    /// line with the module's documentation comment and `import` the
    /// imports, names no declaration can take.
    Declarations(Vec<String>),
}

/// A parsed `focus.txt`: modules, by path under `expected/`, in the order
/// the list first names them.
pub type Focus = Vec<(String, Keep)>;

/// The focus list of `case`, if it has one, or its problems.
pub fn case_focus(case: &Path) -> Option<Result<Focus, String>> {
    let path = case.join(FOCUS);
    match fs::read_to_string(&path) {
        Ok(text) => Some(parse_focus(&text).map_err(|problem| format!("{FOCUS}: {problem}"))),
        Err(e) if e.kind() == ErrorKind::NotFound => None,
        Err(e) => panic!("read {}: {e}", path.display()),
    }
}

/// Reads a focus list: one module per line, by its path under `expected/`,
/// alone for the whole module or followed by the names of the
/// declarations to keep. A module may take several lines. `#` starts a
/// comment.
pub fn parse_focus(text: &str) -> Result<Focus, String> {
    let mut focus: Focus = Vec::new();
    for (number, line) in text.lines().enumerate() {
        let line = line.split('#').next().unwrap_or_default();
        let mut words = line.split_whitespace();
        let Some(module) = words.next() else {
            continue;
        };
        let at = format!("line {}", number + 1);
        if !module.ends_with(".elm") {
            return Err(format!(
                "{at}: `{module}` is not a module's path, such as `Notes/V1.elm`"
            ));
        }
        let names: Vec<String> = words.map(str::to_owned).collect();
        let at_module = focus.iter().position(|(path, _)| path == module);
        let kept = match at_module {
            None if names.is_empty() => {
                focus.push((module.to_owned(), Keep::Module));
                continue;
            }
            None => {
                focus.push((module.to_owned(), Keep::Declarations(Vec::new())));
                focus.len() - 1
            }
            Some(index) => index,
        };
        let kept = match (&mut focus[kept].1, names.is_empty()) {
            (Keep::Module, true) => return Err(format!("{at}: {module} is named twice")),
            (Keep::Declarations(kept), false) => kept,
            _ => {
                return Err(format!(
                    "{at}: {module} is kept whole and also by declaration"
                ));
            }
        };
        for name in names {
            if kept.contains(&name) {
                return Err(format!("{at}: `{name}` in {module} is named twice"));
            }
            kept.push(name);
        }
    }
    if focus.is_empty() {
        return Err("names no module".into());
    }
    Ok(focus)
}

/// The top-level pieces of an elm-format-laid-out module, in order: each
/// declaration (its documentation comment, type annotation and
/// definition) under its name, `module` for the module line with its
/// documentation comment, `import` for the imports, and `None` for the
/// rest (the header comment and section comments). Trailing blank lines
/// are dropped.
pub fn split_module(text: &str) -> Vec<(Option<String>, String)> {
    let mut scan = Scan::default();
    // Each piece's lines, and for each line whether it starts outside any
    // comment or string.
    let mut pieces: Vec<Vec<(&str, bool)>> = Vec::new();
    let mut previous_blank = true;
    for line in text.lines() {
        let outside = scan.outside();
        let starts_piece =
            outside && previous_blank && line.starts_with(|c: char| !c.is_whitespace());
        match pieces.last_mut() {
            Some(piece) if !starts_piece => piece.push((line, outside)),
            _ => pieces.push(vec![(line, outside)]),
        }
        scan.line(line);
        previous_blank = line.trim().is_empty();
    }
    let mut out: Vec<(Option<String>, Vec<&str>)> = Vec::new();
    for piece in pieces {
        let name = piece_name(&piece);
        let lines: Vec<&str> = piece.iter().map(|(line, _)| *line).collect();
        // The module's documentation comment follows the module line
        // after a blank line, so it is a piece of its own: join them.
        let is_module_doc = name.is_none() && lines[0].starts_with("{-|");
        match out.last_mut() {
            Some((Some(previous), joined)) if is_module_doc && previous == "module" => {
                joined.extend(lines);
            }
            _ => out.push((name, lines)),
        }
    }
    out.into_iter()
        .map(|(name, mut lines)| {
            while lines.last().is_some_and(|line| line.trim().is_empty()) {
                lines.pop();
            }
            (name, lines.join("\n"))
        })
        .collect()
}

/// The name a piece declares: from its first line outside a comment that
/// is not itself a comment.
fn piece_name(piece: &[(&str, bool)]) -> Option<String> {
    let line = piece
        .iter()
        .filter(|(line, outside)| *outside && !line.trim().is_empty())
        .map(|(line, _)| *line)
        .find(|line| !line.starts_with("{-") && !line.starts_with("--"))?;
    let mut words = line.split_whitespace();
    match words.next()? {
        "module" => Some("module".into()),
        "import" => Some("import".into()),
        "type" => match words.next()? {
            "alias" => words.next().map(str::to_owned),
            name => Some(name.to_owned()),
        },
        "port" => words.next().map(str::to_owned),
        name if name.starts_with(|c: char| c.is_lowercase() || c == '_') => Some(name.to_owned()),
        _ => None,
    }
}

/// Where a scan of Elm source stands at the end of a line: inside how many
/// nested block comments, and whether inside a triple-quoted string. A
/// line comment, a one-line string and a character end with their line.
#[derive(Default)]
struct Scan {
    comments: usize,
    long_string: bool,
}

impl Scan {
    fn outside(&self) -> bool {
        self.comments == 0 && !self.long_string
    }

    fn line(&mut self, line: &str) {
        let bytes = line.as_bytes();
        let mut i = 0;
        while i < bytes.len() {
            let rest = &bytes[i..];
            if self.long_string {
                if rest.starts_with(b"\\") {
                    i += 2;
                } else if rest.starts_with(b"\"\"\"") {
                    self.long_string = false;
                    i += 3;
                } else {
                    i += 1;
                }
            } else if self.comments > 0 {
                if rest.starts_with(b"{-") {
                    self.comments += 1;
                    i += 2;
                } else if rest.starts_with(b"-}") {
                    self.comments -= 1;
                    i += 2;
                } else {
                    i += 1;
                }
            } else if rest.starts_with(b"--") {
                return;
            } else if rest.starts_with(b"{-") {
                self.comments += 1;
                i += 2;
            } else if rest.starts_with(b"\"\"\"") {
                self.long_string = true;
                i += 3;
            } else if rest.starts_with(b"\"") {
                i += 1;
                while i < bytes.len() && bytes[i] != b'"' {
                    i += if bytes[i] == b'\\' { 2 } else { 1 };
                }
                i += 1;
            } else if rest.starts_with(b"'") {
                i += 1;
                while i < bytes.len() && bytes[i] != b'\'' {
                    i += if bytes[i] == b'\\' { 2 } else { 1 };
                }
                i += 1;
            } else {
                i += 1;
            }
        }
    }
}

/// The excerpt `focus` keeps of `files` (path under `expected/` to
/// content), or a problem for each module or declaration it names that
/// `files` does not have.
pub fn excerpt(focus: &Focus, files: &BTreeMap<String, String>) -> Result<String, Vec<String>> {
    let mut out = String::from(
        "-- An excerpt, not a module: what ../focus.txt names of the modules this\n\
         -- case generates. Only it is compared; the modules are compiled and\n\
         -- checked for elm-format's layout whole. `just bless` writes it.\n\
         --\n\
         -- Generated:\n",
    );
    for path in files.keys() {
        out.push_str(&format!("--   {path}\n"));
    }
    let mut problems = Vec::new();
    for (module, keep) in focus {
        let Some(text) = files.get(module) else {
            problems.push(format!(
                "{FOCUS} names {module}, which this case does not generate"
            ));
            continue;
        };
        match keep {
            Keep::Module => {
                out.push_str(&format!("\n\n-- {module}, whole\n\n{text}"));
                if !text.ends_with('\n') {
                    out.push('\n');
                }
            }
            Keep::Declarations(names) => {
                let pieces = split_module(text);
                for name in names {
                    match pieces.iter().find(|(n, _)| n.as_deref() == Some(name)) {
                        Some((_, piece)) => {
                            out.push_str(&format!("\n\n-- {module}: {name}\n\n{piece}\n"));
                        }
                        None => problems.push(format!(
                            "{FOCUS} names `{name}` in {module}, which does not declare it"
                        )),
                    }
                }
            }
        }
    }
    if problems.is_empty() {
        Ok(out)
    } else {
        Err(problems)
    }
}
