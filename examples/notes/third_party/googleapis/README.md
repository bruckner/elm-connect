# googleapis, vendored

The googleapis files the notes example's protos import, kept here so that
`buf generate` needs no network. `../../buf.yaml` lists this directory as
a module of the example's workspace.

- Module: `buf.build/googleapis/googleapis` on the Buf Schema Registry,
  Buf's curated copy of [googleapis](https://github.com/googleapis/googleapis)
- Commit: `c17df5b2beca46928cc87d5656bd5343` (the Justfile's
  `googleapis_module` pins it)
- Exported: 2026-10-15, unmodified
- Files: `google/api/annotations.proto` and `google/api/http.proto` (the
  HTTP rules `notes.proto` and `routes.proto` carry),
  `google/rpc/error_details.proto` (generated into `Google.Rpc` by
  `../../buf.gen.google-rpc.yaml`), and the module's `LICENSE`
- License: Apache License 2.0, Copyright Google LLC (`LICENSE`; each file
  carries its own header)

To refresh, from the repository root:

```sh
just protos-refresh
```

which runs `buf export` at the pinned commit with `--all` (for `LICENSE`)
and a `--path` for each file above, and copies the result here. To move the
pin, change `googleapis_module` in the Justfile and the commit and date
above, then run `just live`, which fails if the generated code changes.
