# Contributing to elm-connect

Thanks for helping. Everyone taking part follows the
[Code of Conduct](CODE_OF_CONDUCT.md). Questions go to an issue, as
[SUPPORT.md](SUPPORT.md) describes; security problems go through
[SECURITY.md](SECURITY.md), never a public issue.

An agent changing this repository starts with [AGENTS.md](AGENTS.md),
the working agreement; [ARCHITECTURE.md](ARCHITECTURE.md) maps the code.

## Proposing a change

Open an issue before a change of shape: anything that changes the
generated code, the runtime package's exposed API, an option, a
diagnostic, or a decision recorded in [`docs/design.md`](docs/design.md).
Agreeing on the shape there is cheaper than reworking a pull request.
Check the roadmap (`docs/roadmap.md`) first; it says which features are
planned and which would need a major release. A bug fix, a
documentation fix or a test can go straight to a pull request.

## Getting set up

[`mise.toml`](mise.toml) pins the whole toolchain: Rust, Elm,
elm-format, elm-test-rs, node, just, zizmor, gitleaks and cargo-deny,
and Go, buf and func-e (which fetches Envoy) for the live suite. The Rust it pins is also the
workspace's minimum supported Rust version (`rust-version`): the MSRV
is the pinned toolchain, a pull request that moves the pin moves the
MSRV with it, and its release note says so. From the repository root:

```sh
mise install    # install the pinned toolchain
just check      # run the gate
```

`just` with no arguments lists every recipe.

[`mise.lock`](mise.lock) records each tool's exact version and, for
every tool but Rust (which rustup verifies) and elm-test-rs (an npm
package), the URL and SHA-256 of its download on Linux and macOS, x64
and arm64; mise refuses a download that does not match. After moving a
pin in `mise.toml`, run `mise lock` (with `GITHUB_TOKEN` set, or
GitHub's API rate limit leaves entries out) and commit both files; CI installs
with the mise release named in `.github/workflows/ci.yml`, so move that
too when you upgrade mise. `mise lock` writes every platform's entries;
`mise install`, the setup step above included, rewrites `mise.lock` for
the platform it runs on and drops the other platforms' entries for the
Elm compiler (which `mise.toml` configures per platform), so a diff of
`mise.lock` that removes another platform's entry comes from the wrong
command: `git checkout mise.lock` undoes it.

Cargo builds into the worktree's own `target/`, and the live suite's
binaries go under it too. Keep it that way with several worktrees of the
repository: give each its own `target/` and do not set
`CARGO_TARGET_DIR` to a directory they share. A shared directory lets
two worktrees' builds produce test binaries of the same names, so one
worktree's `just bless` can run against the other's generator and
rewrite the corpus with output that is not its own.

## The gate

`just check` runs formatting checks (`cargo fmt`, `elm-format
--validate`), `cargo clippy` with warnings as errors, the Rust tests
(the conformance corpus among them, see
[`conformance/README.md`](conformance/README.md)), the runtime
package's build and Elm tests, a [zizmor](https://docs.zizmor.sh)
audit of the GitHub Actions workflows and the Dependabot configuration, a
[gitleaks](https://gitleaks.io) scan of the commit history for secrets,
[cargo-deny](https://embarkstudios.github.io/cargo-deny/) (`just deny`:
security advisories, licenses, duplicate versions and sources of the
Rust dependencies, under `deny.toml`), and `cargo package` (`just
package`), which builds each crate from its packaged files alone. Cargo
packages only committed crates, so run the gate after committing.
CI runs the same recipe on
Linux and macOS for every pull request and every push to `main`, so a
green local `just check` is the bar for opening a PR. Formatting in the
gate is check-only; `just fmt` fixes it.

`just live` runs the runtime against the example server
(`conformance/README.md`, "Live verification"): it regenerates the
example's code and fails on drift, runs the live cases and the route
fixtures, runs the Connect conformance suite, and builds the browser
example. It is outside the gate, since it needs Go and the Buf Schema
Registry; CI runs it as its own job, so run it before a PR that touches
the runtime's sending, the service modules, `examples/notes/` or a
README snippet's file.

`just example-notes` builds the browser example and serves it with the
API at `http://127.0.0.1:8080` (`just example-notes 127.0.0.1:9000` for
another address); `examples/notes/README.md` walks through it.

The code blocks of the README, the `docs/` guides and the walkthrough
are excerpts: a block's fence names its file (`` ```elm examples/notes/elm/src/Api.elm#wrapper ``),
and `just snippets`, part of the gate, checks each against it. Change
the file, then copy the region into the document; `examples/check-snippets.sh`
documents the forms.

## Branches and pull requests

Work on a branch off `main` and open a pull request; nothing lands on
`main` directly. A repository ruleset enforces this: `main` takes only
merge commits from pull requests whose checks pass, and cannot be
force-pushed or deleted. Keep each commit one logical change, so the history
reads as a sequence of reasons.

Keep the branch's own history linear. When `main` moves, rebase the
branch onto it and push with `git push --force-with-lease`; do not merge
`main` into the branch. Squash fixups into the commit they fix before
asking for review, so each commit still reads as one change.

A pull request carries, besides the change itself (the
[pull request template](.github/PULL_REQUEST_TEMPLATE.md) lists them):

- a passing `just check`, and `just live` where the change touches what
  it covers (see "The gate");
- tests for the behaviour it adds or fixes;
- a release-notes fragment under [`changelog.d/`](changelog.d/README.md)
  for each user-visible change;
- an update to `docs/design.md` wherever a statement there becomes true
  or false, and to the README or the page under `docs/` that describes
  the behaviour;
- if generated code changes, the conformance corpus re-blessed with
  `just bless` ([`conformance/README.md`](conformance/README.md)) and its
  diff reviewed line by line: the corpus is how a reviewer sees what
  users will get.

The maintainer reviews every pull request. Reviews are best effort, with
no fixed response time; if a pull request has heard nothing for two
weeks, a comment on it is a welcome reminder. Expect questions about
naming and the generated code's shape: they are part of the public
surface, and hard to change after a release. A pull request merges once
its checks pass and the review's points are settled.

No sign-off (DCO) is needed; the license terms below cover
contributions.

## The design

[`docs/design.md`](docs/design.md) is the design contract. It iterates
by pull request: a change to the design is a PR against that document,
and the PR discussion is the design record. Code that settles or moves
a decision updates the document in the same PR.

## Docs ride with the change

Whatever a change makes true lands in the same pull request as the
change, ideally the same commit: a design rule, a decision record, a
README paragraph, a `changelog.d/` fragment. A documentation-only PR is for work
that *is* the document, such as a design revision, not for catching up
on bookkeeping after the fact.

Release notes are collected as one file per change under
`changelog.d/`, so two pull requests never conflict over them;
`just changelog-fold` turns the files into the next release's section
of `CHANGELOG.md` when it is cut.

## Code comments

Comments say what the code does and the durable why; the history of a
change belongs in its commit message. A public doc string, on anything
in an `exposed-modules` module, is written for users: what the value
is, how you get one, and what it promises. A maintainer's rationale
(why a module is shaped as it is, which alternative lost) goes in an
`Internal` module's docs, in `docs/design.md`, or in the commit message.

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

## Releasing

The maintainer cuts releases; [`docs/design.md` §8.7](docs/design.md#87-releasing)
has the steps and what the release workflow does with a tag. A
contributor's part is the fragment under `changelog.d/` that a pull
request carries: the fragments are the raw notes the maintainer edits
into the next release's section of `CHANGELOG.md`.

## License

Unless you explicitly state otherwise, any contribution intentionally
submitted for inclusion in this work by you shall be dual-licensed under
MIT or Apache-2.0, as described in the [README](README.md#license),
without any additional terms or conditions.
