# Contributing to elm-connect

## Getting set up

[`mise.toml`](mise.toml) pins the whole toolchain: Rust, Elm,
elm-format, elm-test-rs, node and just. From the repository root:

```sh
mise install    # install the pinned toolchain
just check      # run the gate
```

`just` with no arguments lists every recipe.

## The gate

`just check` runs formatting checks (`cargo fmt`, `elm-format
--validate`), `cargo clippy` with warnings as errors, the Rust tests,
and an `elm make` of the conformance harness. CI runs the same recipe on
Linux and macOS for every pull request and every push to `main`, so a
green local `just check` is the bar for opening a PR. Formatting in the
gate is check-only; `just fmt` fixes it.

## Branches and pull requests

Work on a branch off `main` and open a pull request; nothing lands on
`main` directly. Keep each commit one logical change, so the history
reads as a sequence of reasons.

## The design

[`docs/design.md`](docs/design.md) is the design contract. It iterates
by pull request: a change to the design is a PR against that document,
and the PR discussion is the design record. Code that settles or moves
a decision updates the document in the same PR.

## Docs ride with the change

Whatever a change makes true lands in the same pull request as the
change, ideally the same commit: a design-doc status, a README
paragraph, a `CHANGELOG.md` line. A documentation-only PR is for work
that *is* the document, such as a design revision, not for catching up
on bookkeeping after the fact.

## Commit messages

Commits follow the seven rules from
[cbea.ms/git-commit](https://cbea.ms/git-commit/):

1. Separate subject from body with a blank line.
2. Limit the subject line to 50 characters.
3. Capitalize the subject line.
4. Do not end the subject line with a period.
5. Use the imperative mood in the subject line ("Add foo", not "Added
   foo").
6. Wrap the body at 72 characters.
7. Use the body to explain *what* and *why*, not *how*.

Reference durable things in a body (commits, files, sections of the
design) rather than issue or PR numbers alone.

## License

Unless you explicitly state otherwise, any contribution intentionally
submitted for inclusion in this work by you shall be dual-licensed under
MIT or Apache-2.0, as described in the [README](README.md#license),
without any additional terms or conditions.
