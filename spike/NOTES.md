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
