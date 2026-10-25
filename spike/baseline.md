# Baseline sizes (main at ef27315)

Procedure (`spike/measure.sh`): `elm make --optimize` (Elm 0.19.2, via
mise), then `npx terser@5.36.0 --compress --mangle` (terser defaults; not
the Elm guide's pure_funcs set), then `gzip -9`. Programs:

- `notes`: `examples/notes/elm/src/Main.elm` (the browser example).
- `live`: `conformance/live/src/Live.elm` (the live runner: notes, routes and
  the Connect conformance suite's client).
- `routes`: `spike/routes-main/src/Main.elm`, a worker that sends one
  request per binding of every method of `tests/Routes` through
  `Rpc.request` over Transcode (no `send`, no response decoding).

Attribution (`spike/attr.py`, `spike/fn.py`) is over the unminified
optimized output: bytes of each top-level `var` by module. "runtime" is the
package's `Rpc.*`/`Proto.*`; "generated" is `Notes.*`, `Routes.*`,
`Google.*`, `Connectrpc.*`; "app" is the rest of the project; "pkg" is
elm/* packages. The field-descriptor modules (`Routes.V1.Everything`, …)
appear in the program only because the HTTP bindings reference field
descriptors.

```
notes    optimized   298401  minified    77210  gzip   25477
live     optimized   373283  minified    91164  gzip   27917
routes   optimized   207776  minified    49276  gzip   15714
== attribution: notes
total attributed 206504
  runtime       107421
  pkg            53244
  generated      25941
  app            19898
--- top keys
  runtime:Rpc.Internal                        45161
  pkg:elm/core                                38038
  runtime:Proto.Json                          27169
  app:Main                                    19481
  generated:Notes.V1                           9811
  runtime:Proto.Timestamp                      8440
  generated:Notes.V1.NotesService              6815
  pkg:elm/json                                 6095
  runtime:Rpc.Error                            5191
  generated:Google.Rpc                         4985
  runtime:Rpc.Code                             3663
  runtime:Rpc                                  3535
  pkg:elm/html                                 3220
  pkg:elm/url                                  3140
  runtime:Proto.Http                           3050
  runtime:Proto.Duration                       3008
  pkg:elm/http                                 1390
  runtime:Proto.Field                          1322
  runtime:Proto.Method                         1307
  runtime:Proto.Message                        1298
  runtime:Proto.Internal                       1132
  runtime:Proto.Any                            1098
  generated:Notes.V1.ListNotesRequest           954
  generated:Google.Rpc.ErrorInfo                939
  runtime:Rpc.Call                              666
  pkg:elm/virtual_dom                           559
  pkg:elm/time                                  534
  generated:Notes.V1.UpdateNoteRequest          491
  generated:Google.Rpc.BadRequest               488
  runtime:Rpc.Body                              435
== attribution: live
total attributed 320535
  runtime       126717
  generated     109290
  pkg            50555
  app            33973
--- top keys
  runtime:Rpc.Internal                        48350
  runtime:Proto.Json                          38213
  pkg:elm/core                                37440
  app:Live                                    33973
  generated:Connectrpc.Conformance.V1         29619
  generated:Routes.V1.Routes                  28830
  generated:Routes.V1                         18993
  generated:Notes.V1                          12481
  runtime:Proto.Timestamp                      8440
  generated:Notes.V1.NotesService              7244
  pkg:elm/json                                 6656
  pkg:elm/http                                 5925
  runtime:Rpc                                  5347
  generated:Routes.V1.Everything               5031
  runtime:Rpc.Error                            4562
  runtime:Rpc.Code                             3663
  runtime:Proto.Http                           3147
  runtime:Proto.Duration                       3008
  runtime:Rpc.Trace                            2401
  runtime:Rpc.Transport                        2055
  runtime:Proto.Field                          1761
  runtime:Rpc.Call                             1364
  runtime:Proto.Method                         1307
  runtime:Proto.Internal                       1199
  generated:Routes.V1.GetMessageRequest        1155
  generated:Notes.V1.ListNotesRequest           954
  runtime:Rpc.Retry                             869
  pkg:elm/time                                  534
  generated:Routes.V1.UpdateResourceRequest      518
  generated:Notes.V1.UpdateNoteRequest          491
== attribution: routes
total attributed 160096
  runtime        70320
  generated      55178
  pkg            29294
  app             5304
--- top keys
  runtime:Proto.Json                          33074
  generated:Routes.V1.Routes                  28910
  pkg:elm/core                                23246
  generated:Routes.V1                         17048
  runtime:Rpc.Internal                        16251
  runtime:Proto.Timestamp                      8440
  pkg:elm/json                                 5845
  app:Main                                     5304
  generated:Routes.V1.Everything               5031
  runtime:Proto.Http                           3157
  runtime:Proto.Duration                       3008
  runtime:Proto.Field                          1755
  runtime:Proto.Method                         1200
  generated:Routes.V1.GetMessageRequest        1155
  runtime:Rpc.Call                              852
  runtime:Proto.Internal                        710
  generated:Routes.V1.UpdateResourceRequest      518
  runtime:Rpc                                   494
  generated:Routes.V1.UpdateMessageRequest      483
  runtime:Rpc.Body                              435
  generated:Routes.V1.Inner                     416
  generated:Routes.V1.Deep                      389
  runtime:Rpc.Transport                         349
  generated:Routes.V1.Kind                      347
  runtime:Proto.EnumValue                       310
  runtime:Proto.Enum                            285
  generated:Routes.V1.GetMessageRequestSubMessage      239
  generated:Routes.V1.Message                   223
  generated:Routes.V1.FileRequest               211
  generated:Routes.V1.Resource                  208
== per definition: notes service
$author$project$Notes$V1$NotesService$ total 6815
  descriptorListNotes                                 1097
  descriptorUpdateNote                                1047
  descriptorArchiveNote                                823
  descriptorDeleteNote                                 818
  descriptorGetNote                                    795
  descriptorCreateNote                                 614
  listNotes                                            280
  archiveNote                                          273
  createNote                                           270
  updateNote                                           270
  deleteNote                                           267
  getNote                                              261
== per definition: routes service (tests/Routes)
$author$project$Routes$V1$Routes$ total 28910
  descriptorGetMessage                                4832
  descriptorTyped                                     3812
  descriptorMulti                                     3698
  descriptorSingle                                    3624
  descriptorQuery                                     3574
  descriptorUpdateResource                            1089
  descriptorUpdateMessage                              810
  descriptorCancel                                     796
  descriptorFiles                                      793
  descriptorHead                                       792
  descriptorPostSub                                    789
  descriptorUpdateMessageWhole                         738
  updateResource                                       278
  updateMessage                                        274
  updateMessageWhole                                   271
  getMessage                                           265
  postSub                                              259
  unbound                                              259
  files                                                253
  single                                               253
  head                                                 251
  multi                                                251
  query                                                251
  typed                                                251
  cancel                                               249
  descriptorUnbound                                    198
== per definition: runtime transcoding (routes main)
$author$project$Rpc$Internal$Route$ total 7693
$author$project$Proto$Http$ total 3157
$author$project$Proto$Internal$ total 710
$author$project$Rpc$Route$ total 0
$author$project$Proto$Method$ total 1200
$author$project$Rpc$Internal$Wire$ total 3436
```
