# Binary codec spike, run 1 report (plan steps 1–4)

Branch `spike/binary-codec` is pushed at **f165c5d**, five commits on top of dfe7d38. No PR, nothing merged.

## SHAs
| step | commit | subject |
|---|---|---|
| 1 | ebb50ab | Measure the JSON codecs' baseline |
| 2 | 4933e53 | Add Proto.Binary, the protobuf wire format |
| 3 | 053f2fc | Generate binary codecs under codec=binary\|both |
| 4 | fa361a1 | Check the binary codecs against prost-reflect |
| 3 fix | f165c5d | Reserve Proto.Binary among the runtime modules (naming.rs `RUNTIME_MODULES` must match elm.json) |

**Gate:** `just check` exits 101 at `test`. The one failing test is `elm-connect --test compile_errors::a_missing_import_names_the_include_paths_searched`. It depends on the environment, not the branch: it renders a help line containing two `CARGO_TARGET_TMPDIR` paths at width 400 and expects "with `-I`" on one line; this worktree's long path pushes the wrap point before "`-I`". The branch does not touch that code. With that test skipped every other gate passes: fmt-check, clippy, `cargo test --workspace` (283 passed), elm-check, snippets, changelog-check, zizmor, gitleaks, deny, license, `package`.

## Baseline (`spike/baseline.md`)
Setup: Elm 0.19.2 `--optimize`, terser 5.36.0, gzip -9, Node 24.21.0. The notes figures match the gen-routes baseline to the byte.

| program | optimized | minified | gzip |
|---|---:|---:|---:|
| notes example | 298401 | 77210 | 25477 |
| codec corpus, every JSON codec reachable (`SizeJson`) | 196079 | 48068 | 14875 |
| same worker without codecs (`SizeNull`) | 66532 | 16822 | 5700 |
| **corpus JSON codecs (difference)** | **129547** | **31246** | **9175** |

Unminified bytes: notes generated `encode*`/`decode*` 11832, `Proto.Json` 27169; corpus generated codecs 50811 (whole generated module 60494), `Proto.Json` 40945.

JSON speed, median of 11 runs at 50 rounds, including `JSON.parse`/`stringify`:

| inputs | n | decode µs | encode µs | raw B | gzip B (each) |
|---|---:|---:|---:|---:|---:|
| corpus, all | 140 | 8.24 | 2.37 | 30320 | 23261 |
| Scalars | 18 | 6.10 | 1.64 | 5057 | 3423 |
| Maps | 8 | 13.37 | 4.88 | 3844 | 2716 |
| Tree | 10 | 13.59 | 3.68 | 1970 | 1340 |
| WellKnown | 8 | 8.20 | 3.70 | 3456 | 2427 |
| Everything | 8 | 48.12 | 12.24 | 6646 | 3947 |
| Leaf | 8 | 0.53 | 0.23 | 190 | 350 |
| Repeated, 1,000 leaves | 1 | 444.33 | 255.27 | 32742 | 5131 |

Tooling under `spike/`: `attr.py`/`fn.py` from gen-routes-2; new `measure.sh`, `codecs.py`, `codec-bench.js` (vanilla JS); `timeout.sh` (macOS has no `timeout(1)`, perl alarm); `codec-harness/` worker app (needs elm-explorations/test as a direct dependency because `Generated.Codec.Data` imports `Codec.RoundTrip`).

## Proto.Binary
- **Size:** `src/Proto/Binary.elm` 1,430 lines, 36.4 KB source. Compiled size not yet measured (step 5).
- **API:** one opaque `Codec a` per scalar and well-known type, plus field helpers in the generated shape: decoding `message`, `field`, `repeated`, `mapEntry`, `skip`; encoding `implicit`, `optional`, `present`, `list`, `dict`, `boolMap`; `embedded` for message fields; `messageEncoder`/`messageDecoder` for a well-known method type; `decode`/`encode` for a whole body.
- **Additive runtime changes elsewhere:** `Proto.Duration.fromParts`/`toParts`.
- **Tests:** `tests/Proto/BinaryTest.elm`, **53 tests**, passing at `--fuzz 1000`: varint 32/64 at bounds, 10-byte negative int32, five-byte int32; 64-bit as text past 2^53 and `AsInt` range failures; zigzag incl. negatives; fixed/sfixed; double/float NaN/±inf/-0 by bits (implicit floats omitted at 0 and -0, written at NaN); UTF-8 strings, bytes in both holdings; nested messages; packed/unpacked repeats, packed overrun; map key order, defaults omitted in entries, out-of-order entries, bool map False first; oneof last-wins, Empty member; unknown fields of all four wire types skipped, groups fail, field 0 fails; empty message; six truncation points; Timestamp, Duration, Value/Struct/ListValue, Any, wrappers, FieldMask; fuzzed round trips. Fixtures from the encoding guide or Python.

## Generated shape (`codec=both`)
- **Option** `codec=json|binary|both`, default `json`; default output byte-identical (corpus unchanged; Eliza and notes regenerated and diffed clean). Header records `codec=…`. CLI `--codec`; plugin usage and unknown-option help name it (`options_invalid/expected/diagnostics.txt` changes).
- **Blessed case** `conformance/cases/codec_both`, inputs symlinked to `conformance/codec/*.proto`.
- **Sample:**

```elm
encodeLeafBytes : Leaf -> Bytes.Encode.Encoder
encodeLeafBytes value =
    Bytes.Encode.sequence
        [ Proto.Binary.implicit Proto.Binary.string 1 value.name
        , Proto.Binary.implicit Proto.Binary.int32 2 value.count
        ]

decodeLeafBytes : Int -> Bytes.Decode.Decoder Leaf
decodeLeafBytes =
    Proto.Binary.message defaultLeaf
        (\number wire value ->
            case number of
                1 -> Proto.Binary.field Proto.Binary.string (\v -> { value | name = v }) wire
                2 -> Proto.Binary.field Proto.Binary.int32 (\v -> { value | count = v }) wire
                _ -> Proto.Binary.skip wire value
        )
        identity

messageLeaf =
    Proto.Message.message encodeLeaf decodeLeaf defaultLeaf Codec.V1.Leaf.descriptor
        |> Proto.Message.withBinary encodeLeafBytes decodeLeafBytes
```

- **Methods:** `Proto.Method.method … |> Proto.Method.withBinary encReqBytes decResBytes`; a decorator, so it composes with gen-routes' positional `methodWith` unchanged.
- **`codec=binary`:** messages, oneofs and wrappers get no JSON codecs; enums keep theirs. Values built with `Proto.Message.messageBinary`/`Proto.Method.methodBinary`; their JSON encoder writes `null`, their JSON decoder fails.
- **Enums:** binary codecs are number conversions; negative numbers are `if`s in the `case` fallback (no negative literal patterns).
- **Size:** corpus package module 1,557 lines (json) → 3,556 (both); binary alone 2,935.
- **Brief deviation:** `decodeXBytes : Int -> Bytes.Decode.Decoder X`, not `Bytes.Decode.Decoder X` (see below). Alternatives in `spike/NOTES.md`.

## Corpus oracle
- `codec.rs`: each sample also carries `binary` (hex of deterministic bytes) and `binaryJson`. Bytes are prost-reflect's field encodings with map entries sorted in the Elm Dict's order (UTF-16 for strings, numeric for 32-bit keys, text order for 64-bit-as-text, bool False first). Samples canonicalised first: every singular Empty set, each Any's packed message re-encoded the same way, a Value with no kind given `null_value` (prost-reflect leaves JSON `null` as a kindless Value). A new Rust test checks prost-reflect decodes those bytes back to the canonicalised sample.
- Sets: `codec=both`, `both,int64=int`, `both,bytes=bytes`, `codec=binary`.
- `tests/Codec/BinaryRoundTripTest.elm`: decode binary, re-encode byte-identical (with and without unknown fields of all four wire types appended); where JSON exists, binary-decoded value writes the same JSON as JSON-decoded; JSON-decoded value encodes to the same bytes. prost reads our output via byte identity with the bytes the Rust test proves it reads back.
- **Result: 228 samples (140 wide, 88 narrow); 1,752 Elm tests, all pass, all byte-identical.** 187/228 identical to prost's own `encode_to_vec`; the other 41 differ only by HashMap order and the canonicalisation rules. Samples with a non-empty Any (10 wide, 5 narrow) skip the JSON→binary check: an Any decoded from JSON holds JSON and the binary encoder writes only its type URL. An Any decoded from binary holds the bytes (`InBinary`, `unpack` reports `BinaryOnly`) and JSON-encodes in Connect's error-detail form.

## Where elm/bytes hurt
- **No end-of-input, position or backtracking.** A decoder cannot tell where its input ends; every read returns its width and a loop counts down a length passed in. Hence the `Int` in the decoder signature and nested messages read in place.
- **No width for an Encoder.** No `getWidth`, so each nested message, packed run and map entry is encoded to `Bytes` and copied after its length prefix: one extra copy per nesting level. Alternative: generated `sizeXBytes` per message.
- **64-bit values** as two 32-bit halves: decimal text via 16-bit limbs divided by 10,000; text→bits with the carry in floating point (`//` truncates to 32 bits); range checks for `AsInt`.
- **Elm traps:** Float `x == 0` compiles to `!x` (true for NaN), so the NaN check goes first; elm-format rewrites `-0` to `0`; no negative literal patterns.
- **Per-byte decoding:** varints read one byte per `andThen` in a `loop`. Expected to cost speed; unmeasured (step 5).
- **Codec allocation:** each field's `Codec` record is built where used, one allocation per field read.

## Open questions for run 2
1. Accept `Int -> Decoder a`, or hide the length in a wrapper `Proto.Binary.Decoder a`?
2. Generated `size*` versus the copy in `delimited`: measure both on the 1,000-leaf payload.
3. Hoist codecs to one top-level `Codec` per message to avoid per-field allocation? Check against recursive messages.
4. Writing a JSON-holding Any to binary is lossy. Should `Proto.Any.pack` keep the binary when the Message has binary codecs; should well-known JSON forms convert to binary?
5. Reserve the `*Bytes` names? A message `FooBytes` beside `Foo` collides; nothing detects it today.
6. `codec=binary` only makes sense for Connect's proto codec. Should transport refuse JSON for such methods?
7. `Proto.WellKnown`'s typed values have no binary codecs yet.
8. Merge semantics not implemented: a singular message field arriving twice is replaced not merged; a packed run for a singular scalar fails; duplicate bool-map keys kept.
9. 64-bit Dict keys written in text order, unlike protobuf-go's deterministic order. Acceptable?
10. Step 5 needs SizeBinary/SizeBoth harness + binary bench. Step 6 and the notes-server/conformance legs (`Rpc.Body.bytes`, `withCodec`, answer path) still to do.
11. The `a_missing_import…` test depends on worktree path length; out of scope.
