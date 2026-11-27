//! Claiming the generated modules' names: each package's, each
//! service's, and each message's and enum's descriptor module. Unlike
//! the names claimed within a package, a message or a service, these are
//! claimed across the whole build, and a module name can fail in more
//! ways than by clashing: on a file system (a segment Windows reserves, a
//! name that differs from another only in case), or against the modules
//! of the runtime, its dependencies and an application's `elm/*`
//! packages.

use super::{Builder, Clash, Origin};
use crate::diagnostics::{Problem, Site};
use crate::ir::ModuleName;
use crate::naming;

impl Builder {
    /// Claims `module` for `origin`, the proto element `proto`: reported
    /// when a segment of it is a file name Windows reserves, when it is a
    /// module the runtime or a package it depends on already has, when
    /// another generated module has it, or when another's name
    /// differs from it only in case, since its file is then the same file
    /// on a file system that ignores case. A module in the runtime's
    /// namespaces is noted for their warning, and one an application's
    /// elm/* package has is warned of.
    pub(super) fn claim_module(&mut self, module: &ModuleName, origin: Origin, proto: &str) {
        let name = module.to_string();
        let escapes = format!(
            "{} or {}",
            self.spelling.rename(proto),
            self.spelling.module_prefix()
        );
        if let Some(segment) = naming::windows_device_segment(&name) {
            // A type's or service's module inside a package module that
            // was reported for its own segment is that problem, not another.
            let parent = name.rsplit_once('.').map(|(parent, _)| parent);
            if parent.is_some_and(|parent| self.device_modules.contains(parent)) {
                return;
            }
            self.device_modules.insert(name.clone());
            let site = Site {
                label: format!("{} becomes `{name}`", origin.what),
                ..origin.site
            };
            self.diagnostics.push(Problem::windows_device_module(
                &origin.what,
                &name,
                segment,
                &self.spelling.rename(proto),
                site,
            ));
            return;
        }
        if let Some(owner) = naming::reserved_module(&name) {
            let site = Site {
                label: format!("{} becomes `{name}`", origin.what),
                ..origin.site
            };
            self.diagnostics.push(Problem::reserved_module(
                &origin.what,
                &name,
                owner,
                &escapes,
                site,
            ));
            return;
        }
        if naming::in_runtime_namespace(&name) {
            self.runtime_namespace.insert(name.clone());
        }
        if let Some(owner) = naming::shadowed_module(&name) {
            let site = Site {
                label: format!("{} becomes `{name}`", origin.what),
                ..origin.site.clone()
            };
            self.diagnostics.push(Problem::shadowing_module(
                &origin.what,
                &name,
                owner,
                &escapes,
                site,
            ));
        }
        let folded = name.to_lowercase();
        let other = self
            .module_cases
            .get(&folded)
            .filter(|(other, _)| *other != name)
            .cloned();
        if let Some((other, first)) = other {
            let second = Site {
                label: format!("and {} becomes `{name}`", origin.what),
                ..origin.site.clone()
            };
            self.diagnostics.push(Problem::module_case_collision(
                &other,
                &name,
                &self.spelling.rename(proto),
                (first, second),
            ));
        }
        let site = Site {
            label: format!("{} becomes `{name}`", origin.what),
            ..origin.site.clone()
        };
        self.module_cases
            .entry(folded)
            .or_insert((name.clone(), site));
        if let Some(Clash {
            first,
            second,
            rename,
            renamed,
        }) = self.module_names.claim(&name, origin)
        {
            self.diagnostics.push(Problem::module_collision(
                &name,
                first,
                second,
                &self.rename_of(rename.as_deref()),
                self.renamed_by(renamed.as_ref()).as_deref(),
            ));
        }
    }

    /// Claims the descriptor module of the type `full_name`, named `name`
    /// in its package's module, for `origin`. A type whose name another
    /// type of the package has was reported already, and claims nothing.
    pub(super) fn claim_descriptor_module(&mut self, full_name: &str, name: &str, origin: Origin) {
        let Some(package) = self.types.get(full_name).map(|ty| ty.module.clone()) else {
            return;
        };
        let module = naming::descriptor_module(&package, name);
        self.claim_module(&module, origin, full_name);
    }
}
