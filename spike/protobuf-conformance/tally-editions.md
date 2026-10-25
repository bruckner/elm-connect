# Protobuf conformance with edition 2023: tally

Runner v32.0-rc2 (`conformance/protobuf/fetch-runner.sh`), `--enforce_recommended --maximum_edition 2023`, testee generated under codec=both (`just protobuf-conformance`). Cases enumerated with `TESTEE_FAIL_ALL=1`; failures from the run. Proto3 is the regression baseline (same tally as `tally-v32.0-rc2-merge.md`).

## Proto3 (`TestAllTypesProto3`, unchanged)

| level | formats | cases | passed | failed |
|---|---|---:|---:|---:|
| Recommended | JSON → JSON | 87 | 73 | 14 |
| Recommended | JSON → binary | 20 | 15 | 5 |
| Recommended | binary → JSON | 10 | 10 | 0 |
| Recommended | binary → binary | 216 | 216 | 0 |
| Required | JSON → JSON | 207 | 189 | 18 |
| Required | JSON → binary | 148 | 136 | 12 |
| Required | binary → JSON | 298 | 294 | 4 |
| Required | binary → binary | 482 | 480 | 2 |
| Required | all | 1135 | 1099 | 36 |
| Recommended | all | 333 | 314 | 19 |

## Proto3 written in edition 2023 (`editions.proto3.TestAllTypesProto3`, subset)

| level | formats | cases | passed | failed |
|---|---|---:|---:|---:|
| Recommended | JSON → JSON | 87 | 73 | 14 |
| Recommended | JSON → binary | 20 | 15 | 5 |
| Recommended | binary → JSON | 10 | 10 | 0 |
| Recommended | binary → binary | 216 | 187 | 29 |
| Required | JSON → JSON | 207 | 189 | 18 |
| Required | JSON → binary | 148 | 136 | 12 |
| Required | binary → JSON | 298 | 293 | 5 |
| Required | binary → binary | 482 | 479 | 3 |
| Required | all | 1135 | 1097 | 38 |
| Recommended | all | 333 | 285 | 48 |

## Edition 2023 (`TestAllTypesEdition2023`, subset)

| level | formats | cases | passed | failed |
|---|---|---:|---:|---:|
| Required | binary → JSON | 6 | 4 | 2 |
| Required | binary → binary | 8 | 4 | 4 |
| Required | all | 14 | 8 | 6 |
| Recommended | all | 0 | 0 | 0 |

## Classification of the edition 2023 failures (conformance/protobuf/failure_list.txt)

- 55 Editions_Proto3 cases are the twins of the 55 proto3 failures, with the
  same causes (unknown fields not kept, Any by type URL, and the rest the
  proto3 section classifies): proto3 written in edition 2023 generates the
  same codecs, and fails exactly where proto3 fails. No proto3 failure passes
  in the twin, and no twin fails where proto3 passes but for the next two.
- 28 Recommended `ValidDataRepeated.*.UnpackedOutput` and 3 oneof
  `MESSAGE.Merge` cases set an EXPANDED field (`unpacked_*`; the merges set
  `corecursive.unpacked_int32`), which the binary codecs refuse and the subset
  drops: unsupported. proto3's `[packed = false]` twins of the same fields
  generate and pass.
- 6 `Required.Editions.ValidDelimited{Field,Extension}` cases set a delimited
  field or extension, which elm-connect refuses and the subset drops:
  unsupported. The 8 other `Required.Editions` cases (length-prefixed field,
  maps, non-message fields of the group-like messages) pass.

Dropped by the subsets (strip-editions.sh): from test_messages_edition2023,
groupliketype = 201, delimited_field = 202, extensions 120 to 200 and the
extensions 120, 121, 122, and unpacked_* = 89 to 102; from
test_messages_proto3_editions, unpacked_* = 89 to 102 and the two NullValue
fields (307, 120), as proto3's.
