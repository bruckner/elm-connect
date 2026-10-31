# Table-driven binary merge: spike report (2026-10-30)

Branch `spike/binary-merge` from `main` at 66781bf1. Numbers are the
deliverable; nothing here is meant to land as is.

**Setup.** Elm 0.19.2 (mise), the CLI built once from this checkout (debug).
Every build is a cold `elm make --optimize` (elm-stuff deleted first), a
300 s limit, wall time and peak RSS from `/usr/bin/time -l`
(`spike/make.sh`). Before each build the disk floor was checked (free space
stayed above 34 GB) and no cargo or rustc process was running. Variants
were built three times, interleaved round by round, so drift spreads over
all of them. Cells are **median (min–max)**. No build above n = 300 for
`binary` or `both`. Raw lines: `spike/results/*.txt`; tables come from
`spike/summarize.py`.

The synthetic package (`spike/synth.py`, H5's) gives message *i* a field
`parent` of type message *i − 1*. The package is therefore **one chain of
300 nested record types**: `Msg299` holds `Msg298`, which holds `Msg297`,
and so on down to `Msg0`. That shape turned out to explain the results
(extra runs below).

## 0. Ablation: what makes `both` slow (n = 300, chain)

`spike/ablate.py` replaces one section of the generated `both` module by
stubs of the same names and types.

| variant | wall s | vs `both` | peak RSS MB | optimized JS B |
|---|---:|---:|---:|---:|
| `json` | 3.29 (2.98–3.51) | | 4,224 (4,131–4,226) | 518,251 |
| `binary` | 4.20 (3.85–4.44) | | 4,123 (4,026–4,131) | 1,317,826 |
| `both`, as generated | **8.80** (8.35–9.42) | | 4,144 (3,910–4,391) | 1,770,131 |
| (a) merges stubbed | **5.46** (5.21–5.57) | −38 % | 4,484 (4,449–4,491) | 722,230 |
| (b) `binaryRegistry` = `Proto.Registry.empty` | 8.75 (8.47–8.75) | −1 % | 4,114 (3,936–4,154) | 1,770,131 |
| (c) message JSON codecs stubbed | 7.33 (7.16–8.25) | −17 % | 4,489 (4,372–4,602) | 1,390,856 |
| (d) `encode*Bytes` stubbed | 8.06 (7.82–8.30) | −8 % | 4,363 (4,352–4,509) | 1,458,912 |
| (e) `message*` values without `withBinary` (extra) | 8.51 (8.39–8.94) | −3 % | 4,535 (4,368–4,703) | 1,770,131 |

**Reading.** On this package the merge section is the largest single cost
of `both`: stubbing it saves 3.3 s of 8.8 (−38 %). The JSON codecs come
next (−17 %), the binary encoders after (−8 %). `binaryRegistry`, the one
expression that names every message, costs nothing (−1 %), and neither
does the binary half of the typed values (−3 %). The sections' savings add
up to about `both` minus `json`, and none of them is proportional to its
source size: the cost of a section grows with the size of what is around
it. Peak RSS does not move with any section (3.9–4.7 GB throughout). So
the merge is the largest share, but what makes everything expensive is
the extra runs' finding.

### Extra: the depth of the message types, not the size of the module

The same 300 messages with the `parent` fields rewired
(`SYNTH_PARENT`): `root` points every one at `Msg0` (no type nests more
than two deep); `chainK` starts a new chain at every K-th message. The
module's size does not change (2.09 MB for `both` in every shape).

| package (300 messages, one module) | `json` | `binary` | `both` | `both`, merges stubbed | `both`, table form |
|---|---:|---:|---:|---:|---:|
| one chain of 300 (H5's) | 3.02 (3.02–3.23) | 3.93 (3.89–3.95) | 8.52 (8.02–8.89) | 5.46 (5.21–5.57)¹ | 8.48 (8.27–8.93)¹ |
| chains of 100 | | | 1.78 (1.78–1.87) | | |
| chains of 30 | | | 1.04 (1.04–1.05) | | |
| chains of 10 | 0.67 (0.67–0.77) | 0.80 (0.80–0.80) | 0.95 (0.91–0.99) | 0.84 (0.83–0.86) | 0.99 (0.96–1.04) |
| every `parent` at `Msg0` | 0.68 (0.67–0.68) | 0.82 (0.80–0.82) | 0.85 (0.84–0.87) | 0.79 (0.76–0.79) | 0.86 (0.84–0.96) |

¹ from measurements 0 and 2. Peak RSS: 1.41–1.54 GB in every shallow
cell, 2.1 GB for chains of 100, 3.7–4.5 GB for the chain of 300.
`json` at **600** messages with every `parent` at `Msg0`: **0.84 s**
(0.84–0.96), 1.5 GB (H5: 25.1 s, 4.4 GB for the chain of 600).

With types at most ten deep, 300 messages under `both` compile in under
a second, `both` is 1.4× `json` (0.95 against 0.67 s), and the whole merge
section is worth 0.1 s. At a fixed 300 messages, the time above the
shallow floor grows about with the square of the chain's length once
chains are long (chains of 100 → 300: ×8.2 excess). That gives n³ for a
single chain of n, which is H5's "≈ n³" for `json` from 300 to 600. **The
superlinear growth, the 2.26× of `both` over `json`, and the 8 GB of
`binary` at 600 are all products of the synthetic package's 300-deep
chain, not of the number of messages, the module's size or the merge's
shape.** A real schema whose messages nest ten deep is in the bottom rows.

## 1. Source and formatting of the table form

Runtime: `Proto.Binary.mergeTable : List ( Int, Int -> a -> D.Decoder ( Int, a ) ) -> (a -> a) -> a -> Decoder a`
(additive; `src/Proto/Binary.elm`). It builds a `Dict Int` once (a
generated top-level value is evaluated once) and passes `merge` a step that
looks the field number up, skipping a miss. Every existing function stays.

`spike/to_table.py` rewrites each `merge*Bytes` keeping its arms'
expressions (the same helpers, the same setters, a oneof message member's
`case` for the member read before) and its finishing function:

```elm
mergeEntryBytes =
    Proto.Binary.mergeTable
        [ ( 1, \wire value -> Proto.Binary.field Proto.Binary.string (\v -> { value | memo = v }) wire value )
        , ( 2, \wire value -> Proto.Binary.field Proto.Binary.sint64 (\v -> { value | amount = v }) wire value )
        , ...
```

It also writes `flatcase`: today's `case`, each arm's expression on one
line, to separate the formatting from the structure. Every file was run
through elm-format; today's generated files are already elm-format's
output (unchanged by it). Bytes / lines of the `merge*Bytes` values
(definition and body; `spike/results/m1-source-size.md` has every row):

| module | today | flatcase | table | share of shrink that is formatting |
|---|---:|---:|---:|---:|
| synthetic, per message (300) | 3,001–3,102 B / 101–102 | 1,305–1,382 B / 36 | 1,102–1,179 B / 16 | 89 % |
| synthetic `binary` 300, module | 1,627,262 B | 1,111,286 B | 1,050,386 B (−35 %) | |
| synthetic `both` 300, module | 2,093,152 B | 1,577,176 B | 1,516,276 B (−28 %) | |
| `codec_proto` `Ledger/V1.elm`, 2 merges | 3,630 B / 117 | 2,119 B / 59 | 1,774 B / 38 | 81 % |
| — Entry (with a oneof message member) | 3,094 / 98 | 1,792 / 48 | 1,580 / 33 | |
| — GetEntryRequest | 536 / 19 | 327 / 11 | 194 / 5 | |
| `codec_both` `Codec/V1.elm`, 14 merges | 55,033 B / 1,697 | 26,238 B / 590 | 23,148 B / 274 | 90 % |
| — per message, min–max | 855–7,166 B | 437–3,188 B | 294–2,885 B | |

**Plainly: yes, the setter lambda survives elm-format on one line.**
elm-format keeps an application, a lambda or a record update on one line
when it is written on one line; it always breaks a `case` or a `let`. So
`(\v -> { value | name = v })`, and equally the proposal's
`(\v r -> { r | name = v })`, stay on one line. The only multi-line entry
is a oneof message member (its `case`). **But 81–90 % of the shrink is
formatting**: writing today's arms on one line (`flatcase`) already takes
a synthetic merge from 3,100 to 1,380 B; the table's structure takes it
to 1,175 B.

One finding about the proposal's shape: a point-free entry such as
`Proto.Binary.at 6 (... (Proto.Binary.embedded encodeEntryBytes mergeEntryBytes defaultEntry) ...)`
evaluates the codec while the top-level value is built, and Elm rejects
it for a self-referencing message ("The `mergeEntryBytes` value is defined
directly in terms of itself", checked on `Ledger/V1.elm`). Entries must
stay lambdas (as measured here) or the codec must be lazy.

## 2. Compile time of the table form (threshold: ≥ 25 % faster at 300)

The synthetic chain, today's module against `to_table.py`'s (and `flatcase`):

| n, codec | today | table | flatcase |
|---|---:|---:|---:|
| 100 `binary` | 0.76 (0.74–0.82) | 0.75 (0.74–0.76) | 0.75 (0.73–0.75) |
| 100 `both` | 0.79 (0.78–0.80) | 0.81 (0.81–1.01) | 0.82 (0.80–0.84) |
| 300 `binary` | 4.12 (3.92–4.37), 4,109 MB | 3.90 (3.75–4.05), 4,073 MB — **−5 %** | 4.05 (3.78–4.91) |
| 300 `both` | 9.12 (8.70–9.37), 4,083 MB | 8.48 (8.27–8.93), 4,394 MB — **−7 %** | 8.28 (6.85–8.42) |
| 300 `both`, chains of 10 (extra) | 0.95 (0.91–0.99) | 0.99 (0.96–1.04) — +4 % | |
| 300 `binary`, chains of 10 (extra) | 0.80 (0.80–0.80) | 0.83 (0.81–1.86) | |

Peak RSS at 100 is 1.44 GB in every cell; at 300 the table form is not
lower. Optimized JS is larger in the table form: 300 `binary` 1,317,826 →
1,424,017 B (+8 %), gzip −9 44,157 → 46,683 B (+5.7 %); 300 `both`
1,770,131 → 1,872,305 B, gzip 57,009 → 58,095 B.

**Verdict: fails.** −5 % and −7 % at 300, against a 25 % threshold, and
within the spread. Stubbing the merge out entirely saved 38 %, so what the
compiler spends there is the per-field closures and record updates, which
the table keeps; the `case` and its formatting cost nothing measurable.
On packages with shallow types the merge section is worth 0.1 s in total.

## 3. Decode speed (threshold: ≤ +10 %)

`spike/merge-bench.js` with `spike/codec-harness` (the codec spike's
Bench2, binary modes only): `conformance/codec` generated with `codec=both`
by this checkout, today's against `to_table.py`'s, on the codec spike's
corpus (its samples module, 140 inputs) and one `Repeated` of 1,000
leaves. Both programs in one process, interleaved: four passes alternating
which goes first, eleven timings each, 50 rounds (5 for the 1,000 leaves).
Before timing, each input decoded and encoded again was checked to give
the same bytes in both builds (all equal). Two full runs; µs per input,
the median (pass medians min–max):

| input | today, run 1 / 2 | table, run 1 / 2 | table vs today |
|---|---:|---:|---:|
| corpus, all (140) | 8.26 / 8.36 | 8.63 / 8.73 | **+4.4 % / +4.4 %** |
| Scalars | 9.65 / 9.90 | 10.03 / 10.30 | +3.9 / +4.1 % |
| Optionals | 2.63 / 2.65 | 2.72 / 2.75 | +3.1 / +3.7 % |
| Repeated | 8.83 / 8.62 | 9.10 / 9.03 | +3.1 / +4.8 % |
| Maps | 17.98 / 18.00 | 18.23 / 18.61 | +1.4 / +3.4 % |
| Choice | 0.99 / 0.98 | 1.04 / 1.08 | +4.4 / +9.4 % |
| Names | 2.07 / 2.10 | 2.17 / 2.18 | +4.6 / +3.9 % |
| Outer | 2.39 / 2.39 | 2.46 / 2.53 | +3.2 / +5.7 % |
| Tree | 7.48 / 7.59 | 7.68 / 7.71 | +2.7 / +1.5 % |
| WellKnown | 16.83 / 17.04 | 17.12 / 16.90 | +1.7 / −0.8 % |
| Wrappers | 7.15 / 7.15 | 7.16 / 7.38 | +0.2 / +3.1 % |
| Across | 3.03 / 3.13 | 3.14 / 3.18 | +3.6 / +1.7 % |
| Leaf | 0.62 / 0.64 | 0.66 / 0.67 | +6.0 / +4.1 % |
| Everything | 33.91 / 34.08 | 35.96 / 35.85 | +6.0 / +5.2 % |
| Repeated, 1,000 leaves | 844 / 878 | 881 / 894 | **+4.4 % / +1.8 %** |

Pass-to-pass spread within one program was 1–4 %. The program of the
bench grows 6,481 B optimized, 196 B gzipped, for its 14 messages.

**Verdict: holds** (+2 to +6 %, one message at +9.4 % once). Under the
threshold, so the sorted-list variant for small messages was not tried.

## 4. Module size versus module count

300 messages as one package against three packages of 100 (no references
between them; each package one chain of 100):

| codec | one module of 300 | three modules of 100 | ratio |
|---|---:|---:|---:|
| `binary` | 4.02 (3.85–4.38), 4,122 MB | 1.01 (1.01–1.02), 1,680 MB | 4.0× |
| `both` | 8.92 (8.34–9.54), 4,164 MB | 1.44 (1.43–1.46), 2,393 MB | 6.2× |

Read alone, that says split the module. But the split also cut the chain
from 300 to 100 deep. Holding the depth (extra, interleaved):

| `both`, 300 messages | wall s | peak RSS MB |
|---|---:|---:|
| one module, chains of 100 | 1.78 (1.78–1.87) | 2,097 |
| three modules of one chain of 100 | 1.49 (1.44–1.50) | 2,390 |
| one module, chains of 30 | 1.04 (1.04–1.05) | 1,502 |
| one module, every `parent` at `Msg0` | 0.85 (0.84–0.87) | 1,446 |
| three modules, every `parent` at `Msg0` | 0.70 (0.69–1.30) | 1,454 |

**Verdict: the lever is the depth of the types, not the module.** At equal
depth, three modules are 16–18 % faster than one (Elm compiles independent
modules in parallel), not several times. Splitting along the strongly
connected components (`emit/recursion.rs`) with aliases in the package
module would buy that 16–18 %, on packages that already compile in one or
two seconds. It would not shorten a chain: the chain's types reach across
modules as they do within one.

## Recommendation

**Close the roadmap entry with these numbers.** The table form saves 5–7 %
of compile time where compile time is large (a 300-deep chain), costs
4 % on packages with realistic depth, decodes 2–6 % slower, makes the
bundle 5–6 % larger gzipped, and 81–90 % of its source shrink is
formatting that today's `case` could have too. Module splitting buys
16–18 % at equal depth. Neither is worth a generator change.

Three corrections follow from the extra runs, for whoever next writes
about compile time:

- "`codec=both` takes 2.3× `codec=json` at 300 messages" (decisions.md, the
  roadmap, the interface spike's H5) holds only for the 300-deep chain;
  with types ten deep it is 1.4× and under a second.
- "`json` grows ≈ n³" and "`binary` needs 8 GB at 600" are the chain's
  depth: 600 messages of `json` with shallow types build in 0.84 s.
- A scale measurement should state the depth of its types; a synthetic
  package of independent or shallow messages (`SYNTH_PARENT=root` or
  `chain10`), plus one deep chain as the worst case, separates the two.

If a schema with very deep nesting turns up, the lever to study is how
the generated code expresses nested record types (the cost per message
grows with how many record types its type contains), not the codecs.

## Not run, and why

- **n > 300 for `binary` or `both`**: the cap. `json` at 600 ran with
  shallow types only (0.84 s); the chain of 600 is H5's figure.
- **The sorted-list variant** (measurement 3's fallback): the table was
  within the threshold.
- **The proposal's point-free entry form** was not timed: Elm rejects it
  for a self-referencing message (above), so it is not a candidate as
  written. The measured form keeps one lambda per entry.
- **elm-test and `just check`**: the runtime change is one additive
  function no test reaches; the decode bench's round-trip comparison
  checked the table form against today's on the whole corpus.
  `elm make --docs` passes.
- **Minified sizes**: no minifier is active in this worktree; sizes are
  `--optimize` output and `gzip -9` of it.
- One smoke build before the measured rounds ((a) at 9.28 s, the first
  build of the session) is not in the tables.
