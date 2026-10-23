- `elm-connect gen --help` describes `--module-prefix` correctly: with
  `Api`, `notes.v1` becomes `Api.Notes.V1`. It said `Api.Notes` gave
  `Api.Notes.V1`, where it gives `Api.Notes.Notes.V1`.
- The links the binaries print, in `--help`, `elm-connect guide` and
  under a diagnostic, go to the docs at the binary's release tag
  (`blob/0.1.0/…`) rather than at `main`, so they describe the version
  installed.
- The help's examples write `--out generated` after the proto files, as
  the README and the guides do, rather than `-o src/Generated` before
  them, and the plugin's `--help` examples name a proto under its
  include directory with the googleapis include it needs.
- The `services::unbound_method` help no longer says Vanguard serves the
  implicit route itself: Vanguard v0.5 serves rules alone, and a Connect
  handler mounted beside it serves the route.
