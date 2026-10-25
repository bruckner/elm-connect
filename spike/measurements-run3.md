# Measurements: binary codecs (run 3)

Same setup as `baseline.md`: Elm 0.19.2 `--optimize`, terser 5.36.0
`--compress --mangle`, gzip -9 (`spike/measure.sh`). Speed in Node 24.21.0,
one process at a time under `spike/timeout.sh`.

## Leg 1: DCE of the bytes path

The notes example (`examples/notes/elm`, committed `codec=json` bindings):

| build | optimized | minified | gzip |
|---|---:|---:|---:|
| baseline, dfe7d38 | 298401 | 77210 | 25477 |
| run 2's measurement (f95d140) | 322866 | 84428 | 27686 |
| run 2's final head (0a03c3b), before this leg | 329436 | 86001 | 28177 |
| this leg | 304507 | 78787 | 26029 |
| **this leg − baseline** | **+6106** | **+1577** | **+552** |

At this leg no definition of `Proto.Binary`, `Proto.Bytes` or elm/bytes
(nor elm/bytes' kernel) is in the notes build; before it, 2755 B of
`Proto.Bytes` alone and 4796 B of elm/bytes, unminified.

Residual, unminified per definition (`defdiff2.py`), and by experiment in a
scratch copy (gzip):

| removed in the scratch copy | gzip |
|---|---:|
| nothing (this leg) | 26029 |
| `Any`'s binary-aware payload, as at dfe7d38 | 25929 (−100) |
| and the codec dispatch (`MissingCodec`, binary lookups, answer guard) | 25757 (−172) |
| remaining over baseline: `Rpc.Body` bytes kind, `Expect`/`Resolver` choice, `MissingCodec`'s message and code, refactored Connect message | +280 |

`codec=both` still works: `spike/live-both/run.sh` passes (notes over
`application/proto`, 98 cases ok; Connect suite with `CODEC_PROTO` 52/56
through the halves, 51/56 with `sendTraced`, the same known failures as
run 2). JSON: Connect suite 40/40 and 39 + 1 known; notes, transcoding and
route fixtures under Vanguard and grpc-gateway all ok (Envoy not run).

The codec harness (worker programs without `Rpc`) is unchanged by the leg:

| program | head before | this leg |
|---|---:|---:|
| notes, `codec=both` | 102843 / 32764 | 102838 / 32787 |
| `SizeJson` | 48139 / 14905 | 48139 / 14909 |
| `SizeNullBytes` | 22851 / 7569 | 22851 / 7569 |
| `SizeBinary` | 62177 / 18037 | 62177 / 18035 |
| `SizeBoth` | 82221 / 23803 | 82221 / 23801 |

(minified / gzip). `SizeBinary` was 51751 / 14663 at run 2's measurement:
the binary `Any` writer's well-known JSON conversion, added later in run 2,
pulls `Proto.Json` (18.8 KB unminified) and `Proto.Timestamp` (6.5 KB) into
every binary program. Corpus binary codecs (SizeBinary − SizeNullBytes):
10466 B gzip, against JSON's 9209 (SizeJson − SizeNull).
