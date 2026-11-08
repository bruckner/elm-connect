- A service's calls are generated in a module per codec inside its
  module: `Notes.V1.NotesService.Json` (calls `Rpc.Call Rpc.Json`) and
  `Notes.V1.NotesService.Proto` (calls `Rpc.Call Rpc.Proto`). The
  `codec` option says which exist: `json` the first, `proto` the second,
  `both` the two. `Notes.V1.NotesService` keeps the method descriptors
  and the HTTP route functions. The names do not depend on the option,
  so a program picks its wire by the module it imports, and moving a
  package to `codec=both` changes no import. Code importing a service's
  calls imports its `.Json` module instead (docs/migrating.md, "The
  calls module").
- `codec=both` no longer gives calls free in the codec: every generated
  call is in one codec, that of its module.
- `Proto.Method.init`, the builder of a method with both codecs, is
  removed: no generated method has both. A method sent over both wires is
  written as two, with `initJson` and `initProto`.
- `naming::module_collision` covers a service's calls modules: a
  package or module named like `Notes.V1.NotesService.Json` or `.Proto`
  is refused under every `codec` value.
