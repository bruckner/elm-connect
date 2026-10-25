# Measurements: binary codecs (run 2, at the leg-1 head f95d140)

Same setup as `baseline.md`: Elm 0.19.2 `--optimize`, terser 5.36.0
`--compress --mangle`, gzip -9 (`spike/measure.sh`); speed in Node 24.21.0,
50 rounds, median of 11, one process at a time under `spike/timeout.sh`.

## Size

| program | optimized | minified | gzip |
|---|---:|---:|---:|
| `SizeNull` (no codecs; JSON text echo) | 66532 | 16822 | 5700 |
| `SizeJson` (every JSON codec, default options) | 196079 | 48068 | 14872 |
| `SizeNullBytes` (no codecs; base64 → Bytes → base64 echo) | 86321 | 22851 | 7569 |
| `SizeBinary` (every binary codec, `codec=binary`) | 223881 | 51751 | 14663 |
| `SizeBoth` (every JSON and binary codec, `codec=both`) | 342975 | 80904 | 23486 |
| **JSON codecs (SizeJson − SizeNull)** | **129547** | **31246** | **9172** |
| **binary codecs (SizeBinary − SizeNullBytes)** | **137560** | **28900** | **7094** |
| **both (SizeBoth − SizeNullBytes)** | **256654** | **58053** | **15917** |

Unminified attribution (`attr.py`, `codecs.py`): generated codecs JSON
50811 / binary 76395 (`codec=binary`) / 50274 + 75789 (`codec=both`);
runtime `Proto.Json` 40945, `Proto.Binary` 42433. The binary programs drop
`Proto.Timestamp` (8440: RFC 3339 text is JSON-only) and most of
`Proto.Duration`, and add `Proto.Bytes` (7019) and elm/bytes (7546).

Generated codecs per message, unminified, under `codec=both` (`permsg.py`):

| message | JSON | binary |
|---|---:|---:|
| Across | 1637 | 3569 |
| Choice | 5717 | 7250 |
| Everything | 2595 | 10806 |
| Kind | 672 | 414 |
| Leaf | 741 | 1138 |
| Maps | 5588 | 8771 |
| Names | 3100 | 3673 |
| Optionals | 3300 | 4328 |
| Outer | 2792 | 5633 |
| OuterMode | 571 | 372 |
| Repeated | 3492 | 5276 |
| Scalars | 4454 | 5824 |
| Tree | 2415 | 5708 |
| WellKnown | 4745 | 6185 |
| Wrappers | 6797 | 4688 |
| other | 1658 | 2154 |
| total | 50274 | 75789 |

The notes example (`Main`, JSON transport throughout):

| build | optimized | minified | gzip |
|---|---:|---:|---:|
| baseline, dfe7d38 (`baseline.md`) | 298401 | 77210 | 25477 |
| this head, `codec=json` (committed bindings) | 322866 | 84428 | 27686 |
| this head, `codec=both` (`spike/notes-both`) | 384671 | 98793 | 31594 |

The second row is the cost of the transport path itself to a program that
never sends binary: +24 KB optimized, +7.2 KB minified, **+2.2 KB gzip
(+8.7 %)**. `Rpc.send`/`task` reach `sendBytes`, `toResultBytes`, the GET's
base64 and the trace's `bodyBase64` statically, so DCE keeps them, with
`Proto.Bytes` (2755) and elm/bytes (4796). The third row adds the
generated binary codecs and `Proto.Binary` the `withBinary` decorators
reach even though no call uses them: +3.9 KB gzip more.

## Speed and wire bytes

Inputs are prepared in `init`; the time is the update the `go` port runs
(`spike/codec-bench2.js`, `spike/codec-harness/src/Bench2.elm`). JSON times
include `JSON.parse`/`JSON.stringify`; binary times start and end at
`Bytes`. elm/http's handoff of an `arraybuffer` answer is
`new DataView(buffer)`, timed alone at 0.03 µs; XHR sends the encoder's
DataView as it is. The JSON columns reproduce `baseline.md` (8.31 vs 8.24 µs
corpus decode, 443.88 vs 444.33 µs on 1,000 leaves). Ratio = binary / JSON.

| inputs | n | JSON decode µs | binary decode µs | ratio | JSON encode µs | binary encode µs | ratio | JSON raw/gz B | binary raw/gz B |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| corpus, all | 140 | 8.31 | 7.78 | 0.94 | 2.35 | 5.01 | 2.13 | 30320/23261 | 10806/12218 |
| codec.v1.Scalars | 18 | 5.99 | 9.95 | 1.66 | 1.61 | 3.89 | 2.42 | 5057/3423 | 1575/1541 |
| codec.v1.Optionals | 8 | 2.72 | 2.64 | 0.97 | 1.11 | 1.21 | 1.09 | 857/938 | 226/353 |
| codec.v1.Repeated | 8 | 5.45 | 8.70 | 1.60 | 1.68 | 4.52 | 2.70 | 2115/1789 | 644/777 |
| codec.v1.Maps | 8 | 13.59 | 17.84 | 1.31 | 4.73 | 10.46 | 2.21 | 3844/2716 | 1526/1586 |
| codec.v1.Choice | 20 | 2.10 | 0.97 | 0.46 | 0.40 | 0.73 | 1.81 | 780/1168 | 287/654 |
| codec.v1.Names | 10 | 2.35 | 2.17 | 0.92 | 0.63 | 1.17 | 1.85 | 833/1001 | 264/444 |
| codec.v1.Outer | 8 | 2.63 | 2.36 | 0.90 | 0.98 | 1.71 | 1.74 | 906/809 | 216/377 |
| codec.v1.Tree | 10 | 12.85 | 6.39 | 0.50 | 3.56 | 5.78 | 1.62 | 1970/1340 | 695/868 |
| codec.v1.WellKnown | 8 | 8.37 | 15.45 | 1.84 | 3.64 | 12.89 | 3.54 | 3456/2427 | 1981/1795 |
| codec.v1.Wrappers | 18 | 3.84 | 6.71 | 1.75 | 1.02 | 3.54 | 3.46 | 2765/2493 | 1002/1177 |
| codec.v1.Across | 8 | 2.67 | 3.07 | 1.15 | 0.90 | 1.83 | 2.02 | 901/860 | 222/382 |
| codec.v1.Leaf | 8 | 0.56 | 0.54 | 0.96 | 0.32 | 0.55 | 1.74 | 190/350 | 76/232 |
| codec.v1.Everything | 8 | 47.42 | 31.82 | 0.67 | 12.13 | 20.17 | 1.66 | 6646/3947 | 2092/2032 |
| Repeated, 1,000 leaves | 1 | 443.88 | 854.89 | 1.93 | 259.08 | 720.67 | 2.78 | 32742/5131 | 14869/3127 |

Wire bytes: corpus JSON per message is the canonical text; binary is
prost-reflect's deterministic encoding. gzip is per payload, so for small
messages its ~20-byte header dominates.

## The two encoder/decoder experiments (run-1 Q2, Q3), 1,000 leaves

experiments on the 1,000-leaf input (µs per input):
  encode, generated (delimited copies each leaf): 704.98
  encode, size function per leaf (no copy):       659.72
  decode, leaves field, codec built per read:     811.96
  decode, leaves field, one top-level codec:      801.63

ArrayBuffer -> DataView handoff: 0.03 µs (true)

- **Size function vs copy (Q2):** a hand-written `sizeLeaf` that lets the
  encoder write each leaf's length without encoding it first saves 6 %
  (705 → 660 µs). The copy is not where the time goes: building the
  `Bytes.Encode.sequence` trees and varint lists is. A generated `size*` per
  message (and a size per codec) would add code to every message for 6 %.
  **Kept the copy.**
- **Hoisting (Q3):** one top-level `Codec` per message instead of one built
  at each field read saves 1 % (812 → 802 µs), within noise. A hoisted codec
  of a recursive message compiles and round-trips (`HoistCycle.elm`: a
  top-level codec whose decoder refers back to it through the step lambda).
  **Kept the use-site form** (no new generated names).
