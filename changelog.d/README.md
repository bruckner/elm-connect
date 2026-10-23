# Release notes in the making

A pull request that changes what a user of the package or the binaries
sees adds one file here, named after its branch (`gen/unknown-rename`
becomes `gen-unknown-rename.md`), holding one or more `- ` bullets in
the register of [`CHANGELOG.md`](../CHANGELOG.md): what changed, as a
user meets it, and the old behaviour where it helps a reader deciding
whether to upgrade. A repository-only change adds nothing. No two
changes touch the same file, so there is nothing to conflict over.

These files are raw notes. When a release is cut,
`just changelog-fold <version>` gathers them, in file-name order, into
a `## <version> — <date>` section of `CHANGELOG.md` below Unreleased
and removes them; the maintainer then edits that section into the
release's notes, which the release workflow publishes as the GitHub
Release's text. `just check` holds each file to the form the fold
needs: bullets and their continuation lines only, with a trailing
newline.
