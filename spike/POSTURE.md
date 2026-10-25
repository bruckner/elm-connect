# Maintenance posture for the editions forks

How elm-connect should carry editions support in protox, prost-reflect and
prost-types once the spike's result is wanted on `main`. Four shapes, argued
from what the two runs measured. Numbers are from 2026-10-25.

## What is being carried

| Crate | Pinned | Fork diff against the pristine import | Upstream state |
|---|---|---|---|
| prost-reflect | 0.16.5 | src +1316/−37 in 13 files, plus `wkt.rs` regenerated (+517/−187); tests +1145 in 47 files | main is the 0.16.5 commit (last push 2026-07-09); the operator's PR #204 (the `UnknownSyntax` panic, +41/−15) open since 2026-10-22, unreviewed |
| protox-parse | 0.10.0 | src +295/−11 in 7 files (tests.rs among them); snapshots +807/−8 in 34 files | main is the 0.10.0 commit (2026-10-07); issue #31 "Support for protobuf editions" open since 2023-11-30 |
| protox | 0.10.0 | src unchanged since prost-types carries the edition; tests +101 in 2 files | as protox-parse |
| prost-types | 0.14.4 | `protobuf.rs` and `compiler.rs` regenerated (+1372/−444), nothing hand-written | master 6 commits past 0.14.4 (2026-07-05), none in prost-types; PR #1347 "editions" (+2,688/−237, opened 2025-10-09) unreviewed, and it regenerates the same two files |

Two facts shape every option:

- **Breaking releases.** `Syntax::Editions` is a new variant of an exhaustive
  public enum, so prost-reflect's change is 0.17. The prost-types
  regeneration breaks struct literals (new fields) and drops
  `FileOptions.php_generic_services`, which protobuf removed, so it is 0.15
  (and prost, prost-build and prost-derive move in lockstep with it). protox
  takes the new prost-reflect, so it is 0.11. Downstream crates that build
  descriptor literals need edits (protox-parse needed five, prost-reflect three).
- **Order.** protox needs prost-reflect's release; prost-reflect, in the shape
  of this run, needs prost-types'. In run 1's shape (the edition carried in
  prost-reflect's private types and in protox's encoded bytes) prost-reflect
  and protox need no prost-types change at all.

## The rebase trial

The fork commits were replayed as one patch per crate onto upstream heads in
throwaway clones (scratch, not in the repository), with `git apply -p2` onto
the release commit, then `git rebase` or `git cherry-pick`:

| Onto | Result |
|---|---|
| prost-reflect `main` | no-op: main is the release (0 commits) |
| protox `main` | no-op: main is the release (0 commits) |
| prost `master` (6 commits past 0.14.4) | clean |
| prost-reflect PR #204 | 3 conflict hunks in one file, `build/names.rs`: both changes move the unknown-syntax error after the file is added, so the fork's side is the resolution (a minute's work). One semantic conflict: #204's new test asserts that a `syntax = "editions"`, `EDITION_2023` file is refused, which the fork now accepts; its data must become edition 2024 or an unknown syntax. With that, prost-reflect's suite passes on the result (against the vendored prost-types, with a `[patch]` in the clone). |
| prost PR #1347 head | 4 conflict hunks in `protobuf.rs`: both regenerate it. Resolution is regenerating from whichever `descriptor.proto` is newer, not merging hunks. |

Upstream churn in the files the forks touch, for scale: prost-reflect
0.16.0 → 0.16.5 (21 commits, 13 months) changed 7 of the 14 touched source
files by +130/−72; 0.16.4 → 0.16.5 touched none. protox 0.9.0 → 0.10.0 (12
commits, 16 months) changed 5 of the 7 touched files by +63/−7. prost-types'
generated files change only when someone regenerates them. So the rebase
cost per upstream release is small, minutes to an hour, and dominated by
the occasional semantic overlap such as #204's, not by textual churn.

## (a) Upstream first

Three PRs (the drafts are in the report): prost-types "regenerate from
protobuf 32.0", prost-reflect "support protobuf editions (edition 2023)",
protox "parse and compile edition 2023 files". The `[patch.crates-io]`
section lives until all three are released, in order, which in this run's
shape is three releases by two maintainers, two of them breaking.

- Evidence on pace: prost-reflect's last push was 2026-07-09 and #204 has
  waited three days unreviewed; protox released on 2026-10-07 and has had an
  editions issue open for almost three years; prost's #1347, the editions
  work that the prost-types regeneration is a slice of, has waited over a
  year unreviewed. The prost-types link is the slowest.
- `cargo install elm-connect`: unaffected until editions land on `main`; the
  feature waits for the releases. The `package` gate and the `crates` publish
  job keep working, because `main` keeps crates.io dependencies.
- Risk: the PRs may stall or be reshaped (#1347 does editions in prost-build
  too, and may want a different `Edition` API).

## (b) Forks published under our own names

`elm-connect-prost-types`, `elm-connect-prost-reflect`,
`elm-connect-protox-parse`, `elm-connect-protox`, depended on with
`package = "..."` renames so the code still says `prost_reflect`.

- `cargo install elm-connect` and the `crates` job work at once: every
  dependency is on crates.io, and `deny` passes unchanged.
- Cost: four more crates to own, release, keep secure and answer issues
  for, each a fork of someone else's work under a name that suggests it is
  ours; the rebase cost above per upstream release, for as long as upstream
  does not take the change; and a second copy of the prost-types and
  prost-reflect types in any build that also uses the real ones (a plugin
  user's build does not, but a library user of elm-connect-gen could).
- It is also the one option that publishes before upstream acts.

## (c) Permanent in-tree vendoring

What the spike does: `vendor/` path crates behind `[patch.crates-io]`,
deny-clean (a path is not a git source), recorded in THIRD_PARTY.md, the
fork diffs reviewable against pristine imports.

- `cargo install elm-connect` from crates.io cannot work: `[patch]` does not
  publish, so a published elm-connect-gen resolves the crates.io
  prost-reflect and does not compile. The `package` gate shows exactly this
  on the branch (`cargo package` verifies against crates.io and fails), and
  the release workflow's `verify` job runs the same `cargo package`, so a
  release cannot even be cut. Path dependencies without a registry version
  cannot be published at all.
- The variant that publishes is absorbing the forks' sources into a module
  of a published crate (elm-connect-gen), which is (b) without the names and
  with some 37,500 lines of someone else's code inside our crate.
- So (c) is a spike and development posture, not a release posture.

## (d) A git dependency with a deny exception

Point the three crates at git branches of public forks.

- Needs `deny.toml`'s `unknown-git = "deny"` relaxed, which policy forbids,
  and public forks, which this spike may not create.
- `cargo publish` refuses a crate with a git dependency, so `cargo install
  elm-connect` and the `crates` job fail as in (c).
- No advantage over (c) and worse supply-chain properties.

## Recommendation

**(a), upstream first, with the critical path cut to prost-reflect and
protox.** Keep editions off `main` until prost-reflect and protox have
released it; meanwhile the spike branch (shape (c)) is where it lives and is
rebased per upstream release, at the small cost measured above. Send the
prost-reflect and protox PRs in run 1's shape, which needs no prost-types
change (the edition rides in prost-reflect's private descriptor types and
protox's encoded bytes), and offer the prost-types regeneration to prost
separately, as a slice of #1347, off the critical path. elm-connect then
needs one new upstream release of each of two actively maintained crates,
not three releases in order, one of them of a crate whose editions PR has
waited a year. The plugin's raw-byte splice for the response's edition
fields, which a stock prost-types needs, is small and tested.

Fall back to (b) only if editions support must ship in a release before
upstream acts; it is the only option that publishes, and its cost is
ongoing.
