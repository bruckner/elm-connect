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
