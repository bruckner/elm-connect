# Security policy

elm-connect is two things: a code generator (the `elm-connect` CLI and
`protoc-gen-elm-connect`, built on the `elm-connect-gen` crate) and an
Elm runtime package (`bruckner/elm-connect`). Both share one version
and are released together.

## Supported versions

Until 1.0.0, only the latest release receives security fixes; a fix
lands on `main` and ships in the next release. From 1.0.0 on, the latest
minor release is supported, and so is the previous minor release for
three months after its successor is published.

## Reporting a vulnerability

Please do not open a public issue. Report it privately through GitHub:
on the repository's **Security** tab, choose **Report a vulnerability**
(<https://github.com/bruckner/elm-connect/security/advisories/new>).
Say which component and version is affected, and include a proto, a
response body or a command that reproduces it if you have one.

What to expect:

- an acknowledgement within 7 days;
- an assessment, and a fix or a plan, as soon as the problem is
  understood; this is a one-maintainer project, so it is best effort;
- coordinated disclosure: we publish a GitHub security advisory with
  the fixed release, at the latest 90 days after your report unless we
  agree on another date with you. You are credited in the advisory
  unless you ask not to be.

## Verifying a release

A release is built from its tag, a commit on `main` named by the bare
version (`1.2.0`), by the repository's release workflow
(`.github/workflows/release.yml`), which checks out the tag afresh,
uses no caches, and builds with `--locked`, so with the dependency
versions `Cargo.lock` pins, under the Rust version the crates declare.
Release tags cannot be moved or deleted, and nothing is published
until the maintainer approves the run (design §8.7 in `docs/design.md`
has the whole process).

Two checks tie a downloaded archive to that build:

- `SHA256SUMS`, attached to the release, lists every archive's
  checksum: `sha256sum --check SHA256SUMS --ignore-missing` beside the
  downloaded archive.
- Every archive and `SHA256SUMS` carry a build-provenance attestation
  signed for the release workflow's run:
  `gh attestation verify <archive> --repo bruckner/elm-connect` checks
  that this repository's release workflow built the file, and from
  which commit.

The Elm package's `src/` is the tagged tree's: `elm publish` checks
that the tag on GitHub names the commit being published and that the
tree matches it, and the release workflow then builds the package's documentation from the tag
and compares it with the index's copy, failing the release if the
index did not store what was built.

[docs/install.md](docs/install.md#prebuilt-binaries) walks through the
download and both checks. A checksum or an attestation that does not
verify, or a package whose contents differ from its tag, is a security
problem: report it privately, as above.

## Scope

In scope for the generator:

- writing outside the output directory (`--out`, or protoc's and buf's
  `out`), or overwriting files it did not generate;
- generated Elm that does something the proto did not ask for, such as
  text from a proto (a name, a comment, an option value) escaping into
  code;
- a crash or a hang on a proto or descriptor set, including a hostile
  one.

In scope for the runtime package:

- request construction: a URL, header or method that a value in a
  request message can inject into or alter;
- handling of responses, including hostile ones: a hang, a freeze, a
  stack overflow, work out of all proportion to the response's size, or
  data from one part of a response surfacing where it does not belong.

Out of scope:

- the security of the server the client talks to, its authentication,
  and its CORS and CSRF policy;
- the transports a browser and elm/http provide;
- the example server under `examples/` and the test harnesses, which
  are not shipped;
- a generated client's behaviour when its generated modules have been
  edited by hand.
