//! Checking the rename map (design §3.7) before any name is derived: an
//! entry that names nothing generated, names an enum value alias, or
//! gives a name its element cannot take is reported, with the nearest
//! element it could have meant, and the others are kept for the naming
//! that follows. What a proto full name resolves to, and which names an
//! element accepts, is `ir/rename.rs`'s.

use std::collections::BTreeMap;

use prost_reflect::{DescriptorPool, FileDescriptor};

use super::Builder;
use crate::diagnostics::{Problem, closest};
use crate::ir::rename;

impl Builder {
    /// Checks every entry of `renames` against what it names among the
    /// packages of `by_package`, reporting those that name nothing
    /// generated or give a name it cannot take, and keeps the rest.
    pub(super) fn check_renames(
        &mut self,
        pool: &DescriptorPool,
        renames: &BTreeMap<String, String>,
        by_package: &BTreeMap<String, Vec<FileDescriptor>>,
    ) {
        for (proto, elm) in renames {
            let target = match rename::resolve_prefix(pool, proto) {
                Some((name, target))
                    if name == *proto && by_package.contains_key(&target.package) =>
                {
                    target
                }
                found => {
                    let problem = self.unknown_rename(pool, proto, found, by_package);
                    self.diagnostics.push(problem);
                    continue;
                }
            };
            let what = target.role.what();
            let Some((becomes, rule)) = target.role.rule() else {
                let site = self.site(&target.file, &target.path, format!("{what} here"));
                self.diagnostics.push(Problem::rename_alias(proto, site));
                continue;
            };
            if target.role.accepts(elm) {
                self.renames.insert(proto.clone(), elm.clone());
            } else {
                let site = self.site(&target.file, &target.path, format!("{what} here"));
                self.diagnostics.push(Problem::invalid_rename(
                    proto, elm, what, becomes, rule, site,
                ));
            }
        }
    }

    /// The problem with the rename of `proto`, which names nothing
    /// generated: `found` is the longest prefix of it that names an
    /// element, if any ([`rename::resolve_prefix`]). The problem names
    /// that element and what it lacks, or that its package is not
    /// generated, or, with no element, the generated packages.
    fn unknown_rename(
        &mut self,
        pool: &DescriptorPool,
        proto: &str,
        found: Option<(String, rename::Target)>,
        by_package: &BTreeMap<String, Vec<FileDescriptor>>,
    ) -> Problem {
        let Some((element, target)) = found else {
            // The suggestion swaps the path's leading segments for the
            // generated package they most nearly spell.
            let segments: Vec<&str> = proto.split('.').collect();
            let candidates: Vec<String> = by_package
                .keys()
                .filter_map(|package| {
                    let rest = segments.get(package.split('.').count()..)?;
                    Some([package.as_str()].into_iter().chain(rest.iter().copied()))
                })
                .map(|parts| parts.collect::<Vec<_>>().join("."))
                .collect();
            let suggestion = closest(proto, candidates.iter().map(String::as_str));
            let packages: Vec<String> = by_package.keys().cloned().collect();
            return Problem::unknown_rename(proto, &packages, suggestion.as_deref());
        };
        let what = target.role.what();
        let Some(files) = by_package.get(&target.package) else {
            return Problem::rename_not_generated(
                proto,
                &element,
                what,
                &target.package,
                target.file.name(),
            );
        };
        let site = self.site(
            &target.file,
            &target.path,
            format!("the {} here", target.role.noun()),
        );
        let Some(members) = target.role.members() else {
            return Problem::unknown_rename_leaf(proto, &element, what, site);
        };
        let under = &proto[element.len() + 1..];
        let (missing, rest) = under.split_once('.').unwrap_or((under, ""));
        let names = rename::names(files);
        let children = names.iter().filter_map(|name| {
            name.strip_prefix(element.as_str())?
                .strip_prefix('.')
                .filter(|child| !child.contains('.'))
        });
        // The member most nearly spelled, with the rest of the path kept
        // when that then names a generated element.
        let suggestion = closest(missing, children).map(|child| {
            let member = format!("{element}.{child}");
            let whole = format!("{member}.{rest}");
            let names_generated = !rest.is_empty()
                && rename::resolve(pool, &whole)
                    .is_some_and(|target| by_package.contains_key(&target.package));
            if names_generated { whole } else { member }
        });
        Problem::unknown_rename_member(
            proto,
            &element,
            what,
            members,
            missing,
            suggestion.as_deref(),
            site,
        )
    }
}
