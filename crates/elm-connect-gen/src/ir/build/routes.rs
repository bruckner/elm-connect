//! The HTTP routes of each method: its `google.api.http` rule and
//! additional bindings resolved against the request and response
//! (`crate::route`), each problem reported at the part of the rule it is
//! about, and, once every package is built, a warning for each pair of
//! bindings with one HTTP method and path shape. A route names a field
//! by the value of its descriptor in its message's descriptor module.

use std::collections::HashMap;

use prost_reflect::{DescriptorPool, FieldDescriptor, FileDescriptor, MethodDescriptor};

use super::Builder;
use crate::diagnostics::{Problem, Site, Spans, tag};
use crate::ir::{HttpRule, HttpVerb, Package};
use crate::naming;
use crate::route::{self, Route};

impl Builder {
    /// The routes of `rule`, the method's own binding first; `None` after
    /// reporting every problem in them, at the rule's option.
    pub(super) fn routes(
        &mut self,
        file: &FileDescriptor,
        method: &MethodDescriptor,
        rule: &HttpRule,
    ) -> Option<Vec<Route>> {
        let full_name = method.full_name();
        let path = [
            method.path(),
            &[tag::METHOD_OPTIONS, tag::METHOD_OPTIONS_HTTP],
        ]
        .concat();
        let bindings = std::iter::once((rule, false)).chain(
            rule.additional_bindings
                .iter()
                .map(|binding| (binding, true)),
        );
        let mut routes = Vec::new();
        let mut failed = false;
        let name = |field: &FieldDescriptor| self.field_ref(field);
        let mut resolved = Vec::new();
        for (binding, nested) in bindings {
            resolved.push(route::resolve(
                binding,
                &method.input(),
                &method.output(),
                nested,
                &name,
            ));
        }
        for (index, resolved) in resolved.into_iter().enumerate() {
            match resolved {
                Ok(route) => routes.push(route),
                Err(errors) => {
                    failed = true;
                    // No problems: the route named a field without an Elm
                    // name, whose problem is the field's own.
                    self.unnamed_route |= errors.is_empty();
                    let what = match index {
                        0 => format!("The HTTP rule of `{full_name}`"),
                        n => format!("Additional binding {n} of `{full_name}`"),
                    };
                    let binding = match index {
                        0 => rule,
                        n => &rule.additional_bindings[n - 1],
                    };
                    for error in errors {
                        let (label, within) = route_literal(index, binding, &error);
                        let site = Site {
                            within,
                            ..self.site_within(file, &path, label.into())
                        };
                        self.diagnostics.push(Problem::route(&what, &error, site));
                    }
                }
            }
        }
        (!failed).then_some(routes)
    }

    /// A `route::ambiguous_binding` warning for each pair of bindings of
    /// `packages` (built from `pool`) with one HTTP method and one path
    /// shape: the rules, their additional bindings, and the implicit
    /// `POST /<package>.<Service>/<Method>` route of every method, which a
    /// rule can take too. Implicit routes come first, so the second of a
    /// pair, where the warning points, is a binding written in the protos.
    pub(super) fn check_ambiguous_bindings(&mut self, pool: &DescriptorPool, packages: &[Package]) {
        struct Binding {
            /// As the middle of a sentence names it, with its method and
            /// path.
            what: String,
            /// The HTTP method and path shape.
            shape: String,
            /// Where the protos write it, for a written binding.
            at: Option<(FileDescriptor, Vec<i32>, Vec<String>)>,
        }
        let services = || packages.iter().flat_map(|package| &package.services);
        let mut bindings = Vec::new();
        for service in services() {
            for method in &service.methods {
                let path = format!("/{}/{}", service.proto_full_name, method.proto_name);
                bindings.push(Binding {
                    what: format!(
                        "the implicit route of `{}.{}` (`POST {path}`)",
                        service.proto_full_name, method.proto_name
                    ),
                    shape: format!("POST {path}"),
                    at: None,
                });
            }
        }
        for service in services() {
            let descriptor = pool.get_service_by_name(&service.proto_full_name);
            for method in &service.methods {
                let Some(rule) = &method.http else {
                    continue;
                };
                let full_name = format!("{}.{}", service.proto_full_name, method.proto_name);
                let written = std::iter::once(rule).chain(&rule.additional_bindings);
                for (index, (route, binding)) in method.routes.iter().zip(written).enumerate() {
                    let verb = binding.verb.as_str();
                    let what = match index {
                        0 => format!("the HTTP rule of `{full_name}`"),
                        n => format!("additional binding {n} of `{full_name}`"),
                    };
                    let at = descriptor
                        .as_ref()
                        .and_then(|service| {
                            service.methods().find(|m| m.name() == method.proto_name)
                        })
                        .map(|descriptor| {
                            let path = [
                                descriptor.path(),
                                &[tag::METHOD_OPTIONS, tag::METHOD_OPTIONS_HTTP],
                            ]
                            .concat();
                            (descriptor.parent_file(), path, path_within(index, binding))
                        });
                    bindings.push(Binding {
                        what: format!("{what} (`{verb} {}`)", binding.template),
                        shape: format!("{verb} {}", route.shape()),
                        at,
                    });
                }
            }
        }

        let mut by_shape: HashMap<&str, Vec<usize>> = HashMap::new();
        let mut pairs = Vec::new();
        for (second, binding) in bindings.iter().enumerate() {
            let earlier = by_shape.entry(binding.shape.as_str()).or_default();
            pairs.extend(earlier.iter().map(|&first| (first, second)));
            earlier.push(second);
        }
        for (first, second) in pairs {
            let (first, second) = (&bindings[first], &bindings[second]);
            let site = second.at.as_ref().map(|(file, path, within)| Site {
                within: within.clone(),
                ..self.site_within(file, path, "this path".into())
            });
            self.diagnostics.push(Problem::ambiguous_binding(
                &first.what,
                &second.what,
                &second.shape,
                site,
            ));
        }
    }

    /// A field of a generated message as generated code names its
    /// descriptor: its message's descriptor module and its value there
    /// ([`Builder::field_value`]). `None` for a field whose message or
    /// name was reported already.
    fn field_ref(&self, field: &FieldDescriptor) -> Option<route::FieldRef> {
        let message = field.parent_message();
        let ty = self.types.get(message.full_name())?;
        Some(route::FieldRef {
            module: naming::descriptor_module(&ty.module, &ty.name),
            name: self.field_value(field).ok()?,
        })
    }

    /// A site at `path` in `file`, or at the nearest enclosing element the
    /// compiler recorded a span for. Options written as one aggregate
    /// (`option (google.api.http) = { ... }`) are recorded as a whole, not
    /// field by field.
    fn site_within(&mut self, file: &FileDescriptor, path: &[i32], label: String) -> Site {
        let spans = self
            .spans
            .entry(file.name().to_owned())
            .or_insert_with(|| Spans::new(file.file_descriptor_proto()));
        let span = (1..=path.len())
            .rev()
            .find_map(|len| spans.get(&path[..len]));
        Site {
            file: file.name().to_owned(),
            span,
            label,
            within: Vec::new(),
        }
    }
}

/// The label of a problem `error` in the binding `binding` (the rule
/// itself at `index` 0, else its additional binding `index`), and the
/// literals that find what it is about in the rule's text (see
/// [`Site::within`]): the quoted path, `body`, `response_body` or custom
/// kind, or the binding's block.
fn route_literal(
    index: usize,
    binding: &HttpRule,
    error: &route::RouteError,
) -> (&'static str, Vec<String>) {
    use route::RouteError as E;
    let mut within = vec!["additional_bindings".to_owned(); index];
    let label = match error {
        E::NoPattern | E::QueryField { .. } => {
            if index == 0 {
                "in this rule"
            } else {
                "in this binding"
            }
        }
        E::NestedBindings => {
            within.push("additional_bindings".to_owned());
            "nested here"
        }
        E::CustomKind { kind, .. } => {
            within.extend(["kind".to_owned(), quoted(kind)]);
            "this kind"
        }
        E::Syntax { .. }
        | E::UnboundWildcard { .. }
        | E::PathField { .. }
        | E::PathFieldTwice { .. } => {
            within = path_within(index, binding);
            "this path"
        }
        E::BodyField { field, .. } | E::GetBody { body: field, .. } => {
            within.extend(["body".to_owned(), quoted(field)]);
            "this body"
        }
        E::ResponseBodyField { field, .. } => {
            within.extend(["response_body".to_owned(), quoted(field)]);
            "this response body"
        }
    };
    (label, within)
}

/// The literals that find the path of the binding `binding` (the rule
/// itself at `index` 0, else its additional binding `index`) in the
/// rule's text (see [`Site::within`]).
fn path_within(index: usize, binding: &HttpRule) -> Vec<String> {
    let key = match &binding.verb {
        HttpVerb::Get => "get",
        HttpVerb::Put => "put",
        HttpVerb::Post => "post",
        HttpVerb::Delete => "delete",
        HttpVerb::Patch => "patch",
        HttpVerb::Custom(_) => "path",
    };
    let mut within = vec!["additional_bindings".to_owned(); index];
    within.extend([key.to_owned(), quoted(&binding.template)]);
    within
}

/// `text` as the text format writes a string, in double quotes, so that a
/// value with escapes (`"GET\r\n"`) is found as written.
fn quoted(text: &str) -> String {
    let mut out = String::from("\"");
    for c in text.chars() {
        match c {
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            c if c.is_control() => out.push_str(&format!("\\{:03o}", u32::from(c))),
            c => out.push(c),
        }
    }
    out.push('"');
    out
}
