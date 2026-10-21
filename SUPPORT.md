# Getting help

Ask in a GitHub issue: open a
[new issue](https://github.com/bruckner/elm-connect/issues/new/choose)
and pick **Question**. Search the existing issues first; your question
may have an answer already. The [README](README.md) and the pages under
[`docs/`](docs/) are the documentation, and
[`docs/diagnostics.md`](docs/diagnostics.md) explains every diagnostic
the generator reports.

A question is quicker to answer when it carries:

- the versions: the generator's (`elm-connect --version` or
  `protoc-gen-elm-connect --version`) and the Elm package's (from your
  `elm.json`), and whether you run the CLI, protoc or buf;
- the proto, or a minimal one that shows the problem;
- the options you pass (CLI flags, `--elm-connect_opt=`, or `opt:` in
  `buf.gen.yaml`);
- the generated code in question, or the diagnostic, as text;
- for a call that fails: the server, the transport (Connect or
  transcoding) and what the `Rpc.Error` says.

Bugs and feature requests have their own issue forms. Security
problems do not go in issues; see [SECURITY.md](SECURITY.md).

Answers are best effort: elm-connect is maintained by one person, and
there is no guaranteed response time.
