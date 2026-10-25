# Spike: generated route functions (plan, 2026-10-24, awaiting operator approval)

## Question
Does moving HTTP transcoding from the runtime's binding interpreter to generated per-binding
functions pay for itself in bundle size and per-call work, and who loses if the data-only
HTTP bindings and the interpreter are dropped?

## Today
- Generated: `descriptorX = Proto.Method.descriptor service name idempotency in out [bindings…]`
  (~1.8 KB unminified per method, ~1 KB of it binding data); `x = Rpc.call (Proto.Method.method
  encode decode descriptorX)`.
- Runtime: `Rpc.Internal.Wire.request` encodes the request to JSON, then `Rpc.Internal.Route`
  interprets the binding over that JSON (lookup by path, scalar sniffing, percent-encoding,
  default-dropping for query, body = field or whole-minus-path-vars by re-encoding). Since #117,
  `unsendable` refuses an empty/mismatched path value (`InvalidPathValue`).
- Interpreter + `Proto.Http` + `Proto.Internal.Binding` ≈ 12 KB of the runtime's 95 KB unminified.

## Shape to prototype
- `Rpc.Route` (new public record): `{ method : String, path : String, query : List (String, String), body : Maybe Json.Encode.Value }`, path already percent-encoded, no leading slash.
- A route function per binding: `routeX : Req -> Result Rpc.PathError Rpc.Route` (the E6 check moves into typed code: non-empty, segment match). Typed field access: no JSON detour for path/query; body = encoder of the field, or the message encoder minus path-bound keys (first cut may reuse the runtime's `remove`; note the cost).
- `Proto.Method.methodWith : { encode, decode, descriptor : Descriptor, routes : List (req -> Result PathError Route) } -> Method req res` (additive sibling of `method`). `Descriptor` keeps identity only (service, name, idempotency, input, output); the binding data moves to a separate generated value `bindingsX : List Proto.Http.Binding` referenced by nothing the call needs → dead code unless an application imports it.
- Interpreter kept, DCE-able: `Proto.Http.interpret : Binding -> (Json.Encode.Value -> Result PathError Route)` wraps today's Route code; `Proto.Method.method` (the old form) builds `routes` with it from the descriptor's bindings, so hand-written descriptors and old generated code keep working, and an application using only `methodWith` carries no interpreter.
- `Wire.transcodeRequest` takes the route from `routes` at the call's `viaBinding` index; Connect transport unchanged.
- `Rpc.request` keeps its type; `Rpc.Call.descriptor`/`bindings` surface changes are listed as API deltas in the report, not decided.

## Work
1. Baseline: optimized+minified+gzip sizes of examples/notes/elm, conformance/live client, and tests/Routes (routes.proto, many bindings) with `attr.py`/`fn.py`-style attribution (scripts in the review scratch, copy into the spike worktree's `spike/` dir, not committed to main).
2. Runtime: `Rpc.Route`, `PathError`, `methodWith`, `Proto.Http.interpret`, Wire switch. Old path must pass every existing test unchanged.
3. Generator: emit `routeX` per binding in the service module: path template → concat of literals and `percentEncode (text field)` with typed text rules (string as is; ints `String.fromInt`; int64 strings as is; bool; enums by name; Timestamp RFC 3339; FieldMask camelCase comma-joined; Duration; nested `a.b`); query: omit proto3 defaults / `Nothing`, repeated → many pairs; body rules `*` / field / none; the segment check. Regenerate tests/Routes, examples, live client.
4. Oracle: `conformance/routes/*.json` replayed through `Rpc.request` (RouteFixturesTest) must pass with generated routes; `just live` against Vanguard/grpc-gateway/Envoy must pass.
5. Measure: sizes again (per-method delta, runtime delta, totals min+gz); a node micro-benchmark of `Rpc.request` ×10k old vs new; generator LOC and test delta.
6. Report `GEN-ROUTES-REPORT.md`: tables; API deltas; "who loses" (hand-written descriptors → `interpret`; runtime binding introspection; fix distribution: route bugs fixed by regenerating, not by a runtime update; readability of generated code; compile-time vs runtime errors); recommendation and a 1.0 posture (land pre-1.0 / define the additive shape and land later / drop).

## Caps and rules
Branch `spike/gen-routes` in worktree `~/Documents/elm-connect-wt/spike-gen-routes`; Opus; single Rust build slot (after `gen/header-options` finishes); disk floor 8,000,000 KiB before each build; no large googleapis generation; no application named; nothing merged; the report is the deliverable. Timebox: one agent run (~2 h); stop at the first blocker and report.

---

# Report: generated route functions (spike, 2026-10-24)

Branch `spike/gen-routes` (from `origin/main` ef27315), worktree
`~/Documents/elm-connect-wt/spike-gen-routes`. Nothing is meant to merge.
Commits: baseline (aa46518), runtime (449b8f6, bf9f33b), generator
(7153690, plus a printing fix), regeneration (aa4abda), measurements
(`spike/after.md`). `mise exec -- just check` passes at the head.
`mise exec -- just live` passes: Vanguard, grpc-gateway, Envoy, and the
Connect conformance suite (213 `ok`, the same 16 `known` divergences the
known-divergent files list, 0 failures; conformance 40/40 and 39/40 + 1
known).

## Answer in one paragraph

Generated route functions work, pass every oracle (fixtures, route
properties, the fuzzed transcoding tests, the live suite against three
transcoders) and roughly halve the time `Rpc.request` takes over
Transcode (5.6 to 2.9 us a request). The bundle win is real but modest:
3 to 5% gzipped (0.8 to 1.0 KB) on the three programs measured, and it
comes almost entirely from the fixed cost that drops out (the
interpreter, `Proto.Http`, and the field descriptors and descriptor
modules that only the binding data reached), not from the per-method
code, which grows for methods with wide queries. The plan's
`Result PathError Route` shape cannot keep `Rpc.request`'s documented
behaviour and had to become `( Route, Maybe PathError )`. The price is a
dozen new public helper functions, about 670 lines of generator, route
fixes that ship by regenerating, and binding introspection that moves
off the call.

## Size

Bytes; `elm make --optimize` (0.19.2), terser 5.36.0 `--compress
--mangle`, `gzip -9`. Programs: the notes example, the live runner
(notes, routes and Connect conformance clients), and a worker sending
every binding of `tests/Routes` through `Rpc.request` (`spike/routes-main`).

| program | stage | baseline | after | delta |
|---|---|---:|---:|---:|
| notes | optimized | 298401 | 283788 | -14613 (-4.9%) |
| notes | minified | 77210 | 74351 | -2859 (-3.7%) |
| notes | gzip | 25477 | 24665 | -812 (-3.2%) |
| live | optimized | 373283 | 354112 | -19171 (-5.1%) |
| live | minified | 91164 | 90197 | -967 (-1.1%) |
| live | gzip | 27917 | 26898 | -1019 (-3.7%) |
| routes | optimized | 207776 | 194141 | -13635 (-6.6%) |
| routes | minified | 49276 | 49171 | -105 (-0.2%) |
| routes | gzip | 15714 | 14957 | -757 (-4.8%) |
| routes, old generated code on the new runtime | gzip | 15714 | 16140 | +426 (+2.7%) |

Runtime delta (unminified, attribution by module): notes -12.0 KB, live
-12.3 KB, routes -9.0 KB. In the routes program `Rpc.Internal.Route`
7.7 -> 2.1 KB, `Proto.Http` 3.2 -> 0, `Proto.Field` 1.8 -> 0,
`Proto.Enum`/`EnumValue` 0.6 -> 0, `Proto.Internal` 0.7 -> 0.1, and the new
`Rpc.Route` +5.3 KB. Generated descriptor modules reached only through
bindings drop out too (`Routes.V1.Everything` 5.0 KB and the rest).

Per method (unminified; call + descriptor before, call + descriptor +
route functions after; the descriptor modules the bindings reached are
counted above, not here):

| service | method | before | after | delta |
|---|---|---:|---:|---:|
| notes | getNote | 1056 | 993 | -63 |
| notes | listNotes | 1377 | 1426 | +49 |
| notes | createNote | 884 | 1029 | +145 |
| notes | updateNote | 1317 | 1461 | +144 |
| notes | deleteNote | 1085 | 1025 | -60 |
| notes | archiveNote | 1096 | 1235 | +139 |
| notes | total | 6815 | 7169 | +354 |
| tests/Routes | getMessage (4 bindings) | 5097 | 5124 | +27 |
| tests/Routes | query/single/multi/typed (22 params each) | 3825-4063 | 4949-5258 | +1058..+1195 |
| tests/Routes | files/head | 1043-1046 | 965-970 | -76..-78 |
| tests/Routes | the other 6 | 457-1367 | 486-1493 | +29..+225 |
| tests/Routes | total | 28910 | 34015 | +5105 |

The call itself grows (about 265 -> 420 bytes: `methodWith`'s record and
routes list); the descriptor shrinks (about 800 -> 200). A query
parameter costs more as code than as data (`Rpc.Route.unlessZero
"page_token" "" Basics.identity request_.pageToken` against
`Proto.Http.param [ ….pageToken ]`): the four 22-parameter methods grow
by about 1.1 KB each unminified. So the per-method code eats into the
fixed saving as an API grows; in the routes program the minified total is
already flat (-0.2%), though gzip still saves 4.8% because the emitted
code repeats itself. The emission is a first cut; a
`List.concat` of singleton lists, `Basics.identity` for strings and the
zero repeated per parameter are all cheap to tighten.

Full tables, raw attribution: `spike/baseline.md`, `spike/after.md`.

## Speed

`node spike/bench.js OLD NEW 625 15`: 10,000 `Rpc.request` calls (625
rounds of the worker's 16 requests, a fresh path value per round), median
of 15 after a warm-up, Node 24.21, unminified optimized builds. The last
round's requests are byte-identical across all three builds.

| build | median | per request |
|---|---:|---:|
| baseline (interpreter over the request's JSON) | 56.1 ms | 5.61 us |
| route functions | 29.4 ms (28.9 re-run) | 2.94 us (-48%) |
| old generated code on the new runtime | 60.7 ms | 6.07 us (+9%) |

The +9% for old code is the tuple: Elm is strict, so the interpreter now
computes the path check whenever it builds the request. Sending (not
measured) still builds the route twice (once for the request, once in
`unsendable`) and still encodes the request's JSON over Transcode for the
write limit, so per-send JSON work is not gone.

## What changed in the runtime

- `Rpc.Route` (new exposed module): `Route` (`method`, `path`
  percent-encoded without a leading slash, `query` unencoded pairs, `body
  : Maybe Json.Encode.Value`), `PathError` (`{ field, template }`, exactly
  the record `InvalidPathValue` carries, so no second error), and the
  helpers generated code calls.
- `Proto.Internal.Interpret`: the interpreter, moved out of
  `Rpc.Internal.Route` unchanged but for returning a `Route`.
- `Proto.Internal.Method`: the `Method` type, now over its descriptor type
  and holding one route per binding (`build : req -> ( Route, Maybe
  PathError )` and the response body's JSON name); `Proto.Method.Method`
  aliases it.
- `Proto.Method.method` builds its routes by interpreting the
  descriptor's bindings over the encoded request; `methodWith` takes them.
- `Rpc.Internal.Wire` builds the transcoded request from the route of the
  call's `viaBinding` index; `Answer` reads the response body's name from
  it; `Rpc.Call.viaBinding` counts routes. Connect is untouched.
- Every existing test passed on the old path before the generator was
  touched (2565 runtime + 11 example tests), and still passes after.

## What the generator had to grow

- `emit/route_fn.rs` (new, 532 lines), `emit/method.rs` +103/-15,
  `emit.rs` +41 (a `ROUTES` section; `emit_service` takes every
  generated package to walk field paths across them), `lib.rs`,
  `naming.rs` (`Rpc.Route` reserved as a runtime module). Crates total
  +672/-26.
- Cases it handles: literal and single-/multi-segment variables (the
  segment check reproduced: `checkSegment` non-empty or the literal,
  `checkSegments` split at `/` with `*`, `**` and literals), the custom
  verb, nested `a.b` through `Maybe` messages, oneof members (a `case` on
  the oneof), text rules (string, int64-as-string as is;
  `String.fromInt`; `Rpc.Route.bool`; enums, floats, bytes, field masks
  and int64-as-Int through their proto3 JSON encoder (`viaJson`, a small
  JSON detour per value, not per request); Timestamp and Duration through
  `Proto.Timestamp.toString`/`Proto.Duration.toString`), query omission
  (no presence: `unlessZero` against the typed zero; presence:
  `optional`; repeated: one pair per element), body `*` (the request's
  encoder then the runtime's `without`, the old `remove`: it decodes the
  object back into key-value pairs once per path variable, the first
  cut's cost), `body: field` (that field's encoder, `{}` when unset), and
  no body. A well-known request type is typed when its route reads no
  field.
- Fallback: a binding it cannot type becomes `Proto.Http.interpret` of
  its data over the encoded request (a field of a message outside the
  generated packages, a recursive message on the path, `bytes` held as
  `Bytes`). Nothing in the corpus, the example, the live client or the
  conformance suite falls back (0 of every binding generated).
- Tests: no Elm test changed or was added. Two Rust unit tests edited
  (the call's printed text and sections; the runtime module list). No
  unit test for `route_fn.rs` itself; its oracle is the 5 fixture files,
  the route properties and the live suite, which all pass.

A generated route, for reading (`ListNotes`, was 24 lines of
`Proto.Http` data plus four field descriptors):

```elm
routeListNotes0 : Notes.V1.ListNotesRequest -> ( Rpc.Route.Route, Maybe Rpc.Route.PathError )
routeListNotes0 request_ =
    ( { method = "GET"
      , path = "v1/notes"
      , query =
            List.concat
                [ Rpc.Route.unlessZero "page_size" 0 String.fromInt request_.pageSize
                , Rpc.Route.unlessZero "page_token" "" Basics.identity request_.pageToken
                , Rpc.Route.unlessZero "filter" "" Basics.identity request_.filter
                , Rpc.Route.unlessZero "visibility" Notes.V1.VisibilityUnspecified (Rpc.Route.viaJson Notes.V1.encodeVisibility) request_.visibility
                ]
      , body = Nothing
      }
    , Nothing
    )
```

and the call:

```elm
listNotes =
    Rpc.call
        (Proto.Method.methodWith
            { encode = Notes.V1.encodeListNotesRequest
            , decode = Notes.V1.decodeListNotesResponse
            , descriptor = descriptorListNotes
            , routes = [ { route = routeListNotes0, responseBody = Nothing } ]
            }
        )
```

`tests/Routes/V1/Routes.elm` grows from 779 to 1432 lines.

## Findings

1. **The plan's `Result PathError Route` shape breaks `Rpc.request`'s
   contract.** `Rpc.request` documents that it builds the request whatever
   the call holds, a path value its template cannot match included, and
   that sending is what refuses it (PR #117). With a `Result`, an invalid
   value has no route to build. Implemented as planned, 171 tests failed
   (163 route properties, 4 bodies, 2 multi-segment, 2 fuzzed), every one
   a request with an empty or mismatched path value; the route fixtures
   themselves passed. The spike switched to `req -> ( Route, Maybe
   PathError )` (commit bf9f33b), which keeps the contract, and also made
   `Proto.Http.interpret` take that shape. Either the shape is the tuple,
   or the contract changes (`request` of such a call has no meaningful
   URL); that is a decision, not a detail.
2. **The plan's `routes` list lacks the response body.** A binding's
   `response_body` decides how the answer is decoded, so each route
   carries it: `routes : List { route, responseBody : Maybe String }`.
3. **No fixture failed** with generated routes, and the live suite's
   results are unchanged under all three transcoders.
4. **Naming is not checked.** `routeXN`, `bindingsX` and the locals
   (`request_`, `valueN_`, `member_`, `message_`) are new names in the
   service module's namespace, which design §3.7 says holds only calls
   and descriptors. A method named `routeGetNote0`, or one whose Elm name
   is `request_`, would now clash or shadow; `naming.rs` would have to
   reserve them.
5. **Two template matchers.** Keeping the interpreter means
   `Proto.Internal.Interpret.matches` (over `Segment`s) and
   `Rpc.Route.checkSegments` (over strings) implement the same rule
   twice; a fix to one must reach the other.

## API deltas

Added (all additive to 0.1):

- module `Rpc.Route`: `Route`, `PathError`; `segment`, `segments`,
  `checkSegment`, `checkSegments`, `firstInvalid`, `unlessZero`,
  `optional`, `repeated`, `bool`, `viaJson`, `jsonText`, `without` (12
  functions that exist for generated code and become public API).
- `Proto.Method.methodWith : { encode, decode, descriptor, routes : List
  { route : req -> ( Rpc.Route.Route, Maybe Rpc.Route.PathError ),
  responseBody : Maybe String } } -> Method req res`.
- `Proto.Http.interpret : Binding -> Json.Encode.Value -> (
  Rpc.Route.Route, Maybe Rpc.Route.PathError )`.

Changed:

- `Proto.Method.Method req res` is an alias of
  `Proto.Internal.Method.Method Descriptor req res` (still opaque; the
  package site and compiler errors show the internal name, as for
  `Proto.Http.Binding`).
- Generated code: the call is built by `methodWith`; `descriptorX` is
  built with no bindings; `routeXN` and `bindingsX : List
  Proto.Http.Binding` are new top-level values. So for regenerated code
  `Rpc.Call.descriptor c |> Proto.Method.bindings` is `[]`: the rule is in
  `bindingsX`, which an application must import by name.
- `Rpc.Call.viaBinding` counts the method's routes, not its descriptor's
  bindings (the same number for code built by `method`).
- `Rpc.request`, `Rpc.response`, `Rpc.send` and every other `Rpc`
  signature: unchanged.

Redundant if the interpreter goes: `Proto.Method.method`; the bindings
argument of `Proto.Method.descriptor` and `Proto.Method.bindings`; all of
`Proto.Http` (`binding`, `literal`, `variable`, `wildcard`,
`doubleWildcard`, `noBody`, `wholeBody`, `bodyField`, `param`,
`interpret`); `Proto.Internal.Interpret`; the generator's binding-data
emission (it would stay only if `bindingsX` stays). `Proto.Field`
descriptors stay for messages and the registry.

## Who loses

- **Hand-written descriptors.** Code that builds a `Descriptor` with
  `Proto.Http` data (in this repository: the runtime's own
  `TranscodeTest`/`RpcTest`; outside it, anyone calling an API without
  generating from protos) keeps working through `Proto.Method.method`, at
  the old cost. With the interpreter gone they would write route
  functions with the `Rpc.Route` helpers: possible, but every helper is
  then documented, supported API, and the "rule as data" path that
  `docs/descriptors.md` and design §3.9 describe is gone.
- **Runtime binding introspection.** Anything that reads a call's rule
  (route templates in logs or traces, a mock server or test double that
  matches requests to methods, generic tooling over descriptors) gets `[]`
  from `Rpc.Call.descriptor` for regenerated code and must import
  `bindingsX` by name. Nothing in this repository does so (`Rpc.Trace`
  records only the binding's index). Dropping data entirely removes it.
- **Fix distribution.** Encoding, template matching, JSON text and the
  `*` body are runtime helpers, so their fixes still ship in the runtime.
  What is now emitted (which fields go where, presence and default rules,
  oneof reads, the order of checks) is fixed only by a new generator and
  every application regenerating: a route bug of that kind becomes a
  regenerate-and-redeploy for each consumer rather than a package bump.
  The `Proto.Version` sentinel at least makes generated code and runtime
  agree on the helpers' meaning.
- **Readability.** A route reads as the request it builds (above), more
  directly than nested `Proto.Http` data does; it is longer for wide
  queries (45 lines for `Everything`'s 22 parameters) and the module
  nearly doubles in lines.
- **Compile-time against run-time errors.** Typed access turns a
  generator mistake about a field (a wrong name, a wrong type, presence
  misread) into an Elm compile error in the generated module; the
  interpreter's JSON lookup instead read a missing key as the default,
  silently. Path-value validity stays a run-time check (values are run
  time), with the same `InvalidPathValue`.
- **Applications on old generated code** keep working, but pay 2.7% more
  gzipped and 9% more per request until they regenerate (the runtime now
  carries both the route plumbing and the interpreter).

## Who loses if the data-only descriptors and the interpreter are dropped entirely (the operator's question)

Every application calling generated code gains (smaller, faster, typed).
The losers are:

1. people writing descriptors by hand, for APIs they do not generate
   from protos or in tests: they lose the declarative form and must write
   route functions against the `Rpc.Route` helpers;
2. tools that introspect a method's HTTP rule at run time: mocks, request
   routers, logging of templates, documentation UIs. They lose it unless
   `bindingsX` is kept as an opt-in value (which costs nothing in a
   program that does not refer to it);
3. consumers waiting on a route fix: emitted-logic bugs are fixed by
   regenerating, not by upgrading the runtime;
4. the bindings the generator cannot type today (a path or query field in
   a message of a package that is not generated, a recursive message on a
   path, `bytes=bytes` in a query): without the interpreter to fall back
   to they need typed support or a diagnostic first. None occurs in the
   corpus, so the gap is unmeasured;
5. the runtime's own test suite, whose transcoding tests are written
   against hand-built descriptors and would need rewriting
   (`tests/Rpc/TranscodeTest.elm`, 58 tests building bindings with
   `Proto.Http`, and a few in `RpcTest.elm`).

## Open problems

- Decide the route shape: the tuple (kept contract) or `Result` (changed
  contract). The tuple costs the old path 9% (strict evaluation of the
  check); a lazy check (`() -> Maybe PathError`) or computing the check
  only in `unsendable` would remove that.
- Sending builds the route twice and still encodes the JSON for
  `requestTooLarge` over Transcode; measure `Rpc.send`'s path, not only
  `Rpc.request`.
- Reserve the new names (finding 4); add unit tests for `route_fn.rs`;
  cover the fallback cases with corpus cases (cross-package path fields,
  recursion, `bytes=bytes`, `int64=int` in paths).
- Tighten the emission (per-type query helpers, no `List.concat` of
  singletons, no `Basics.identity`) and re-measure: the per-method growth
  is mostly avoidable.
- Docs: design §3.9 ("Bindings are data"), §5.2 (`Rpc.Internal.Route`),
  §3.7 (the service namespace), `docs/descriptors.md` and
  `docs/transcoding.md` would all change; the spike updated none of them.
- One matcher (finding 5) if the interpreter stays.

## Recommendation and 1.0 posture

**Define the additive shape now, land later** (in a 1.x minor), with two
small pre-1.0 moves so nothing about 1.0 forecloses it:

- Everything the spike adds is additive: `Rpc.Route`, `methodWith`,
  `Proto.Http.interpret`, a new field inside the opaque `Method`. None of
  it needs to be in 1.0, and the generated code's shape is the
  generator's to change under the version sentinel.
- What 1.0 would freeze that matters is the *meaning* of
  `Proto.Method.bindings (Rpc.Call.descriptor call)`. Before 1.0,
  document it as the rule of code built from bindings, possibly `[]` for
  generated code, or move generated binding data to `bindingsX` already
  (it costs nothing and is what landing would do), so that landing route
  functions later is not a behaviour change.
- And settle the route shape question (finding 1) in the design doc
  before 1.0, since `Rpc.request`'s contract is what decides it.

Not "land before 1.0": the win (about 1 KB gzipped and 2.7 us a request)
is real but small next to a 25 KB application, while the cost is a dozen
public helpers frozen at 1.0, a doubled service module and an untested
fallback matrix. Not "drop": the speed and the dead-code result are
solid, the oracle passes untouched, and the shape is additive, so it can
wait for a release that also tightens the emission. If the interpreter
is ever dropped, keep `bindingsX` as data so introspection survives;
then only hand-written descriptors lose, and `Proto.Http.interpret`
could live on as a small separate package for them.

## Blockers and deviations

- None blocked the work. Docker, Go, buf and Envoy were available; `just
  live` ran in full.
- Deviations from the plan, recorded above: the route shape (tuple, not
  `Result`); `routes` records carrying `responseBody`; the review's
  attribution script classified generated modules by an application's
  prefix, so the copy in `spike/` takes the prefixes as an argument; the
  plan names `Rpc.Route`/`Rpc.PathError`, which live in a module
  `Rpc.Route` (as `Rpc.Route.Route`, `Rpc.Route.PathError`) because
  `Proto.Method` cannot import `Rpc`; no changelog fragment or doc edits
  (spike branch).
