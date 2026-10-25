# Spike follow-up: tightening generated route functions (2026-10-24/25)

Branch `spike/gen-routes-2` (from `spike/gen-routes` at e2d17d7). Measurement spike; nothing merges. Four commits, one per step. Written by the follow-up agent; saved by the dispatching session (the agent's report-file write was refused by the harness, so this is its text as returned).

| step | commit | change |
|---|---|---|
| 1 | d8b7413 | one query encoder per request message (`queryOf<Message>`), shared by every binding taking it |
| 2 | cd08139 | specialised query helpers in `Rpc.Route` |
| 3 | 2cf1c5d | flat route record, plain route functions, positional `methodWith` |
| 4 | 4419a5a | call descriptor trimmed to the Connect identity; full descriptor cold |

Gates at head: `just check` rc 0; `just live` 213 ok, 16 known, 0 failures; conformance 40/40 and 39/40 + 1 known.

## The question
The first spike made per-method code bigger (+354 B notes service; ~+1.1 KB per fixture method sharing the 22-field `Everything`) although the identity descriptor shrank and binding data became dead. Diagnosis: (a) query fields inlined per method where the data form shared field descriptors; (b) per-method structure (`methodWith` record, `{route, responseBody}` list, `(Route, Maybe PathError)` tuple, `List.concat`); (c) generic `unlessZero` carrying default + text function; (d) identity descriptor still carrying type names.

## Method
First spike's procedure (`spike/measure.sh`, `elm make --optimize` 0.19.2, terser 5.36.0, gzip -9, `attr.py`, `permethod.py`); baseline and spike head rebuilt from their commits and matched `spike/after.md` to the byte. Shared `queryOf*` definitions live in the package module and are listed on their own rows; totals count them once.

## Per method (unminified bytes: call, descriptor, route functions)

Notes service:

| method | baseline | spike | step 1 | step 2 | step 3 | step 4 |
|---|---:|---:|---:|---:|---:|---:|
| archiveNote | 1096 | 1235 | 1235 | 1235 | 1174 | 1113 |
| createNote | 884 | 1029 | 1029 | 1029 | 972 | 912 |
| deleteNote | 1085 | 1025 | 1025 | 1025 | 972 | 904 |
| getNote | 1056 | 993 | 993 | 993 | 940 | 883 |
| listNotes | 1377 | 1426 | 928 | 928 | 875 | 803 |
| updateNote | 1317 | 1461 | 1358 | 1358 | 1301 | 1241 |
| service module | 6815 | 7169 | 6568 | 6568 | 6234 | 5856 |
| queryOfListNotesRequest (shared) | – | – | 621 | 453 | 452 | 452 |
| queryOfUpdateNoteRequest (shared) | – | – | 244 | 277 | 277 | 277 |
| **total incl. shared** | **6815** | **7169** | **7433** | **7298** | **6963** | **6585** |

Fixture service (`tests/Routes`):

| method | baseline | spike | step 1 | step 2 | step 3 | step 4 |
|---|---:|---:|---:|---:|---:|---:|
| query (22 params) | 3825 | 4949 | 852 | 852 | 798 | 737 |
| single (22 params) | 3877 | 4971 | 1057 | 1057 | 999 | 938 |
| multi (22 params) | 3949 | 5007 | 1093 | 1093 | 1035 | 974 |
| typed (22 params) | 4063 | 5262 | 2172 | 2176 | 2118 | 2057 |
| getMessage (4 bindings) | 5097 | 5124 | 3494 | 3494 | 3340 | 3275 |
| cancel | 1045 | 1167 | 1167 | 1167 | 1105 | 1048 |
| files | 1046 | 970 | 970 | 970 | 916 | 853 |
| head | 1043 | 965 | 965 | 965 | 911 | 848 |
| postSub | 1048 | 1273 | 1273 | 1273 | 1211 | 1146 |
| unbound | 457 | 486 | 486 | 486 | 472 | 407 |
| updateMessage | 1084 | 1165 | 1165 | 1165 | 1107 | 1039 |
| updateMessageWhole | 1009 | 1187 | 1187 | 1187 | 1125 | 1070 |
| updateResource | 1367 | 1493 | 1395 | 1395 | 1337 | 1267 |
| service module | 28910 | 34019 | 17276 | 17280 | 16474 | 15659 |
| queryOfEverything (shared) | – | – | 3980 | 3489 | 3489 | 3489 |
| queryOfGetMessageRequest (shared) | – | – | 815 | 630 | 630 | 630 |
| queryOfUpdateResourceRequest (shared) | – | – | 249 | 282 | 282 | 282 |
| **total incl. shared** | **28910** | **34019** | **22320** | **21681** | **20875** | **20060** |

Step 1 removes the four inlined copies; `typed` stays largest for its five path variables. Steps 3 and 4 shrink every method by 52–62 B and 57–72 B. At step 4, four of six notes methods are below baseline (archiveNote +17 B, createNote +28 B).

## Totals (bytes)

| program | stage | baseline | spike | step 1 | step 2 | step 3 | step 4 | step 4 vs baseline | step 4 vs spike |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|
| notes | optimized | 298401 | 283788 | 284054 | 284298 | 283943 | 283768 | −14633 | −20 |
| notes | minified | 77210 | 74351 | 74409 | 74499 | 74389 | 74141 | −3069 (−4.0%) | −210 |
| notes | gzip | 25477 | 24665 | 24682 | 24703 | 24665 | 24607 | −870 (−3.4%) | −58 |
| live | optimized | 373283 | 354112 | 342887 | 343015 | 341717 | 340334 | −32949 | −13778 |
| live | minified | 91164 | 90197 | 87780 | 87912 | 87506 | 86265 | −4899 (−5.4%) | −3932 |
| live | gzip | 27917 | 26898 | 26927 | 26971 | 26922 | 26778 | −1139 (−4.1%) | −120 |
| routes | optimized | 207776 | 194141 | 182670 | 182933 | 182096 | 181484 | −26292 | −12657 |
| routes | minified | 49276 | 49171 | 46716 | 46863 | 46633 | 46034 | −3242 (−6.6%) | −3137 |
| routes | gzip | 15714 | 14957 | 14968 | 15004 | 14972 | 14898 | −816 (−5.2%) | −59 |

Minified change per step (gzip in brackets):

| step | notes | live | routes |
|---|---:|---:|---:|
| 1 shared query encoder | +58 (+17) | −2417 (+29) | −2455 (+11) |
| 2 specialised helpers | +90 (+21) | +132 (+44) | +147 (+36) |
| 3 flatten | −110 (−38) | −406 (−49) | −230 (−32) |
| 4 trim identity | −248 (−58) | −1241 (−144) | −599 (−74) |

By group, unminified (`attr.py`):

| program | group | baseline | spike | step 1 | step 2 | step 3 | step 4 |
|---|---|---:|---:|---:|---:|---:|---:|
| notes | runtime | 107421 | 95391 | 95391 | 95768 | 95753 | 95955 |
| notes | generated | 25941 | 23392 | 23656 | 23521 | 23181 | 22803 |
| live | runtime | 126717 | 114391 | 114615 | 115512 | 115485 | 115687 |
| live | generated | 109290 | 102845 | 91384 | 90610 | 89339 | 87753 |
| routes | runtime | 70320 | 61365 | 61589 | 62486 | 62455 | 62657 |
| routes | generated | 55178 | 51063 | 39368 | 38729 | 37923 | 37108 |

`Rpc.Route` 5349 → 5573 (step 1, `except`) → 6470 (step 2). `Proto.Method` 1094 → 1066 (step 3) → 1268 (step 4, `endpoint`). Gzip barely moves against the spike (−58 to −144 B) while minified drops 3–4 KB in routes and live: gzip had already squeezed the spike's repeated code, so the first spike's gzip figures understated both the repetition and what removing it is worth.

## Speed (`bench.js`: 10,000 `Rpc.request` calls, median of 15, Node 24.21)

| build | median | per request | vs spike |
|---|---:|---:|---:|
| baseline (interpreter) | 54.9 ms | 5.49 us | |
| spike | 28.8–29.5 ms | 2.88–2.95 us | |
| step 1 | 30.2 ms | 3.02 us | +4% |
| step 2 | 30.0 ms | 3.00 us | +3% |
| step 3 | 29.6 ms | 2.96 us | +3% |
| step 4 | 29.8–30.3 ms | 2.98–3.03 us | +3% |

Requests identical in every pair. Step 1 causes the regression (`except` filters path fields with `List.member`). Not measured: step 3 makes the answer path build the route again to read `responseBody`; sending also builds the route in `unsendable`.

## Which step paid most
- **Step 1** most where messages are shared: −11.7 KB unminified fixture service, −2.4 KB minified in live and routes; costs notes +264 B unminified / +58 B minified and ~4% speed.
- **Step 4** most evenly: every method −57 to −72 B; −1.2 KB minified in live; no speed cost.
- **Step 3** small uniform win: ~−55 B per method.
- **Step 2 did not pay.** Encoders −13–20% but runtime helpers +377 B (notes) / +897 B (routes); `unlessZero`/`viaJson` must stay for paths and `int64=int`; net +90 to +147 B minified; break-even ~45 query params per program. `enum` still needs the zero and encoder. **Trap:** in Elm 0.19.2 `value == 0` on a Float compiles to `!value`, true for NaN; the first `float` helper dropped `scale=NaN`, caught by two route-property tests; fixed with `value /= 0 || isNaN value`.

## Decisions within the steps
- Encoder lives in the message's package module (`Routes.V1.queryOfEverything`, a `QUERY ENCODERS` section); routes remove path/body fields by proto name with `Rpc.Route.except [...]`.
- Covers the union of query params of every binding of every generated method taking the message, declaration order, depth first; each binding's query = union minus excluded, byte-identical to the spike (bench checks).
- Filter rather than per-path/body variants: argued, not measured (variants would be three 3.5 KB copies vs one copy + three 30–60 B lists).
- Step 3: `Rpc.Route.Route = { method, path, query, body, responseBody, invalid }`; route function and `Proto.Internal.Method.Bound req` are both `req -> Route`; `methodWith encode decode descriptor [ routeX0 ]` positional; interpreter fills the same record.
- Step 4: `descriptorX = Proto.Method.endpoint service name idempotency`; `fullDescriptorX = Proto.Method.descriptor … [bindings…]` (the baseline descriptor), dead unless referenced.

## API consequences
1. `queryOf<Message>` becomes public generated API (package modules expose `(..)`); name not reserved in `naming.rs`; package modules now import `Rpc.Route` (call layer) — if landed, helpers belong in a `Proto.*` module (e.g. `Proto.Query`).
2. **The encoder depends on run composition** (union of bindings seen): a message's module changes when a service elsewhere starts/stops querying it; split runs can leave a service calling a `queryOfX` lacking fields (compile error). Fix: emit for every message over all leaves with a query form; DCE drops unused. Recommended.
3. `Rpc.Route` grows to ~19 functions (`except`, `string`, `int`, `int64`, `bool`, `float`, `enum`; `optional`/`repeated` take text; path `bool` renamed `boolText`).
4. `Route` gains `responseBody` and `invalid` (record alias: breaks hand-built routes); `methodWith` positional; `Proto.Http.interpret` returns `Route`. The path check is a field, so `Rpc.request` keeps its contract and sending reads `.invalid`.
5. Type names gone from generated calls: `Proto.Method.input`/`output` of `Rpc.Call.descriptor` are `""` for regenerated code; `bindings` stays `[]`; `fullDescriptorX` must be imported by name; `Proto.Method.endpoint` is new. Nothing in `src/` reads `input`/`output` but the accessors and tests (`Rpc.Trace` records the binding index; `Proto.Any` and `Rpc.Call.toJson` do not take the descriptor's types), so the change is invisible to the runtime and visible only to applications logging a call's type names. Must be settled before 1.0.

## Updated recommendation
Route functions are now smaller than the data form for most methods and far smaller for wide shared queries; bundles −4.0…−6.6% minified, −3.4…−5.2% gzipped vs baseline; requests 45% faster than the interpreter (3% slower than the untightened spike). Posture unchanged in kind: **define the additive shape, land later**, with:
- Take steps 1, 3, 4. Make the step-1 encoder a property of the message alone; move its helpers to a `Proto.*` module; reserve `queryOf*`, `route*`, `fullDescriptor*`.
- Drop step 2.
- Before 1.0 settle in design.md: a generated call's descriptor is the endpoint form (types `""`, no bindings) with the full descriptor as a separate value; the path check is a route field (`invalid`).
- Weigh step 3's answer-path cost: if one extra route build per Transcode response matters, keep `responseBody` beside the route function in the method.

## Not done or not verified
No new unit tests for `queryOf` emission/union (oracle unchanged and passing); design.md §3.7/§3.9, descriptors.md, fragment not updated (spike); variants alternative argued not measured; `Rpc.send` and answer path not benchmarked; regeneration via `just bless`, `just live-gen`, `just live-conformance-gen`, staged by name. Step outputs and logs are in the session scratchpad.
