//! The comments a file's `SourceCodeInfo` records, by descriptor path, as
//! the documentation of what they precede or follow (design §3).
//!
//! An element's comment is its leading comment, then its trailing one as a
//! paragraph of its own; detached comments, those a blank line separates
//! from the element, are left out, as protoc-gen-go and protoc's Java
//! generator leave them out. Each line loses the one space that follows
//! `//` by convention and any trailing whitespace; blank lines stay, as
//! paragraph breaks. The text is otherwise as written: what it means as
//! Markdown is the printer's to settle.

use std::collections::HashMap;

use prost_types::FileDescriptorProto;

/// The comments of one file, by descriptor path.
#[derive(Clone, Debug, Default)]
pub struct Comments {
    by_path: HashMap<Vec<i32>, Option<String>>,
}

impl Comments {
    /// Indexes the comments in the `SourceCodeInfo` of `file`; empty when
    /// the compiler was not asked for source info. Where a path has
    /// several locations, the first wins.
    pub fn new(file: &FileDescriptorProto) -> Self {
        let mut by_path = HashMap::new();
        for location in file.source_code_info.iter().flat_map(|info| &info.location) {
            by_path.entry(location.path.clone()).or_insert_with(|| {
                comment(
                    location.leading_comments.as_deref(),
                    location.trailing_comments.as_deref(),
                )
            });
        }
        Comments { by_path }
    }

    /// The comment of the element at `path`, if it has one.
    pub fn get(&self, path: &[i32]) -> Option<&str> {
        self.by_path.get(path)?.as_deref()
    }
}

/// An element's comment from its leading and trailing comments as
/// `SourceCodeInfo` records them, each cleaned by [`clean`], the trailing
/// one a paragraph after the leading one; `None` when neither holds
/// anything but whitespace.
pub fn comment(leading: Option<&str>, trailing: Option<&str>) -> Option<String> {
    let parts: Vec<String> = [leading, trailing]
        .into_iter()
        .flatten()
        .filter_map(clean)
        .collect();
    (!parts.is_empty()).then(|| parts.join("\n\n"))
}

/// One comment as written, without its markers: each line without the
/// one space that follows `//` and without trailing whitespace, and the
/// blank lines at either end dropped; `None` when nothing is left.
pub fn clean(text: &str) -> Option<String> {
    let lines: Vec<&str> = text
        .lines()
        .map(|line| line.strip_prefix(' ').unwrap_or(line).trim_end())
        .collect();
    let first = lines.iter().position(|line| !line.is_empty())?;
    let last = lines.iter().rposition(|line| !line.is_empty())?;
    Some(lines[first..=last].join("\n"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cleaning_drops_one_space_and_the_trailing_whitespace() {
        assert_eq!(
            clean(" A note.\n   Indented.  \n\n Next paragraph.\t\n").as_deref(),
            Some("A note.\n  Indented.\n\nNext paragraph.")
        );
        assert_eq!(clean("tight\n").as_deref(), Some("tight"));
        assert_eq!(clean("\n \n  x\n\n").as_deref(), Some(" x"));
        assert_eq!(clean(" \n\t\n"), None);
        assert_eq!(clean(""), None);
    }

    #[test]
    fn the_trailing_comment_follows_as_a_paragraph() {
        assert_eq!(
            comment(Some(" Lead.\n"), Some(" Trail.\n")).as_deref(),
            Some("Lead.\n\nTrail.")
        );
        assert_eq!(comment(None, Some(" Trail.\n")).as_deref(), Some("Trail."));
        assert_eq!(
            comment(Some(" \n"), Some(" Trail.")).as_deref(),
            Some("Trail.")
        );
        assert_eq!(comment(Some("  \n"), None), None);
        assert_eq!(comment(None, None), None);
    }

    #[test]
    fn the_index_keeps_leading_and_trailing_but_not_detached() {
        use prost_types::SourceCodeInfo;
        use prost_types::source_code_info::Location;
        let location = |path: Vec<i32>, leading: Option<&str>, trailing: Option<&str>| Location {
            path,
            span: vec![0, 0, 1],
            leading_comments: leading.map(str::to_owned),
            trailing_comments: trailing.map(str::to_owned),
            leading_detached_comments: vec![" Detached.\n".to_owned()],
        };
        let file = FileDescriptorProto {
            source_code_info: Some(SourceCodeInfo {
                location: vec![
                    location(vec![4, 0], Some(" A message.\n"), None),
                    location(vec![4, 0], Some(" Recorded twice.\n"), None),
                    location(vec![4, 0, 2, 0], None, Some(" A field.\n")),
                    location(vec![4, 1], None, None),
                    location(vec![4, 1], Some(" Too late.\n"), None),
                ],
            }),
            ..FileDescriptorProto::default()
        };
        let comments = Comments::new(&file);
        assert_eq!(comments.get(&[4, 0]), Some("A message."));
        assert_eq!(comments.get(&[4, 0, 2, 0]), Some("A field."));
        assert_eq!(comments.get(&[4, 1]), None);
        assert_eq!(comments.get(&[5]), None);
    }
}
