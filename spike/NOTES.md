# Spike notes: runtime performance and size (2026-10-25)

Branch `spike/perf-size` from `origin/main` dfe7d38. Measurement spike;
nothing here merges. No Rust was built: everything below runs on the
committed runtime (`src/`), the committed example `generated/` trees and the
conformance corpus's `expected/` modules.

## Tools (`spike/`)

- `measure.sh OUT`: `elm make --optimize` (0.19.2), terser 5.36.0
  `--compress --mangle`, `gzip -9`, for three programs: `min` (spike/min-main,
  one `Rpc.send` of Eliza's `Say` over Connect, the error read with
  `Rpc.Error.message`), the notes example and the Eliza example. Prints the
  attribution by runtime module (`attr.py ... full`).
- `attr.py`, `fn.py`: copied from `origin/spike/gen-routes-2`; `attr.py`
  takes `full` to key runtime modules by their whole name. Both split the
  output at `var $...`, so kernel code is counted under the definition before
  it; `attr2.py` fixes that.
- `attr2.py JS GEN prefixes...`: statements split at every top-level
  `var`/`function`, kernel code under `kernel:<package>`; and for each key
  matching a prefix a leave-one-out estimate of its minified and gzipped
  share (its statements stubbed `var x = 0;`, an array naming every
  definition appended to both builds so terser drops nothing else).
- `why.py JS NAME`: the shortest reference chain from `main` to a definition,
  i.e. why it survives dead-code elimination.
- `bench-main/` (Bench.elm) + `bench-perf.js BUILD [OTHER]`: per-call times,
  `(median T(n) - median T(0)) / n`, 11 repetitions, n calibrated to ~20 ms a
  run. Fixtures are top-level values, so they are built at load, outside the
  timed `init`. With two builds it alternates them and compares checksums.
- `prof-run.js` + `prof-sum.js`: one task under `node --cpu-prof`, self time
  attributed to the compiled definition enclosing each sampled line.
- `to.sh SECONDS cmd`: a wall-clock limit (macOS has no `timeout`).
- `bench.js`: the gen-routes spike's `Rpc.request` bench, copied as the
  brief asks; it drives a `routes-main` program this branch does not have.

## Baseline (dfe7d38)

| program | optimized | minified | gzip |
|---|---:|---:|---:|
| min | 169074 | 45127 | 14868 |
| notes | 298401 | 77210 | 25477 |
| eliza | 216568 | 58150 | 19317 |

The notes numbers match the gen-routes baseline to the byte.

## Prototype 1: transcoding behind `Rpc.Transport.transcode`

`Rpc.Internal.Wire` called `Rpc.Internal.Route`'s URL, body and path-check
functions by name in its `Transcode` branches, so every program reached
them, a Connect-only one included (`why.py`: `main -> Rpc.send ->
Rpc.request -> Wire.request -> Wire.transcodeRequest -> Route.transcodeUrl`,
and `Rpc.unsendable -> Wire.invalidPathValue -> Route.invalidPathValue`).
The `Transcode` variant now carries those three functions
(`Rpc.Internal.Transport.Transcoder`), put there by `Rpc.Transport.transcode`;
Wire calls them through the transport. `==` on transports still holds:
elm/core compares by reference first, and every transcoding transport holds
the same three top-level functions (new test in `RpcTest`).

| program | gzip before | after | delta |
|---|---:|---:|---:|
| min | 14868 | 13896 | -972 (-6.5%) |
| eliza | 19317 | 18359 | -958 (-5.0%) |
| notes (transcodes) | 25477 | 25532 | +55 (+0.2%) |

Optimized: min 169074 -> 155717, eliza 216568 -> 203361, notes 298401 ->
298618. Minified: 45127 -> 42029, 58150 -> 55101, 77210 -> 77284. What is
left of `Rpc.Internal.Route` in min is `route` (the binding lookup Answer and
Trace use), `connectUrl` and `trimSlash`, 1.1 KB optimized. Request and
answer times unchanged (bench, within 2%). Runtime tests: 1034 pass (the
codec round trips need `cargo test` to generate their modules and were not
run); notes example tests 11 pass.

## Prototype 2: the request path's wasted work

Profile of `Rpc.request` over Connect (`request.connect.note`): 75% of the
time in `percentEncode`, `hexByte`, `List.map` and `String.join`, building
the GET URL. Elm evaluates a `let` eagerly, so `connectRequest`
percent-encoded the whole message into a GET URL for every call, POSTs
included, and measured it against `maxGetUrl`. And `Rpc.unsendable`, which
`send` runs on every call, encoded the message a second time to compare it
with a write limit, also when there is none. Headers were checked by turning
each value into a list of characters twice (`validHeaderValue`'s trim);
the trim changes nothing (a space and a tab pass the check themselves), so
the value is checked with one `String.all`.

`spike/build-bench.sh REV OUT.js` compiles Bench.elm against any revision's
`src/`. P1 against P2, µs per call:

| task | P1 | P2 | change |
|---|---:|---:|---:|
| request.connect.say | 1.688 | 0.184 | -89% |
| request.connect.note (330 B) | 12.905 | 1.880 | -85% |
| request.connect.tags1000 (12 KB) | 323.7 | 20.7 | -94% |
| request.connect.headers | 1.758 | 0.272 | -85% |
| request.connectGet.say (a GET) | 1.665 | 1.789 | +7% (noise; same work) |
| request.transcode.* | | | 0..+1% |
| send.connect.say | 1.995 | 0.345 | -83% |
| send.connect.headers (6 headers) | 3.837 | 1.003 | -74% |
| send.connect.note | 14.316 | 1.919 | -87% |
| send.connect.tags1000 | 338.5 | 20.4 | -94% |
| send.transcode.create | 5.332 | 3.681 | -31% |
| encode.createNote (the floor) | 1.685 | 1.693 | 0% |

A Connect POST now costs about what encoding its message costs. Size: min
-33 B gzip (13896 -> 13863), eliza -46 (18359 -> 18313), notes -21 (25532 ->
25511). Runtime tests 1034 pass, notes tests 11 pass.

## Prototype 3: two of the JSON decoders' hot spots

Profiles (`json.notes1000.decode`, `json.scalars.decode`, `json.team.decode`):
42% of a message decode is elm/json's `_Json_run`/`_Json_runHelp`, the
nested `decodeValue` calls a field makes to find its key (`probe`, then
`isArray` when found or `isObject` when not, then `isNull`, then the field's
own decoder); in messages with 64-bit integers (Scalars, Maps) 20-25% more
is `canonicalInteger`: `scientific`'s `split`/`toLower`/`all`, then
`leadingCount` and `trailingCount` folding over tuples, for text that is
almost always already canonical.

- A canonical decimal (`0`, or digits not starting with `0`, at most 20 of
  them, not `-0`) is its own canonical form: returned as it is, before
  `scientific`. Error texts of `wide` and `int64Form` are built only on
  failure.
- `spelledAs` of a single spelling, as most fields have, skips the general
  case's `List.any`/`List.filterMap`/`oneSpelling` work; same checks, same
  results.

Separately: the int64 path alone -73% on one int64, -30% Scalars, -26%
Team, -11% Note; the single-spelling path alone -8..-14% on messages with
single-spelling fields, -2% on Scalars (all `fieldEither`). Together, P2
against P3 (µs): note decode 5.14 -> 4.27 (-17%), Scalars 8.47 -> 6.15
(-27%), Team 47.8 -> 33.2 (-31%), Event 13.4 -> 12.2 (-9%), NoteEvent -8%,
Forest -10%, 1,000 notes 2787 -> 2445 (-12%), `Rpc.response` of a note
-16%. Encoders and `{}` unchanged. Run-to-run noise on the 1,000-note row is
about 5-10% (n = 8).

Size cost: min +47 B gzip (13863 -> 13910), eliza +76 (18313 -> 18389),
notes +128 (25511 -> 25639). Runtime tests 1034 pass, the JSON tests again
at `--fuzz 2000` pass (356); the codec round trips against prost-reflect's
samples (`tests/Codec`, generated by `cargo test`) were not run, and they are
the oracle these changes most need.

Not taken: deciding object-ness in one run with `keyValuePairs (fail "")`
(it fails at the first own key) starts a `for ... in` over the object, which
V8 may answer only after listing every key, so an absent field would cost
time in the object's size, where `in` costs constant time (the property
`spelledAs`'s comment states); a single-run `oneOf` check costs O(n) on an
array. The bigger win is a message-level object check in generated code
(below, estimated).

## Estimate: one object check per message (generated code)

`spike/bench-main/src/FastJson.elm` hand-writes the note decoders as
generated code could emit them: `message` checks object-ness once, then each
field only probes, checks `null` and decodes. Same results as the generated
decoders on the bench's inputs and on nine odd ones (arrays, `null`, a
string, `{}`, null fields, both spellings, wrong types, a `length` key);
`check` compares them. µs, on P3:

| decoder | note | 1,000 notes |
|---|---:|---:|
| generated (`Proto.Json.field`) | 4.40 | 2459 |
| one check per message, pipeline | 3.76 (-14%) | 1798 (-27%) |
| one check per message, `map8`/`map5` | 3.60 (-18%) | |
| plain elm/json `oneOf [field, succeed]`, 3 fields only (not proto3-correct) | 0.73 | 256 |
| `JSON.parse` alone | 0.54 | 145 |

What is left is the three runs a field still makes (probe, `isNull`, the
field's decoder) and the oneof's member probing.


## What each remaining blocker costs (min at the spike head)

`spike/loo.py`: the group's definitions stubbed, every other definition
kept, minified and gzipped against the whole. A standalone cost, so an upper
bound on what freeing it saves. `why.py` gives the chain.

| group | optimized | min | gz | reached by |
|---|---:|---:|---:|---|
| Proto.Json field machinery | 10221 | 3045 | 983 | the generated codecs (needed) and `Answer.detailList -> Proto.Json.any` |
| Retry module | 5810 | 1581 | 607 | `send -> taskFromRequest -> attempt -> Retry.run`, policy or not |
| Retry module + deadline path | 6989 | 1882 | 722 | also `attempt -> Wire.withBudget -> Retry.attemptTimeout` |
| Error.message chain (min-code, which never asks for a message) | 3004 | 1088 | 406 | `Answer.failure` (gRPC headers without `grpc-message`) |
| Retry policy math | 3481 | 975 | 405 | `Retry.run`'s policy branch |
| Any JSON for error details | 3207 | 1157 | 361 | `Answer.failure -> statusBody/connectBody -> detailList -> Proto.Json.any` |
| percentDecode chain | 3904 | 966 | 350 | `Answer.failure` (`grpc-message`) |
| Code.fromString + fromInt | 1934 | 953 | 298 | `Answer.connectBody`, `Answer.fromGrpc` (needed; tables could be smaller) |
| percentEncode chain | 2013 | 480 | 202 | `Wire.connectRequest`'s GET branch (Connect GET only) |
| size limits | 1812 | 493 | 180 | `unsendable`, `Answer.within` (no limit set) |
| header checks | 1342 | 339 | 126 | `unsendable` (needed: a bad header throws inside XHR) |
| Answer transcoding decoder | 895 | 218 | 78 | `Answer.toResult`'s Transcode branch |
| Code.fromHttpStatus | 322 | 175 | 51 | `attempt -> retryCode -> Error.code` |

Not reached in min (checked): `Rpc.Trace`/`Rpc.Internal.Trace`,
`splitTrailers`, `Proto.Timestamp`, `Proto.Duration`, `Proto.Http`,
`Proto.Field`, `Rpc.checkConfig`'s texts, `Rpc.Code.toString` (Eliza has it,
through `Rpc.Error.toString`). Splitting a module changes nothing in Elm:
dead code is eliminated per definition, so only what is reached matters.
