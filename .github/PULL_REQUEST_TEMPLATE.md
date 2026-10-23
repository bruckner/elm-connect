<!-- CONTRIBUTING.md says what a pull request carries. Delete what does not apply. -->

## What

<!-- What the change does and why; link the issue it settles. -->

## Checklist

- [ ] `just check` passes locally (and `just live`, if the change
      touches the runtime's sending, the service modules,
      `examples/notes/` or a README excerpt's file).
- [ ] A release-notes fragment under `changelog.d/` for each
      user-visible change.
- [ ] `docs/design.md` updated where a statement became true or false.
- [ ] The conformance corpus re-blessed (`just bless`) and its diff
      reviewed, if generated code changed.
- [ ] The branch is rebased on `main`, with no merge commits.
