# Sizes and speed with generated route functions

Same procedure as `spike/baseline.md` (`spike/measure.sh`), at the head
of `spike/gen-routes`: every service regenerated with route functions and
`Proto.Method.methodWith`. "old gen" is `tests/Routes` as main generated
it (`Proto.Method.method` + bindings as data) compiled against the new
runtime: what an application that has not regenerated pays.

## Totals (bytes)

| program | stage | baseline | after | delta |
|---|---|---:|---:|---:|
| notes | optimized | 298401 | 283788 | -14613 (-4.9%) |
| notes | minified | 77210 | 74351 | -2859 (-3.7%) |
| notes | gzip | 25477 | 24665 | -812 (-3.2%) |
| live | optimized | 373283 | 354108 | -19175 (-5.1%) |
| live | minified | 91164 | 90196 | -968 (-1.1%) |
| live | gzip | 27917 | 26898 | -1019 (-3.7%) |
| routes | optimized | 207776 | 194137 | -13639 (-6.6%) |
| routes | minified | 49276 | 49170 | -106 (-0.2%) |
| routes | gzip | 15714 | 14957 | -757 (-4.8%) |
| routes, old gen | optimized | 207776 | 212795 | +5019 (+2.4%) |
| routes, old gen | minified | 49276 | 50574 | +1298 (+2.6%) |
| routes, old gen | gzip | 15714 | 16140 | +426 (+2.7%) |

## By group, unminified optimized (attr.py)

| program | group | baseline | after | delta |
|---|---|---:|---:|---:|
| notes | runtime | 107421 | 95391 | -12030 |
| notes | generated | 25941 | 23392 | -2549 |
| live | runtime | 126717 | 114391 | -12326 |
| live | generated | 109290 | 102845 | -6445 |
| routes | runtime | 70320 | 61365 | -8955 |
| routes | generated | 55178 | 51063 | -4115 |

Runtime modules that change (routes program): `Rpc.Internal.Route` 7693 ->
2070, `Proto.Http` 3157 -> 0, `Proto.Field` 1755 -> 0 (field descriptors
are no longer reached), `Proto.Enum`/`Proto.EnumValue` 595 -> 0,
`Proto.Internal` 710 -> 77, `Rpc.Route` 0 -> 5349 (new: the helpers,
`jsonText`'s decoder and `without`). Generated descriptor modules
reached only through bindings drop out (`Routes.V1.Everything` 5031,
`Routes.V1.GetMessageRequest` 1155, … -> 0).

## Per method, unminified optimized (call + descriptor + route functions)

The before column is the call and its descriptor, the after column the
call, its descriptor and its route functions. Neither counts the field
descriptor modules the bindings reached (gone after; see above).

Notes service:

| method | before | after | delta |
|---|---:|---:|---:|
| archiveNote | 1096 | 1235 | +139 |
| createNote | 884 | 1029 | +145 |
| deleteNote | 1085 | 1025 | -60 |
| getNote | 1056 | 993 | -63 |
| listNotes | 1377 | 1426 | +49 |
| updateNote | 1317 | 1461 | +144 |
| **total** | 6815 | 7169 | +354 |

tests/Routes service:

| method | before | after | delta |
|---|---:|---:|---:|
| cancel | 1045 | 1167 | +122 |
| files | 1046 | 970 | -76 |
| getMessage | 5097 | 5124 | +27 |
| head | 1043 | 965 | -78 |
| multi | 3949 | 5007 | +1058 |
| postSub | 1048 | 1273 | +225 |
| query | 3825 | 4949 | +1124 |
| single | 3877 | 4971 | +1094 |
| typed | 4063 | 5258 | +1195 |
| unbound | 457 | 486 | +29 |
| updateMessage | 1084 | 1165 | +81 |
| updateMessageWhole | 1009 | 1187 | +178 |
| updateResource | 1367 | 1493 | +126 |
| **total** | 28910 | 34015 | +5105 |

The call itself grows (about 265 -> 420 bytes: the `methodWith` record
and its routes list); the descriptor shrinks (about 800 -> 200); the route
function is 375-830 bytes for a method of the notes example and 4.4-4.7 KB
for a method of `Everything`, whose query has 22 parameters.

## Speed (spike/bench.js)

`node spike/bench.js OLD NEW 625 15`: 625 rounds of the 16 requests of the
routes worker (10,000 `Rpc.request` calls), median of 15 runs after a
warm-up, Node 24.21, unminified optimized builds:

| build | median | per request |
|---|---:|---:|
| baseline (interpreter) | 56.1 ms | 5.61 us |
| after (route functions) | 29.4 ms | 2.94 us (-48%) |
| old gen on new runtime | 60.7 ms | 6.07 us (+9%) |

The last round's requests are identical in all three (the script checks).
`Rpc.request` alone is measured; sending also runs `unsendable`, which
builds the route again for its path check and still encodes the request's
JSON for the write limit (unchanged by this spike).

## Generator and tests

- Generator: +532 lines (`emit/route_fn.rs`, new), +103/-15 in
  `emit/method.rs`, +41 in `emit.rs`, small edits in `lib.rs` and
  `naming.rs`; `git diff --stat ef27315..HEAD -- crates/`: 5 files,
  +672/-26.
- Runtime: `Rpc.Route` +258, `Proto.Internal.Interpret` +265 (moved from
  `Rpc.Internal.Route`, -338 there), `Proto.Internal.Method` +30,
  `Proto.Method` +72.
- Tests: no Elm test changed or added; 2565 runtime tests and 11 example
  tests pass before and after. Rust: two unit tests edited
  (`a_method_carries_codecs_not_typed_records` for the new call text and
  sections, `the_runtime_modules_are_the_packages_exposed_modules` for
  `Rpc.Route`); no unit test for `route_fn.rs` itself: its oracle is the
  route fixtures, the route properties and the live suite.

## Raw output

```
notes    optimized   283788  minified    74351  gzip   24665
live     optimized   354108  minified    90196  gzip   26898
routes   optimized   194137  minified    49170  gzip   14957
== attribution: notes
total attributed 191934
  runtime        95391
  pkg            53243
  generated      23392
  app            19908
--- top keys
  pkg:elm/core                                38038
  runtime:Rpc.Internal                        33601
  runtime:Proto.Json                          27169
  app:Main                                    19491
  generated:Notes.V1                           9811
  runtime:Proto.Timestamp                      8440
  generated:Notes.V1.NotesService              7169
  pkg:elm/json                                 6095
  runtime:Rpc.Error                            5191
  generated:Google.Rpc                         4985
  runtime:Rpc.Route                            4248
  runtime:Rpc.Code                             3663
  runtime:Rpc                                  3535
  pkg:elm/html                                 3220
  pkg:elm/url                                  3139
  runtime:Proto.Duration                       3008
  pkg:elm/http                                 1390
  runtime:Proto.Message                        1295
  runtime:Proto.Method                         1195
  runtime:Proto.Any                            1098
  generated:Google.Rpc.ErrorInfo                939
  runtime:Proto.Field                           838
  runtime:Rpc.Call                              759
  runtime:Proto.Internal                        566
  pkg:elm/virtual_dom                           559
  pkg:elm/time                                  534
  generated:Google.Rpc.BadRequest               488
  runtime:Rpc.Body                              435
  app:Api                                       417
  runtime:Rpc.Transport                         350
== attribution: live
total attributed 301442
  runtime       114391
  generated     102845
  pkg            50233
  app            33973
--- top keys
  runtime:Proto.Json                          38213
  pkg:elm/core                                37268
  runtime:Rpc.Internal                        36793
  generated:Routes.V1.Routes                  33996
  app:Live                                    33973
  generated:Connectrpc.Conformance.V1         29715
  generated:Routes.V1                         18993
  generated:Notes.V1                          12481
  runtime:Proto.Timestamp                      8440
  generated:Notes.V1.NotesService              7660
  pkg:elm/json                                 6506
  pkg:elm/http                                 5925
  runtime:Rpc.Route                            5349
  runtime:Rpc                                  5347
  runtime:Rpc.Error                            4562
  runtime:Rpc.Code                             3663
  runtime:Proto.Duration                       3008
  runtime:Rpc.Trace                            2401
  runtime:Rpc.Transport                        2055
  runtime:Rpc.Call                             1489
  runtime:Proto.Method                         1201
  runtime:Rpc.Retry                             869
  runtime:Proto.Internal                        566
  pkg:elm/time                                  534
  runtime:Rpc.Body                              435
== attribution: routes
total attributed 146532
  runtime        61365
  generated      51063
  pkg            28800
  app             5304
--- top keys
  generated:Routes.V1.Routes                  34015
  runtime:Proto.Json                          33074
  pkg:elm/core                                23153
  generated:Routes.V1                         17048
  runtime:Proto.Timestamp                      8440
  runtime:Rpc.Internal                         8068
  pkg:elm/json                                 5444
  runtime:Rpc.Route                            5349
  app:Main                                     5304
  runtime:Proto.Duration                       3008
  runtime:Proto.Method                         1094
  runtime:Rpc.Call                              977
  runtime:Rpc                                   494
  runtime:Rpc.Body                              435
  runtime:Rpc.Transport                         349
  pkg:elm/time                                  203
  runtime:Proto.Internal                         77
== per definition: notes service
$author$project$Notes$V1$NotesService$ total 7169
  routeUpdateNote0                                     824
  routeListNotes0                                      770
  routeArchiveNote0                                    591
  listNotes                                            437
  archiveNote                                          432
  createNote                                           428
  updateNote                                           428
  deleteNote                                           425
  getNote                                              416
  routeCreateNote0                                     392
  routeDeleteNote0                                     383
  routeGetNote0                                        377
  descriptorListNotes                                  219
  descriptorDeleteNote                                 217
  descriptorArchiveNote                                212
  descriptorCreateNote                                 209
  descriptorUpdateNote                                 209
  descriptorGetNote                                    200
== per definition: routes service (tests/Routes)
$author$project$Routes$V1$Routes$ total 34015
  routeTyped0                                         4667
  routeMulti0                                         4416
  routeSingle0                                        4375
  routeQuery0                                         4358
  routeGetMessage3                                    1134
  routeGetMessage1                                    1058
  routeGetMessage0                                    1039
  routeGetMessage2                                     996
  routeUpdateResource0                                 839
  getMessage                                           693
  routePostSub0                                        664
  routeCancel0                                         579
  routeUpdateMessageWhole0                             543
  routeUpdateMessage0                                  520
  updateResource                                       437
  updateMessageWhole                                   434
  updateMessage                                        432
  postSub                                              411
  single                                               404
  files                                                403
  multi                                                401
  query                                                401
  typed                                                401
  cancel                                               400
  head                                                 400
  routeFiles0                                          375
  routeHead0                                           375
  unbound                                              288
  descriptorUpdateResource                             217
  descriptorUpdateMessage                              213
  descriptorUpdateMessageWhole                         210
  descriptorGetMessage                                 204
  descriptorPostSub                                    198
  descriptorUnbound                                    198
  descriptorFiles                                      192
  descriptorSingle                                     192
  descriptorHead                                       190
  descriptorMulti                                      190
  descriptorQuery                                      190
  descriptorTyped                                      190
== per definition: runtime transcoding (routes main)
$author$project$Rpc$Internal$Route$ total 2070
$author$project$Proto$Http$ total 0
$author$project$Proto$Internal$ total 77
$author$project$Rpc$Route$ total 5349
$author$project$Proto$Method$ total 1094
$author$project$Rpc$Internal$Wire$ total 3435
```

Re-measured after the last generator commit (a printing fix): routes
194141 / 49171 / 14957, live 354112 / 90197 / 26898, notes unchanged;
the benchmark 55.4 ms old against 28.9 ms new.
