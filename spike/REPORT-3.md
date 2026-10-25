# Binary codec spike, run 3: final report

All four legs done and pushed; no PR, nothing merged. The DCE fix comes back to within +552 B gzip of the baseline, not within noise (accounted for below). One leg-2 instruction deliberately not followed (the packed-run rule), with evidence.

| branch | head | commits |
|---|---|---|
| `spike/binary-codec` | **a6c849f** | e65cb25 DCE fix · d0e8b39 merge + opaque decoder · a6c849f elm-protocol-buffers comparison |
| `spike/grpc-web` (from a6c849f) | **ca904e7** | ca904e7 unary gRPC-Web transport |

**Gate, both branches:** `just check` stops at `test` (exit 101) on the known path-length test `a_missing_import_names_the_include_paths_searched`, not fixed. Every other gate passes alone: fmt-check, clippy, 283 Rust tests, elm-check (4,398 Elm tests on binary-codec, 4,413 on grpc-web, +11 notes example), snippets, changelog-check, zizmor, gitleaks, deny, license, package.

**Problem found and fixed: stale package-verify copies.** After the first `just check`, `target/debug/{elm-connect,protoc-gen-elm-connect}` generated pre-merge code until rebuilt: the immutable package-verify copies under `~/.cargo/registry/src/*/elm-connect-gen-0.1.0` dated from run 1 (COMMON.md's trap). Applied COMMON's fix: deleted those extraction directories, `cargo clean -p` on the three crates, removed `target/package`, reran `just package` on binary-codec (passes; Rust identical to grpc-web's). Leg 2's live run predates the problem (its `elm-both.js` was built from the new plugin).

## 1. DCE fix: before and after
- **Shape:** `withBinary` builds the whole bytes path as closures inside the method: the Connect message (POST bytes; GET base64 computed only for a GET), the write-limit check, the reading of a binary answer. `Proto.Message.withBinary` builds an `Any`'s base64 halves the same way.
- **Type move:** records moved to `Proto.Internal.Method` / `Proto.Internal.Message`, descriptor as a type parameter so `Idempotency(..)` stays in `Proto.Method`. `Proto.Method.Method` and `Proto.Message.Message` are now aliases. Every public signature unchanged.
- **Kernel trap:** a single `Bytes.width` anywhere in the generic path pulls in elm/bytes' whole kernel, encoders included.

Notes example, `codec=json`:

| build | minified | gzip |
|---|---:|---:|
| baseline dfe7d38 | 77,210 | 25,477 |
| run 2's head, before this leg | 86,001 | 28,177 |
| **after this leg** | **78,787** | **26,029** |

- No `Proto.Binary`, `Proto.Bytes` or elm/bytes code remains in the JSON-only build, kernel included.
- **The +552 B is not noise:** ~172 B run-time codec setting dispatch (`MissingCodec`, binary lookups, answer guard); ~100 B `Any`'s binary-aware payload; ~280 B `Rpc.Body`'s bytes kind, string-vs-bytes `Expect` choice, the `MissingCodec` message. Zero would need the codec chosen where the method is built rather than as a `Transport` setting: a different public shape.
- **`codec=both` still works:** proto live leg 98 cases pass; Connect suite `CODEC_PROTO` 52/56 halves, 51/56 `sendTraced` (as run 2); JSON legs unchanged (40/40, 39 + 1).
- **Correction to run 2.** `SizeBinary` grew 3.4 KB gzip after run 2's measurements (14,663 → 18,037 B): the binary `Any` writer's conversion of well-known JSON forms reaches `Proto.Json` and `Proto.Timestamp` from every binary program. Corpus binary codecs are now 10.5 KB gzip vs JSON's 9.2 KB, overturning run 2's "binary is smaller once gzipped". Not fixed.

## 2. Merge and the conformance tally
- **Generated shape:** `mergeFooBytes : Foo -> Proto.Binary.Decoder Foo` = `Proto.Binary.merge step finish`; `decodeFooBytes = mergeFooBytes defaultFoo`; `embedded encode merge default`; `fieldInto` reads a singular message field or oneof message member into the value read before it; `insertBool` makes a later bool-map entry replace the earlier; recursion wrappers get `mergeX_Bytes` via `Proto.Binary.map`.
- **Deviation, deliberate:** the brief said a packed run for a singular scalar takes its last element. protobuf-go does not: every singular consumer returns `errUnknown` on a wire-type mismatch (`internal/impl/codec_gen.go`, v1.36.12). Every field helper now takes the record and a mismatched wire type is skipped as unknown (before: failed the whole decode).
- **Q1 decided: opaque `Proto.Binary.Decoder a`.** `--optimize` compiles it to `identity`, zero cost. Defined in `Proto.Internal.Binary` (import cycle); package site shows the internal name, as for `Any`.
- **Not merged:** well-known types held as Elm values (Timestamp, Duration, Struct, Value, ListValue, FieldMask, Any). Wrappers do merge.
- **Protobuf conformance:** the 5 merge cases pass and left `failure_list.txt`. **1,413 / 1,468** (was 1,408); Required 1,099/1,135; Recommended 314/333; binary→binary Required 480/482, Recommended 216/216 (the 2 left: unknown fields not kept).
- **Elm oracle:** 1,752 round-trip tests, all byte-identical.
- **Speed** (interleaved runs; noise ±10 %): binary decode corpus 8.41/8.51 → 8.91/8.89 µs (+5 %), 1,000 leaves 901/896 → 938/935 µs (+4 %); encode unchanged. First build was +19 % because `embedded` applied the merge eagerly; fixed.
- **Size:** `SizeBinary` +303 B gzip.

## 3. Comparison with elm-protocol-buffers (`spike/COMPARISON.md`)
Versions: eriktim/elm-protocol-buffers 1.2.0; protoc-gen-elm 4.0.4 (npm, `--ignore-scripts`, gitignored `spike/compare/npm`, integrity sha512-at4f…qDBg==); elm-protoc-utils 2.3.0.

**What protoc-gen-elm cannot take:** output does not compile for a negative enum value (negative literal pattern), a `bool`-keyed map (`Dict Bool v`), an aliased enum (duplicate patterns). Both sides generated from the corpus with those removed; 130 of 140 samples remain.

**Size** (program minus its no-codec counterpart, minified / gzip):

| codecs | elm-connect | elm-protocol-buffers |
|---|---:|---:|
| binary | 40,326 / 10,618 | **29,124 / 7,167** |
| binary, ours with the `Any` writer's JSON conversion stubbed | 30,028 / 7,329 | 29,124 / 7,167 |
| JSON | **36,229 / 10,568** | 41,204 / 11,305 |
| both | **60,354 / 16,148** | 64,115 / 16,826 |

**Speed** (µs per input, ours / theirs):

| inputs | binary decode | binary encode | JSON decode |
|---|---:|---:|---:|
| corpus | **7.66** / 8.60 | **4.28** / 10.58 | 4.65 / **2.72** (81 inputs) |
| Scalars | 9.57 / **7.42** | **3.39** / 5.46 | 6.10 / **3.07** |
| Repeated | 8.59 / **7.46** | **4.09** / 7.42 | – |
| 1,000 leaves | **888** / 3,398 | **668** / 2,410 | 475 / **230** |

- Their binary decode wins on 64-bit-dense messages (Scalars −22 %, Repeated −13 %); likely cause, not isolated: our exact decimal text for 64-bit (`int64=string`).
- On 1,000 leaves they are 3.8x slower (append each element with `++`).
- Their JSON decoders are 1.6–2.7x faster, partly by leniency: `maybe` turns a malformed field into its default.
- They write every default: output 15 % larger raw.

**Correctness** (protobuf suite, same 1,468 cases): ours 1,413; theirs 585. binary→binary Required 480 vs 463. Their main failures: bools decoded through 32-bit ops; no merge; field number 0 accepted; byte-exact Recommended fail (defaults written); **every JSON output** fails (unset `Value` written as `null`); **nearly every JSON input** fails (repeated fields must be present; same bug rejects 49 of 130 corpus samples' canonical JSON).

**Verdict:** do not depend on it (its `Decoder`, `Encoder`, `Int64` would enter our public API; its majors would force ours; we would take on its bugs). Borrow one idea: open enums (`Unrecognized_ Int` keeps an unknown enum number; ours reads the zero value). Close our own gap: make the `Any` writer's JSON conversion DCE-able; that removes nearly all of the binary size difference (within 2 % once stubbed).

## 4. gRPC-Web, unary (`spike/grpc-web`)
**Shape:** a third transport, `Rpc.Transport.grpcWeb`, not a Connect option. Shares only the URL; GET, JSON codec and `withMaxGetUrl` are ignored. Messages always protobuf binary; a JSON-only method gets `MissingCodec "proto"`, nothing sent.
- **Request:** POST of one framed message (5-byte envelope), `X-Grpc-Web: 1`, `grpc-timeout` from the timeout (ms rounded up; `S`/`H` past eight digits). Retry budget rewrites `grpc-timeout` as it rewrites `Connect-Timeout-Ms`.
- **Content type lives on the body:** elm/http joins a `Content-Type` header with the body's own type, so `Rpc.Body` gains `bytesAs` and `contentType`.
- **Answer:** a body's trailers frame wins over headers; a body-less 200 is trailers-only (status in headers); `grpc-message` percent-decoded; `grpc-status-details-bin` decoded as `google.rpc.Status` into details; `Source` is `GrpcTrailers` (already reserved) for body trailers, `GrpcHeaders` for trailers-only; body trailers reach `Rpc.Trace` as `trailer-` entries.
- **Text mode** (`application/grpc-web-text`): not built; ~30 lines; NOTES says how.

**Oracle results:**
- **Notes server:** 22/22 live cases (success, errors with details, retry, five ways of sending, both size limits, headers and `grpc-timeout` on the wire, timeout). The two error faults give **identical code, message and detail bytes** over Connect (proto codec) and gRPC-Web; only `Source` differs (`ConnectBody` vs `GrpcHeaders`; connect-go answers unary errors trailers-only).
- **Connect suite, gRPC-Web client cases:** 67/85 halves, 77/85 `sendTraced`. Remaining (`spike/live-both/known-failing-grpcweb*.txt`): 4 malformed answers (we give `BadResponse`/`internal` where the suite wants `unimplemented`/`unknown`; same policy as Connect); 2 sub-format cases (harness builds requests from JSON; binary writer sends an `Any` of a non-well-known message with type URL alone: the codec-registry gap); 2 cancellations `sendTraced` cannot make (known); halves only, 12 cases needing body trailers (no public reader outside the trace).

**Sizes** (minified / gzip):

| program | before | after |
|---|---:|---:|
| notes `codec=json` | 78,787 / 26,028 | 79,497 / 26,225 (+197 B gzip) |
| notes `codec=both`, Connect | 103,380 / 32,929 | 107,262 / 34,047 (+1,118 B gzip) |
| notes `codec=both`, `grpcWeb` | – | 107,309 / 34,064 (+17 B over Connect) |

A JSON-only program pays 197 B gzip for the transport's dispatch. A program with binary codecs pays 1.1 KB gzip for gRPC-Web whether or not it uses it, because every `withBinary` method carries the closures; avoiding that needs an opt-in decorator or generator option (a transport is data and cannot bring code).

**Server streaming over gRPC-Web, beyond `spike/streaming`'s envelope framing:** the stream ends with a trailers frame (text parsed into a status) rather than an end-stream message; `grpc-status-details-bin` decoded in Elm; a stream may end trailers-only; `grpc-timeout` replaces `Connect-Timeout-Ms`. This branch's `frames`, `trailerLines`, `settle` are the Elm half.

## 5. Updated 1.0 reservation list
**Reserve before 1.0:** option `codec=json|binary|both`; the `*Bytes` suffix and the `merge` prefix in `naming.rs` plus a clash diagnostic (not built); `Rpc.Error.Reason.MissingCodec`; `Proto.Any.Problem.Binary`; the opaque `Proto.Binary.Decoder` in its merge-capable form; `Proto.Method.Method` and `Proto.Message.Message` becoming aliases of internal unions (`elm diff` would call that a major against a published version, so before the first Elm publish); `Rpc.Body.toText` meaning "text only" and `contentType`'s meaning; **new:** an `Unrecognized` constructor on generated enums (open enums) — decide before 1.0, adding it later breaks exhaustive `case`s; `Rpc.Error.Source.GrpcTrailers` is now actually given, so it must stay.

**Stays additive:** `Rpc.Transport.grpcWeb` and the internal `GrpcWeb` constructor; `Rpc.Body.bytesAs`, `contentType`; `Proto.Binary.merge`, `fieldInto`, `insertBool`, `map`; the `withBinary` readers; `withCodec`, `Rpc.responseBytes`.

## What was not done
- DCE criterion: notes +552 B gzip over baseline, not within noise. The `Any` writer's JSON conversion still costs every binary program 3.3 KB gzip.
- Merging well-known types; keeping unknown fields; a codec registry; `NullValue` support.
- gRPC-Web text mode; a public reader of body trailers; mapping malformed answers to the suite's expected codes.
- Faster JSON field reading (protoc-gen-elm's output reads JSON 1.7x faster); open enums.
- Envoy not run. gRPC-Web tested from Node only; browser CORS (exposing `grpc-status`) untested. `elm diff` not run.

## Files
- Notes/measurements: `spike/NOTES.md`, `spike/measurements-run3.md`, `spike/COMPARISON.md`, `spike/protobuf-conformance/tally-v32.0-rc2-merge.md`.
- Comparison tooling: `spike/compare-{gen.sh,bench.js,size.sh,attr.py}`, `spike/compare-harness/`, `spike/compare-protobuf/`.
- gRPC-Web runtime/tests: `src/Rpc/Internal/{GrpcWeb,Binary}.elm`, `src/Proto/Internal/{Method,Message,Binary}.elm`, `tests/Rpc/GrpcWebTest.elm`.
- gRPC-Web live cases/suite config: `conformance/live/cases/grpcweb.json`, `spike/live-both/{conformance-grpcweb.yaml,known-failing-grpcweb*.txt,run.sh}`.
