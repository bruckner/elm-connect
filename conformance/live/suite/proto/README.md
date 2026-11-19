# Connect conformance suite protos, vendored

The `connectrpc.conformance.v1` protos of the
[Connect conformance suite](https://github.com/connectrpc/conformance),
kept here so that `buf generate` needs no network. `../buf.yaml` lists
this directory as the suite's module.

- Module: `buf.build/connectrpc/conformance` on the Buf Schema Registry
- Commit: `e6d2b1a1ebb247d28a8be5e1a763b0f0`, the one the registry labels
  v1.0.7, the release `../../fetch-conformance.sh` pins
  `connectconformance` to (the Justfile's `conformance_module` pins it)
- Exported: 2026-11-18, unmodified
- Files: the whole module, `connectrpc/conformance/v1/*.proto`, and its
  `LICENSE`
- License: Apache License 2.0, Copyright The Connect Authors (`LICENSE`;
  each file carries its own header)

To refresh, from the repository root:

```sh
just protos-refresh
```

which runs `buf export` at the pinned commit with `--all` (for `LICENSE`)
and copies the result here. To move the pin, change `conformance_module`
in the Justfile and the commit and date above, then run `just live`.
