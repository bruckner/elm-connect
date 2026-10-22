# Decisions

The questions elm-connect has settled, by topic, each with its date:
what was decided, what else was considered, why, and where the design
states the result. [design.md](design.md) says how the system works;
this page says why it works that way. What may come later is in
[roadmap.md](roadmap.md).

## The project

### The name

*2026-10-20; outreach pending, 2026-10-21.*

The package keeps the name `elm-connect`, with a line in the README's
Trademarks section saying that it is an independent project, not
affiliated with or endorsed by the Connect project, the CNCF or The
Linux Foundation, and that the name says which protocol the generated
clients speak. The alternatives were a name without "connect", or
asking to become an official Connect implementation. The maintainers
of Connect and The Linux Foundation are to be asked before 1.0, once
these docs are accurate, and the name is decided with their answer: a
rename after publishing is a different package on the index, so it is
cheapest now. Where: the README.

### No package split

*2026-10-20; revisited 2026-10-21.*

One Elm package holds both the codecs and descriptors (`Proto.*`) and
the calls (`Rpc.*`). Considered: a codec package and a call package,
or a third package of prebuilt googleapis types. A split costs a second
repository and release train, makes public the internal modules `Rpc`
reads (`Proto.Internal.Binding`, `Proto.Internal.Any`), and gives
users two installs that must agree; it buys no bundle size, since Elm's
dead-code elimination already drops the `Rpc` side from a program that
only encodes and decodes. Splitting Connect from transcoding was
weighed too: the transcode-only code is about a tenth of the call
layer, and a split would first force `Rpc.Transport` open. What is kept
instead is a rule: no `Proto` module imports an `Rpc` one, and `Rpc`
reads no `Proto.Internal` module beyond those two, so a split stays
possible. It would be a major (modules leave the package) and is
revisited only for a transport whose runtime is mostly its own. Where:
design §3.1.

### The design as a specification

*2026-10-22.*

The design says what the system does, in the present tense; the
history and the alternatives are on this page. Until then its headings
and paragraphs carried status markers, *Decided* with the date a point
was settled or reshaped, and §5 and §6 were "Decided unless marked",
with nothing in them marked otherwise. The dates are kept in the
entries here. Where: the design's opening paragraph.

## Generated types

### 64-bit integers and bytes as `String`

*2026-10-19.*

By default the 64-bit integer kinds are `String`, the exact decimal,
and `bytes` is `String`, the base64 text as received. `int64=int`,
`jstype` and `bytes=bytes` choose `Int` or `Bytes`, and `Proto.Int64`
and `Proto.Bytes` convert at the edge. Rejected: an opaque
`Proto.Int64.Int64`, as protoc-gen-elm has, because a value a program
mostly passes through or displays (an ID, a revision, a count) gains
nothing from a wrapper it must unwrap to show or compare; and `Bytes`
by default, because Elm's `==` does not look inside a `Bytes` value, so
records holding one compare equal when they differ. The cost accepted:
an `int64` field and a `string` field have the same Elm type. Where:
design §3.4.

### Record fields in declaration order

*2026-10-19.*

A message's record lists its fields in the order the `.proto` file
writes them, a oneof's field where its first member is declared, and
the defaults, descriptors, encoders and decoders follow that order. The
record's constructor is positional, so the order is API. Field-number
order was considered: it survives a cosmetic reordering of the file.
Rejected, since the record should read beside the proto in its
author's grouping, peer generators use file order, and a new field
changes the positional constructor under either order. Where: design
§3.2, §3.6, §3.9.

### `google.protobuf.Value` fields as `Maybe`

*2026-10-19.*

A singular `Value` field is `Maybe Json.Encode.Value`: a missing key is
`Nothing`, and any JSON under the key, `null` included, is `Just` it.
`null` is one of `Value`'s values, which protojson reads as set, so the
alternative, a bare `Json.Encode.Value` that read a missing key as
`null` and always wrote the field, made a client that never touched it
send `null` and the server see it set. Repeated, as a map value and as
a oneof member it stays a bare value. Where: design §3.5.

### Unrecognised enum values: an option, never the default

*2026-10-21.*

An enum constructor holding a number the client does not know,
`<Enum>Unrecognized Int`, will come as an option, and later as a
per-enum proto option too; it will never be the default. As the
default it would add a branch to every `case` on every enum, and adding
it after 1.0 would break every such `case`; behind an option the
default output stays as it is. Today an unknown number reads as the
zero value, and an unknown name fails or, under `enum_unknown=zero`,
reads as the zero value. Where: design §3.3; the roadmap.

### Descriptors in a module per type

*2026-10-19.*

What the proto says about a message or enum, its descriptor and one
value per field, lives in a module of the type's own beside the
package's (`Notes.V1.Note` beside `Notes.V1`), and the package module
holds what a program sends and receives. Before, each descriptor was a
value of the package module (`descriptorNote`) with its fields written
inline. Why: a field's descriptor becomes a value a program can name
(`Notes.V1.Note.title`), which routes and UI code build on. The cost is
a module per type, measured: programs pay only for what they reach.
Nesting the modules (`Notes.V1.Outer.Inner`) was rejected, since a
parent referring to its nested type would be an import cycle. Where:
design §3.1, §3.9.

### Doc comments in elm-format's form

*2026-10-20.*

Generated documentation carries each element's proto comment, and
elm-format re-renders a doc comment's Markdown. Generated code is held
to elm-format's form (`elm-format --validate` on the whole corpus), so
the generator ports the Markdown parser and printer elm-format 0.8.8
vendors and repeats them until the text stops changing, keeping text
elm-format would lose in a form it leaves alone. The alternatives were
to give up that guarantee for doc comments, so that formatting a
generated tree would rewrite it and `elm-connect check` would report
drift, or to run elm-format while generating, which the one-binary
install does not allow. Where: design §3.1.

## Naming

### Naming refusals and rules (pending the operator's review of 2026-10-21)

*Decision: pending.*

The rules as implemented today (`crates/elm-connect-gen/src/naming.rs`):

- A package becomes a module, each segment PascalCase
  (`foo_bar.v2beta1` → `FooBar.V2beta1`). A message or enum becomes a
  type, PascalCase per nesting level joined (`Outer.Inner` →
  `OuterInner`), its capitals kept.
- A field, oneof, method or oneof member's descriptor value drops each
  `_` and uppercases the next letter, then lowercases the leading
  capital run but for its last letter when a lowercase letter follows
  (`URLPath` → `urlPath`, `ID` → `id`, `IDs` → `iDs`). One of Elm's
  fourteen reserved words gains a trailing `_` (`type_`).
- An enum value's constructor is the enum's Elm name and the value
  with the enum's own `UPPER_SNAKE` prefix stripped (`STATUS_ACTIVE` →
  `StatusActive`). A oneof's type is the message's name and the
  oneof's, its constructors that and each member's, and `…Unset`; a
  recursive message's wrapper is the name and `_` (`Node_`).
- A package module's values are a prefix and a type name (`encode`,
  `decode`, `default`, `message`, `enum`), `registry` and
  `elmConnectVersion_`; a service is a module of its package's, its
  methods' values named as fields are, each with `descriptor` and the
  name. `module_prefix` applies to every generated module and never to
  the runtime's; a `rename` is taken as written, checked against its
  role.

The refusals, each a diagnostic with `rename` (and for modules
`module_prefix`) as its escape unless said otherwise: a name with no
Elm form, one starting with a digit or only underscores
(`naming::invalid_field`, `invalid_method`, `invalid_type`,
`invalid_module`, `invalid_service`); a file with no package (no
escape); two names that meet after conversion
(`naming::field_collision`, `type_collision`,
`constructor_collision`, `value_collision`, `module_collision`, the
last also for module names that differ only in case, on every
operating system); a generated module named like the runtime's or a
dependency's (`naming::reserved_module`), and a type or constructor
named like one its module uses unqualified (`naming::reserved_name`). Two field names
that differ only in case or underscores (`aB` and `ab`) are refused
before generation by the CLI's and the plugin's descriptor reader,
with no code and no escape. Where: design §3.7, §3.8.

## The runtime's API

### Calls are data, with pure halves

*2026-10-13.*

A generated method, applied to a request, gives an `Rpc.Call`: the
method's codecs, its descriptor and every HTTP binding, as data; a
config, also data, says where and how; `Rpc` sends one with the other.
`Rpc.request` and `Rpc.response` are the pure halves, building the
HTTP request a call stands for and reading an answer without sending
anything. The first shape was a `Connect.Method` per method and a
`Transcode.Call` per binding, chosen by a `transports=` option, which
put route presence in the type and named additional bindings by
number: a method without a rule could not be passed to the transcoding
transport at all, so every helper an application wrote around calls
split in two, guarding against a server configuration the generator
cannot see; `unbound_methods=error` keeps that guard as an option. A
call carrying every binding has nothing to fuse,
`Rpc.Call.viaBinding n` picks a binding without a name for it, and a
method without a rule takes the implicit route. The same shape is
connect-es's in its second version. Where: design §2, §4, §5.2.

### Config is data, with no interceptors

*2026-10-13.*

`Rpc.Config` is a record with no function in it, so it can be
compared, kept in a model, passed through `Html.Lazy`, printed, and
built per call with record syntax; Elm 0.19 throws at run time on `==`
over functions. Rejected: interceptors, a token provider and a logger
in the config. Each use maps onto something else: onto data (headers,
timeout, credentials, retry), onto update-time handling (logging from
the `Rpc.Trace`, refreshing a token in the application's shell before
it builds the config), or onto the pure halves (rewriting a request
between `Rpc.request` and `Rpc.taskFromRequest`). If hooks are wanted
after all, an opaque `Rpc.Client` can be added beside `Rpc.task`
without breaking it. Where: design §5.1; the pattern in
[calling.md](calling.md).

### One module per opaque type, plain names

*2026-10-16.*

Every type generated code builds, and every type a config holds or the
runtime gives, is opaque: built by functions, read by accessors, in a
module of its own named for it (`Proto.Message`, `Rpc.Transport`,
`Rpc.Retry`, `Rpc.Trace`, `Rpc.Body`). A builder is named for what it
builds (`message`, `descriptor`), readers are plain nouns (`name`,
`fields`), and union constructors carry their union's name. Builders
take their arguments positionally. Before, the typed values and
descriptors were record aliases written as literals, and `Transport`
an exposed union: adding a field or a constructor to either would have
been a major, and generated code would have broken on the literal
rather than on the version check. Opaque, a type grows by a new
modifier and accessor, a minor. Where: design §3.1, §3.9, §5.1, §8.3.

### `Rpc` and `Proto` as the top-level names

*2026-10-19.*

The runtime's modules are `Proto.*`, the data, and `Rpc` with `Rpc.*`,
the calling. They were `Connect.*` at first, a product prefix that tied
proto3 JSON to one of the two transports. The cost of short names is
that an application with a module of its own named `Rpc` or
`Proto.Json` cannot import the runtime's; it renames its module, and a
generated module that would take one is refused
(`naming::reserved_module`). An option to move the runtime's modules
under a prefix was deferred: it could only work where the runtime is
vendored rather than installed. Where: design §5.2.

### `Any` in the runtime

*2026-10-13.*

`google.protobuf.Any` is the opaque `Proto.Any.Any`: it packs and
unpacks through the typed values, describes its type through a
registry, and holds a payload that arrived only as binary rather than
failing on it. Error details are `Any` values. Before, a field of
`Any` was a diagnostic, and error details were raw JSON. Where: design
§3.5, §5.4.

### Receive and send limits, with no default

*2026-10-20.*

`Rpc.Transport.withReadMaxBytes` refuses a successful answer longer
than a limit before decoding it, and `withWriteMaxBytes` refuses to
send a request message longer than one; neither has a default, as in
connect-node. connect-go reads at most 4 MiB unless told otherwise, and
connect-web, the browser transport, has no such knob. They are protocol knobs, so they are on
`Rpc.Transport`, not in the frozen `Config`. The failures are two new
reasons, `ResponseTooLarge` and `RequestTooLarge`, added before 1.0
because `Rpc.Error.Reason` freezes then, and kept apart so a caller can
tell a request it must shrink from an answer it chose not to read. A
default limit, connect-go's 4 MiB, was the alternative; the browser has
downloaded the body before the limit applies, so a default would
surprise without saving bandwidth. The knob is kept though no browser
client has one: an Elm program also runs headless under Node, between
connect-web and connect-node, and server streaming will check each
message against the same limit. Where: design §1, §5.1, §5.4.

### `Proto.Field.Behavior` keeps unknown numbers

*2026-10-21.*

`Proto.Field.Behavior`, which mirrors `google.api.FieldBehavior`,
gains `BehaviorUnknown Int`: a field annotated with a behaviour this
release does not name carries its number instead of losing it. Google
has added values to that enum three times (2020, 2021, 2023), and
`Behavior` is a frozen union, so without the constructor each addition
would wait for a major, the generator dropping it meanwhile. The
alternatives were to keep the union as it is, or to make `Behavior`
opaque with accessors, which was rejected as heavy. Where: design §3.9,
§8.3.

### `Rpc.Error.Source` reserves two constructors

*2026-10-21.*

`Source` says where an error's status was read from. It gains
`GrpcTrailers` and `ConnectEndStream`, which this release never
produces: server streaming reads statuses from gRPC trailers and from
Connect's end-of-stream message, and with the constructors already in
place it can produce them in a minor. The precedent is
`Proto.Field.CardinalityRequired`, shipped for proto2 before proto2 is
read. Where: design §5.4, §8.3.

### Retry waits by its own backoff

*2026-10-16.*

A retry policy does not read a 429 or 503's `Retry-After` header or a
`google.rpc.RetryInfo` detail. Honouring either is a new setting on
the opaque `Rpc.Retry`, so it can come in a minor. Where: design
§5.1 (the policy); the roadmap.

### Streaming's shape

*2026-10-21.*

A design pass on streaming was to come before 1.0, writing the
streaming section against the reshaped runtime and listing where it
would want a 1.0 surface to differ. The versioning assessment settled
it: server streaming is a minor, read through ports with a vanilla-JS
companion that an Elm package cannot ship, in a new `Rpc.Stream` module
beside today's; the one surface it wanted different was `Rpc.Error.Source`,
which now reserves its two constructors (above). Client and
bidirectional streaming are not feasible in browsers. Where: the
roadmap.

## Input and versioning

### Editions and proto2 refused in 1.0

*2026-10-16.*

A proto2 file is `input::not_proto3`, and a file that declares an
edition is `input::editions`, from either binary, before anything is
generated, even where its features would reduce to proto3. protox,
under the CLI, does not parse editions, and the plugin does not claim
editions support, so protoc says the same. Accepting them later turns
an error into output, a minor; the descriptors reserve
`CardinalityRequired` for it. Where: design §1.3.

### One version, in lockstep, and a strict sentinel

*2026-10-16.*

The Elm package and the three crates carry one version number and are
released together under one tag. Every generated module names the
release that generated it (`elmConnectVersion_ = Proto.Version.v0_1`),
and the runtime exposes that value for every minor of its major, so a
runtime older than the generated code fails to compile at a line that
says why. Independent version numbers were the alternative; they would
need a compatibility table and a CI matrix to keep it true. A looser
sentinel, naming the oldest runtime the code could run against, as
protobuf-go's generated code does, is recorded; the strict one means
the gate compiles exactly the pair that ships. Where: design §8.1,
§8.2.

### elm/json 1.1.4 at least

*2026-10-16.*

The runtime requires elm/json 1.1.4, which lists an object's keys
without calling the object's own `hasOwnProperty`, so a JSON key of
that name no longer breaks the decode of a map, a `Struct` or an `Any`
holding it. The alternative was to document the gap under older
versions; raising the floor closes it at the source. Where: design
§3.4.

## Verification

### Envoy through func-e, pinned through mise, in CI

*2026-10-21.*

The live suite runs Envoy's gRPC-JSON transcoder as its third
transcoder, locally and in CI's `live` job. func-e, pinned in
`mise.toml` with its checksums in `mise.lock`, downloads the Envoy
release that `conformance/live/envoy/envoy-version` names and runs it;
CI caches the download on that file. The alternatives were Docker,
which runs Envoy's own builds and can pin an image by digest, but is
not on GitHub's macOS runners and is heavy to run locally, and
Homebrew, which installs whatever Envoy it has that day and runs on
macOS only. func-e takes the same pinned version on Linux and macOS
without a daemon, and joins the toolchain the rest of the repository
already installs with mise. The cost accepted: the Envoy binary comes
from Tetrate's archive, checked against the digest in Tetrate's own
index, and the macOS build is Tetrate's, not the Envoy project's. Envoy
stays in CI unless the job's time grows out of proportion. Where:
design §7, docs/envoy.md.
