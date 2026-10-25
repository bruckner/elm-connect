# Baseline: proto3 JSON codecs at dfe7d38

Elm 0.19.2 `--optimize`, terser 5.36.0 `--compress --mangle`, gzip -9
(`spike/measure.sh`); speed in Node 24.21.0 (`spike/codec-bench.js`, 50
rounds, median of 11); wire gzip is zlib's default level, each payload
compressed alone, as a response would be.

## Size

| program | optimized | minified | gzip |
|---|---:|---:|---:|
| notes example (`examples/notes/elm`, `Main`) | 298401 | 77210 | 25477 |
| codec corpus, every JSON codec reachable (`SizeJson`) | 196079 | 48068 | 14875 |
| the same program without codecs (`SizeNull`) | 66532 | 16822 | 5700 |
| **codec corpus's JSON codecs (SizeJson − SizeNull)** | **129547** | **31246** | **9175** |

Unminified attribution (`attr.py`, `codecs.py`):

| program | generated codecs (`encode*`/`decode*`) | generated module total | `Proto.Json` | runtime total |
|---|---:|---:|---:|---:|
| notes | 11832 | 25941 (Notes, Google, Routes) | 27169 | 107421 |
| codec corpus (`SizeJson`) | 50811 | 60494 | 40945 | 52882 (+ `Proto.Timestamp` 8440, `Proto.Duration` 3008) |

The notes figures match the gen-routes spike's baseline to the byte.

## Speed and wire bytes

Per input: `decode` is `Json.Decode.decodeString` of the generated decoder
(so it includes `JSON.parse`); `encode` is `Json.Encode.encode 0` of the
generated encoder (so it includes `JSON.stringify`). Corpus inputs are the
canonical form of every sample of `Generated.Codec.Data` (fixed seed,
64-bit values over their whole range). The large input is one
`codec.v1.Repeated` whose `leaves` hold 1,000 `Leaf { name = "leaf-<i>",
count = 7i }`.

| inputs | count | decode µs/input | encode µs/input | raw bytes | gzip bytes (each) |
|---|---:|---:|---:|---:|---:|
| corpus, all | 140 | 8.24 | 2.37 | 30320 | 23261 |
| codec.v1.Scalars | 18 | 6.10 | 1.64 | 5057 | 3423 |
| codec.v1.Optionals | 8 | 2.92 | 0.85 | 857 | 938 |
| codec.v1.Repeated | 8 | 5.67 | 1.69 | 2115 | 1789 |
| codec.v1.Maps | 8 | 13.37 | 4.88 | 3844 | 2716 |
| codec.v1.Choice | 20 | 2.25 | 0.38 | 780 | 1168 |
| codec.v1.Names | 10 | 2.37 | 0.62 | 833 | 1001 |
| codec.v1.Outer | 8 | 2.76 | 0.97 | 906 | 809 |
| codec.v1.Tree | 10 | 13.59 | 3.68 | 1970 | 1340 |
| codec.v1.WellKnown | 8 | 8.20 | 3.70 | 3456 | 2427 |
| codec.v1.Wrappers | 18 | 3.87 | 1.01 | 2765 | 2493 |
| codec.v1.Across | 8 | 2.76 | 0.86 | 901 | 860 |
| codec.v1.Leaf | 8 | 0.53 | 0.23 | 190 | 350 |
| codec.v1.Everything | 8 | 48.12 | 12.24 | 6646 | 3947 |
| Repeated, 1,000 leaves | 1 | 444.33 | 255.27 | 32742 | 5131 |

Small payloads gzip larger than they are (gzip's ~20-byte frame); the
corpus as a whole gzips to 77% of its size one payload at a time.

## Reproduce

    spike/timeout.sh 600 mise exec -- spike/measure.sh spike/out-baseline
    (cd spike/codec-harness && mise exec -- elm make src/Bench.elm --optimize --output=../out-baseline/bench.js)
    spike/timeout.sh 300 mise exec -- node spike/codec-bench.js spike/out-baseline/bench.js 50 11

`cargo test -p elm-connect-gen --test codec` (`just codec-gen`) must have
written `tests/Generated/Codec/` first.
