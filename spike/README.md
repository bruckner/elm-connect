# Measurement spike: the binary-canonical Any base

Scripts and outputs of the spike that built the base on this branch and
measured it against the typed-Any branch's head (023fa5d4). Not part of
the package. Copied from the earlier spikes' tooling: `loo.py`,
`attr2.py`, `to.sh` (as they were), `synth.py`, `gen.sh`, `make.sh`
(adapted: the CLI, the runtime and an `Any` field are parameters).

- `m1.sh`: synthetic packages, both CLIs, compile time and sizes.
- `size.sh`: one program's optimized, minified and gzipped bytes.
- `m2/`, `m3/`, `floor/`: the programs measured.
- `results/`: the raw outputs the report's tables come from.

## Part 2: the cache and the lenient registry

Built on this branch after the base, and measured against the base's head
(1dc99f6b). The generator is unchanged, so one CLI (the base's) generates
every program; only the runtime differs.

- `m4.sh a`: M4a, the floor and M2's (b) programs on the base, cache and
  lenient runtimes; `defdiff.py` lists the definitions that differ between
  two builds and `m4a-loo.sh` attributes them.
- `m4.sh c`: M4c, M2's program under the three bindings on the lenient
  runtime, with M2's floor on it.
- `m4/bench.sh`, `m4/bench.py`, `m4/bench.js`: M4b and M4e, M3's bench with
  the Any held as JSON and as binary, `pack` and one `Rpc.send`.
- `m4/details.sh`, `m4/details.py`: M4d, the six live cases' transcoded
  details unpacked through the generated google.rpc typed values.
- `results/m4*`: their outputs (`$WORK` stands for the scratch directory);
  `results/m4e-once.patch` is the single-encode change timed in M4e.
