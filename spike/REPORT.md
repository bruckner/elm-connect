# Spike report: runtime performance and size (2026-10-25)

Branch `spike/perf-size` from origin/main dfe7d38, pushed; no PR, nothing merged. Five commits:

| commit | what |
|---|---|
| 43cb782 | harness |
| 1a1c425 | **P1**: transcoding code only reachable through `Rpc.Transport.transcode` |
| 35f21cc | **P2**: the request path stops doing work it never uses |
| 00ef9c7 | **P3**: two JSON decode hot spots |
| 1a574ed | cost estimates for the remaining blockers; a hand-written decoder used to estimate a generator change |

`spike/NOTES.md` holds every table below.

**Method.** Elm 0.19.2 `--optimize`, terser 5.36.0 `--compress --mangle`, `gzip -9`, Node 24.21, as the gen-routes reports. The notes baseline reproduces 298,401 / 77,210 / 25,477 B to the byte.

Tools in `spike/` (`attr.py`, `fn.py`, `measure.sh`, `bench.js` copied from gen-routes-2):
- **`attr2.py`** attributes kernel code to its package (the old `attr.py` folds it into whichever definition precedes it) and gives a leave-one-out estimate of each module's minified and gzipped share (module stubbed, an array naming every definition appended so terser cannot drop anything else).
- **`loo.py`** gives the same leave-out cost for any group of definitions.
- **`why.py`** prints the shortest reference chain from `main` to a definition: why it survives DCE.
- **`bench-main/` + `bench-perf.js`** times each task as (median T(n) − median T(0)) / n over 11 runs, n set so a run takes ~20 ms; with two builds it alternates them and compares checksums.
- **`build-bench.sh REV`** compiles the bench against any revision's `src/`.
- **`prof-run.js` / `prof-sum.js`** run `--cpu-prof` and attribute self time to the enclosing compiled definition.
- **`to.sh`** timeout wrapper (macOS has no `timeout`).

`bench.js` drives a `routes-main` program this branch does not have.

## 1. Size attribution: three programs

Programs: **min** (`spike/min-main`: `Platform.worker`, one `Rpc.send` of Eliza's `Say` over Connect, error read with `Rpc.Error.message`); **notes**; **eliza**.

| program | baseline opt / min / gz | spike head opt / min / gz | gz change |
|---|---|---|---:|
| min | 169074 / 45127 / 14868 | 156267 / 42067 / 13910 | −958 (−6.4%) |
| eliza | 216568 / 58150 / 19317 | 203911 / 55139 / 18389 | −928 (−4.8%) |
| notes | 298401 / 77210 / 25477 | 300181 / 77653 / 25639 | +162 (+0.6%) |

Optimized bytes by runtime module, leave-one-out gzip share in parentheses, baseline → head:

| module | min | eliza | notes |
|---|---|---|---|
| Rpc.Internal.Http | 13416 (1232) → 10617 (1060) | 13424 → 10625 | 12833 → 12288 |
| Rpc.Internal.Route | 11340 (940) → 1154 (109) | 11342 → 1154 | 11340 (needed) |
| Proto.Json | 9347 (891) → 10221 (983) | same as min | 27230 (2385) → 28944 (2510) |
| Rpc.Internal.Answer | 9152 (729) | 9160 | 9162 |
| Rpc.Internal.Retry | 5810 (605) | 5819 | 5834 |
| Rpc.Internal.Wire | 4985 (490) → 5254 | 4997 → 5267 | 5013 → 5283 |
| Rpc.Error | 4579 (550) | 4854 (adds `toString`) | 5212 |
| Rpc | 3930 → 4094 | 3932 → 4096 | 3544 → 3709 |
| Rpc.Code | 3012 (375) | 3683 (adds `toString`) | 3683 |
| Proto.Method | 1311 | 1318 | 1320 |
| Proto.Timestamp / Proto.Duration | – | – | 8457 (884) / 3014 (252); the note's fields need them |
| Proto.Http, Proto.Field, Proto.Internal.Binding | – | – | 3061 / 1337 / 651: descriptor binding data for the interpreter |
| other runtime modules | under 700 each | | |
| kernel + package elm/core | 38128 + 33356 | 38196 + 33633 | 38184 + 38234 |
| elm/json (kernel + package) | 9020 + 5852 | | |
| elm/http (kernel + package) | 3704 + 5680 | | |
| elm/virtual-dom + elm/browser kernels | – | 30104 + 9191 | same |

In min the runtime is 41% of optimized bytes at baseline (69,651) and 37% at the head (57,973).

**Why each piece survives DCE** (min at baseline, chains from `why.py`):
- **`Rpc.Internal.Route`, ~940 B gz.** `send → request → Wire.request → Wire.transcodeRequest → Route.transcodeUrl`, and `unsendable → Wire.invalidPathValue`. Fixed in P1.
- **`Rpc.Internal.Retry`, 607 B gz.** `send → taskFromRequest → attempt → Retry.run` with no policy set; also `attempt → Wire.withBudget → Retry.attemptTimeout`. Together 722 B gz.
- **`Proto.Json.any` + Any JSON helpers, 361 B gz.** `Answer.failure → connectBody/statusBody → detailList → Proto.Json.any`.
- **`Rpc.Error.message` chain, 406 B gz.** `Answer.failure` uses it as fallback text for gRPC headers without `grpc-message`.
- **percentDecode chain, 350 B gz.** Reached via `Answer.failure` reading `grpc-message`.
- **`Code.fromString`/`fromInt`, 298 B gz.** Needed to read errors.
- **`Code.fromHttpStatus`, 51 B gz.** `attempt → retryCode → Error.code`.
- **percentEncode chain, 202 B gz.** `connectRequest`'s GET branch; a POST-only program still carries it.
- **Size-limit code, 180 B gz.** Reached with no limit configured.
- **Transcoding response decoder in `Answer`, 78 B gz.**

Not reached in min: Rpc.Trace and its internal module, `splitTrailers`, Proto.Timestamp, Proto.Duration, Proto.Http, Proto.Field, the `checkConfig` texts, `Code.toString` (Eliza reaches it through `Error.toString`).

Elm removes dead code per definition, so splitting a module changes nothing; only what is reached matters. String literals are 6.0–8.6% of minified output. Terser cannot remove Elm's A2–A9 / F2–F9 currying wrappers; code names appear twice (`fromString`, `toString`).

## 2. Time profile at baseline (µs per call, median of 11)

**Request path:**

| task | µs |
|---|---:|
| `Rpc.request` over Connect, `Say` | 1.67 |
| same, a 330-byte note | 12.76 |
| same, a 12 KB note (1,000 tags) | 339 |
| encoding that 12 KB message alone | 19.6 |
| over transcoding: get / list / create | 0.56 / 2.90 / 2.14 |
| `Rpc.send` over Connect: `Say` / note / six headers | 2.03 / 14.7 / 3.65 |
| `Rpc.send` over transcoding: create | 5.36 |
| building a `Call` | 0.001 |

**Answer path:**

| task | µs |
|---|---:|
| success, `Say` / note | 0.28 / 4.94 |
| Connect error / with details | 0.36 / 1.64 |
| `google.rpc.Status` error | 1.13 |
| gRPC-header error | 5.34 |
| HTML error page | 3.90 |
| `Error.toString` | 0.06 |
| `splitTrailers` (8 headers) | 0.95 |

**JSON codecs:**

| task | µs |
|---|---:|
| decode a note (generated) / plain elm/json / `JSON.parse` alone | 4.90 / 0.67 / 0.53 |
| decode 1,000 notes (generated) / plain / `JSON.parse` alone | 2701 / 253 / 141 |
| Scalars, all set / all absent (`{}`) | 8.28 / 3.36 |
| Team (maps) | 48.1 |
| 1,000-entry string map / elm/json `dict` | 342 / 349 (no overhead) |
| Event (well-known types) | 13.1 |
| Forest (40 nodes) | 79.1 |
| one Timestamp | 0.46 |
| one int64 | 0.56 |
| encoders: note / 1,000 notes | 1.6 / 731 |

Where the time goes:
- **Connect request:** 75% builds a GET URL that is then thrown away (`percentEncode`, `hexByte`, `List.map`, `String.join`); `connectRequest`'s `let` is eager, so every POST paid. `send` also encoded the message a second time to check an unset write limit.
- **Message decode:** 42% in `_Json_run`/`_Json_runHelp`; each field makes 3–4 nested `decodeValue` calls (probe, `isArray`/`isObject`, `isNull`, the field's decoder).
- **int64-heavy messages:** a further 20–25% in `canonicalInteger` on text that is almost always canonical already.
- **gRPC and HTML error answers:** 56% is `JSON.parse` throwing on a non-JSON body.
- Dict building, Timestamp parsing, Maybe wrapping: minor.

## 3. Ranked opportunities

| # | change | measured or estimated saving | API impact | risk | pre-1.0? |
|---|---|---|---|---|---|
| 1 | **P2, done.** Build the Connect GET URL only for a call that may go as GET; encode a second time only when a write limit is set; check a header value in one `String.all` pass. | Measured: Connect request −85 to −94% (12.9 → 1.9 µs at 330 B; 324 → 21 µs at 12 KB); send −74 to −94%; transcoding send −31%. −21 to −46 B gz. | none | very low | no; land any time |
| 2 | **P1, done.** The `Transcode` variant holds Route's URL, body and path-check functions, so only `Rpc.Transport.transcode` reaches them. | Measured: −958 to −972 B gz (−5.0 to −6.5%) for Connect-only programs; +55 B for a transcoding program. Times unchanged. | No type change. `==` still holds (elm/core compares by reference first; new test pins it). `Debug.toString` of a config shows `<function>`. | low | Yes: docs say a transport "is data"; before 1.0 word the contract as "transports built alike are `==`" |
| 3 | One object check per message in generated decoders, plus additive `Proto.Json` helpers. | Estimated via hand-written decoder: note −14% (`map8`/`map5` instead of pipeline: −18%); 1,000 notes −27%. | additive | medium: needs codec round trips as oracle | no |
| 4 | **P3, done.** Return canonical int64 text as is; build error texts only on failure; skip list work for a one-spelling field. | Measured: int64 −73%, Scalars −27%, Team −31%, note −17%, 1,000 notes −12%, `Rpc.response` of a note −16%. +47 to +128 B gz. | none | low, but codec round trips not run | no |
| 5 | Transcoding send: build request JSON and route once (`invalidPathValue` re-encodes today). | Est. −1.5 µs (~−40%) per transcoding send. | none | low | no |
| 6 | Retry policy math and deadline path held by the `Retry` value (P1's reference trick). | Est. −400 to −500 B gz (bound 722); the polymorphic loop cannot move. | none | low–medium | no |
| 7 | Generated route functions + trimmed call descriptor (gen-routes-2). | notes −870 B gz; transcoding `Rpc.request` −48%. | additive | medium | settle the descriptor's meaning pre-1.0 |
| 8 | In `Answer`, write HTTP-status text inline instead of `Rpc.Error.message`. | −406 B gz, only for programs never calling `message`/`toString` (min and Eliza both do). | none | trivial | no |
| 9 | Decode error-detail `Any` lazily. | Est. −361 B gz. | none at type level; `==` between `Any` values built differently may change | medium | if `Any` equality is documented |
| 10 | `Url.percentDecode` for `grpc-message`. | Est. ~−300 B gz. | adds elm/url dependency; stricter on malformed UTF-8 | low–medium | no |
| 11 | Skip `JSON.parse` on error bodies that cannot be a JSON object. | Est. −3 µs per such error (cold path). | none | low | no |
| 12 | Derive Code tables from one table. | Est. −100 to −150 B gz (bound 298). | none | low | no |
| 13 | percentEncode behind `connectGet`; size-limit code behind `with*MaxBytes`; transcoding decoder behind `transcode`. | Bounds −202 / −180 / −78 B gz. | none | low | no |
| – | Not worth doing: splitting modules; `Rpc.Call` record shape (0.001 µs); answer-path header handling (error/trace only); map Dict building (no overhead); Timestamp parsing (0.4 µs); Maybe wrapping. | | | | |

Items 6, 8, 9, 10, 12, 13 together would take min from 13.9 KB to roughly 12 KB gz, about −20% against the 14.9 KB baseline (estimated, not built).

## 4. Prototypes: before and after

- **P1** (1a1c425): sizes as in item 2. Left of Route in min: the binding lookup `Answer` and `Trace` use (`route`), `connectUrl`, `trimSlash`: 1,154 B optimized. Times within ±2%.
- **P2** (35f21cc), µs, P1 → P2: `request.connect.say` 1.688 → 0.184; `request.connect.note` 12.905 → 1.880; `request.connect.tags1000` 323.7 → 20.7; `send.connect.say` 1.995 → 0.345; `send.connect.headers` 3.837 → 1.003; `send.connect.note` 14.316 → 1.919; `send.transcode.create` 5.332 → 3.681. Connect GET and transcoding requests unchanged. A Connect POST now costs about what encoding its message costs.
- **P3** (00ef9c7), µs, P2 → P3: note 5.14 → 4.27; Scalars 8.47 → 6.15; Team 47.8 → 33.2; Event 13.4 → 12.2; Forest 80.3 → 72.2; 1,000 notes 2787 → 2445; int64 0.57 → 0.16. Encoders and the all-absent message unchanged. Noise on the 1,000-note row 5–10% (n = 8).

**Oracles at the head:** runtime tests 1,034 pass (one new, pinning transport `==`); JSON tests at `--fuzz 2000` (356) pass; notes' 11 tests pass; Eliza builds; non-Rust gates rc 0 under `spike/out-gate/` (gitignored): `elm-format --validate`, `elm make --docs`, snippets, `changelog-check`, `license`, zizmor, gitleaks.

## 5. Not done
- **Codec round trips not run:** `tests/Codec/RoundTripTest.elm` reads `tests/Generated/`, which only `cargo test --test codec` writes. These are the oracle P3 most needs. Bench JSON payloads are hand-written, not prost-reflect's.
- **`just elm-check` not run as such** (depends on `codec-gen` = `cargo test`); its non-Rust steps run one by one.
- **No Rust built:** generated code unchanged; conformance compile check not run; items 3, 5, 7 left as estimates.
- No live suite, no design/changelog edits; items 5–13 not built.
- **Caveats:** leave-one-out shares are standalone upper bounds; `attr2.py`'s gzip (Python) reads 14,857 vs the shell's 14,868; one machine.
- **Out of scope, noticed:** (a) a header value whose first character is a lone low surrogate passes `validHeaderValue`; elm/core's `String.all` kernel reads `string[-1]` and checks the letter `u` of `"undefined"` instead; `String.toList` behaves the same, so true before P2 too; XHR would then throw outside elm/http's handler. Inferred from kernel source, not run. (b) elm/json 1.1.4 uses `Object.prototype.hasOwnProperty.call`, not `value.hasOwnProperty`; a one-run object check was still rejected because `hasOwnProperty` can cost in the object's size where `in` is constant. NOTES records both.
