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
