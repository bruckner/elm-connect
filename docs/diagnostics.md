# Diagnostics

Every problem elm-connect reports carries a code, such as
`naming::type_collision`, printed above its message by both the CLI and
the protoc plugin. This file lists every code.

Codes are additive within a major version (design §8.3): codes are added,
and none is removed or changes meaning. A diagnostic's message, help text
and rendering are not a contract, and may change in any release.

Each code is an error, which fails the run, unless the table says
otherwise. The escape is what gets past it: an option, given as the CLI's
flag / the plugin's parameter, or an edit to the protos. Where a code's
rendered output is not pinned by a conformance case (`conformance/cases`,
which feeds the generator `input/` protos and an `options.txt`
parameter), the row says which test covers it instead.

| Code | What it reports | Escape |
|---|---|---|
| **`input::`** | **What the generator was handed: the files and their syntax.** | |
| `input::unknown_file` | A file asked for is not among the compiled files. Only a caller of the library can ask for one: the CLI and protoc request what they compiled. Not in the corpus, which requests every file it compiles: `tests/ir/build.rs` and the plugin's tests cover it. | Ask for a file the compiler was given; check its name against the include paths. |
| `input::not_proto3` | A file to generate declares `syntax = "proto2"` (or no syntax, which is proto2). | `syntax = "proto3";` in the file. |
| `input::editions` | A file declares an edition (`edition = "2023";`). Not in the corpus, whose compiler cannot parse an editions file: `crates/elm-connect/tests/compile_errors.rs` and the plugin's tests cover it. | `syntax = "proto3";` in place of the edition, if the file uses nothing beyond proto3. |
| `input::file_name` | A file name holds a newline or another control character, which would break the generated header comment. Not in the corpus, which cannot hold such a file: `tests/ir/build.rs` covers it. | Rename the file. |
| **`options::`** | **The options: the CLI's flags or the plugin's parameter.** | |
| `options::unknown_option` | The plugin parameter names an option that does not exist, gives one a value it does not take, or holds a pair without `=`. The CLI's argument parser reports the same mistakes in its flags itself. | Fix the key or value; the README's Options table lists them. |
| `options::duplicate_option` | An option other than `rename` is given twice, or `rename` renames one proto element twice. | Give it once. |
| `options::invalid_rename` | A `rename` is not `<proto full name>:<Elm name>`, renames an enum value alias, or gives a name the element it renames cannot take (a type's must be a type name, a field's a record field name, and so on). | `--rename notes.v1.Note:Memo` / `rename=notes.v1.Note:Memo`, with an Elm name of the right form. |
| `options::unknown_rename` | A `rename` names nothing in the generated packages. | Name the element by its proto full name, as declared: `notes.v1.Note.page_count`, not `pageCount`. |
| `options::invalid_module_prefix` | `module_prefix` is not dot-separated Elm module segments. | `--module-prefix Api.Notes` / `module_prefix=Api.Notes`. |
| **`naming::`** | **An Elm name that cannot be formed, or that collides with another.** | |
| `naming::invalid_module` | A package segment does not start with a letter, so it has no Elm module name, or a file to generate has no package. | `--rename <package>:<Elm module>` / `rename=<package>:<Elm module>`, or rename the package. A file without a package has no rename; add a package. |
| `naming::invalid_type` | A message or enum has no valid Elm type name. | `--rename <proto full name>:<Elm name>` / `rename=<proto full name>:<Elm name>`, or rename it in the proto. |
| `naming::invalid_field` | A field or oneof has no valid Elm record field name, or a oneof member's descriptor value has no valid Elm value name: the name is only underscores, or has a digit before its first letter (`_1x`). Leading capitals and underscores are converted, not refused (`Label` → `label`). | `--rename` / `rename=` the field or oneof, or rename it in the proto. A oneof member's descriptor value follows its proto name, not its rename: rename it in the proto. |
| `naming::invalid_method` | A method has no valid Elm value name: the name is only underscores, or has a digit before its first letter. Leading capitals and underscores are converted, not refused (`HTTPGet` → `httpGet`). | `--rename` / `rename=` the method, or rename it in the proto. |
| `naming::invalid_service` | A service has no valid Elm module name. | `--rename` / `rename=` the service, or rename it in the proto. |
| `naming::field_collision` | Two fields, or a field and a oneof, of a message become the same Elm record field. | `--rename` / `rename=` one of them, or rename it in the proto. |
| `naming::type_collision` | Two messages, enums or oneofs of a package become the same Elm type. Two messages also share their record constructor's name, which this one problem reports. | `--rename` / `rename=` one of them, or rename it in the proto. |
| `naming::constructor_collision` | Two enum values, oneof cases or message record constructors of a package become the same Elm constructor, where their types do not also collide: an enum value `STATUS_ACTIVE` beside a message `StatusActive`. | `--rename` / `rename=` one of them, or rename it in the proto. |
| `naming::value_collision` | Two values of one generated module meet: two methods' calls, a call and another method's descriptor, two fields' descriptor values, or a method or field renamed to `elmConnectVersion_`, which every module defines. | `--rename` / `rename=` one of them, or rename it in the proto. |
| `naming::module_collision` | Two generated modules (a package's, a service's, or a message's or enum's descriptor module) get the same Elm module name, or names that differ only in case. | `--rename` / `rename=` one of them, or rename it in the proto. |
| `naming::reserved_name` | A generated type or constructor takes a name the module also uses unqualified for one of elm/core's or the runtime's (`String`, `Maybe`, `Nothing`). | `--rename` / `rename=` it. |
| `naming::reserved_module` | A generated module takes the name of a module of the runtime package or of a package it depends on (`Time`, `Json.Decode`, `Proto.Json`). | `--rename` / `rename=` it, or `--module-prefix Api` / `module_prefix=Api` to move every module. |
| `naming::runtime_namespace` | A warning, beside a successful run: generated modules are named `Rpc` or `Proto` or sit inside them (`Rpc.V1`, `Proto.Notes`, or any module under `module_prefix=Proto`), the runtime's namespaces, where it may add modules in any release. One per run, listing the modules. | `--module-prefix Api` / `module_prefix=Api`, or `--rename` / `rename=` the packages. |
| `naming::shadowing_module` | A warning, beside a successful run: a generated module takes the name of a module of elm/html, elm/browser, elm/url, elm/svg, elm/file, elm/random, elm/regex, elm/parser or elm/virtual-dom (`Html`, `Url.Parser`). The generated code compiles, but an application depending on that package cannot import the module. One per module. | `--rename` / `rename=` it, or `--module-prefix Api` / `module_prefix=Api`. |
| **`types::`** | **A proto type with no Elm form.** | |
| `types::unsupported_well_known` | A field, request or response uses a `google.protobuf` type elm-connect has no mapping for, such as `Api` or `Type`. | None: use a supported well-known type or a message of your own. |
| **`services::`** | **A method the generator refuses, or leaves out, as a method.** | |
| `services::streaming` | A method streams requests, responses or both. An error; a warning, beside a successful run, under `streaming=skip`, which leaves the method out. | `--streaming skip` / `streaming=skip`. |
| `services::unbound_method` | A method has no `google.api.http` rule, under `unbound_methods=error`. | Add a rule, or `--unbound-methods implicit` / `unbound_methods=implicit` (the default) if the server serves the implicit route. |
| **`route::`** | **A `google.api.http` rule that does not resolve.** | |
| `route::rule` | A rule has no path, a `custom` kind that is not an HTTP method a browser sends, or additional bindings nested in an additional binding. | Fix the rule. |
| `route::template` | A path template does not parse, or has a wildcard outside a variable. | Fix the template. |
| `route::path_field` | A path variable names no non-repeated scalar, enum or well-known field with a one-value JSON form (`Timestamp`, `Duration`, `FieldMask`, a wrapper) of the request, runs through a well-known type (`{at.seconds}`), or names a field twice. | Fix the variable's field path. |
| `route::body_field` | `body` names no top-level singular message field of the request. | `body: "*"`, a message field's name, or no `body`. |
| `route::response_body` | `response_body` names no top-level field of the response. | A field of the response, or no `response_body`. |
| `route::query_field` | A request field that would be a query parameter has no query form, such as a message that is not a well-known type with a string form. | Send the field in the body (`body: "*"`, or a body field holding it), or move it out of the request. |
| **`generate::`** | **The set of packages to generate, and the graph between them.** | |
| `generate::not_generated` | A generated package refers to a type of a package that is not generated. | `--include-imports` on the CLI; with protoc, name the file on the command line; with buf, `buf generate --include-imports`. |
| `generate::import_cycle` | Generated packages refer to each other in a cycle, which Elm modules cannot. | Move the types that refer to each other into one package. |
