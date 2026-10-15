# The notes example

A small API, `notes.v1.NotesService`, served by a Go server over the
Connect protocol and over HTTP transcoding from one port, and a browser
application calling it through the Elm client elm-connect generates. The
live suite (`conformance/live/`, `just live`) runs the runtime against
the same server.

This page walks through the application. Each Elm, JSON or YAML block
on it is an excerpt of a file in this directory, named in the block's
fence; `just snippets` (part of `just check`) fails when one differs from
its file, and `just live` compiles the application.

```
proto/notes/v1/notes.proto   the API; its comments document each method's errors
buf.yaml, buf.lock           the modules; googleapis comes from the Buf Schema Registry
buf.gen.yaml                 Go stubs into server/gen, Elm into elm/generated
buf.gen.google-rpc.yaml      Elm for google.rpc's error details into elm/generated
server/                      the Go server (connect-go and Vanguard); routes.go echoes routes.v1
elm/generated/               the generated Elm: Notes.V1, Notes.V1.NotesService, Google.Rpc
elm/src/Main.elm             the application
elm/src/Api.elm              the one function every call is sent through
elm/src/Snippets/            the root README's examples, compiled with the application
elm/index.html               the page: elm.js and nothing else
routes/                      a link to conformance/routes: the route fixtures' API, served too
```

## Running it

From the repository root, with the tools `mise install` provides:

```sh
just example-notes
```

builds the server and the application (`elm make --optimize` into
`elm/dist/`) and serves both from `http://127.0.0.1:8080`: the server's
`-static` flag serves a directory's files beside the API, so the page and
the API share one origin and need no CORS. Open it, and the browser's
network tab beside it.

## Installing the generator

There is no release yet. The CLI and the protoc plugin install from the
repository with Cargo:

```sh
cargo install --git https://github.com/bruckner/elm-connect elm-connect
cargo install --git https://github.com/bruckner/elm-connect protoc-gen-elm-connect
```

The CLI needs nothing else: it compiles the protos itself and carries
`google/api/annotations.proto` and `google/api/http.proto`. The plugin
runs under protoc or buf; this example uses buf, which takes it from
`PATH`:

```yaml examples/notes/buf.gen.yaml
- local: protoc-gen-elm-connect
  out: elm/generated
```

## Generating

```sh
buf generate                                         # from this directory
elm-connect gen -I proto notes/v1/notes.proto --out elm/generated
```

Either writes `elm/generated/Notes/V1.elm` (the types and their JSON
codecs) and `elm/generated/Notes/V1/NotesService.elm` (one function per
method), and the two write the same files. googleapis reaches buf's
plugins as imports only, so nothing is generated for it. The application
also reads `google.rpc` error details, so `buf.gen.google-rpc.yaml`
generates `google/rpc/error_details.proto` from the same googleapis
module, at the commit `buf.lock` pins, into `Google.Rpc`:

```sh
buf generate --template buf.gen.google-rpc.yaml
```

`just live-gen` runs both and fails if the output differs from what is
committed.

## The runtime in `elm.json`

The generated modules import the runtime package, `Proto.*` and `Rpc`.
It is not on the package index yet, so this application reads it from
the repository's `src`, beside its own sources and the generated ones:

```json examples/notes/elm/elm.json
"source-directories": [
    "src",
    "generated",
    "../../../src"
],
```

and takes the runtime's dependencies directly:

```json examples/notes/elm/elm.json
"elm/http": "2.0.0",
"elm/json": "1.1.3",
"elm/time": "1.0.0"
```

Once the package is published, `elm install bruckner/elm-connect` replaces
the third source directory.

## Sending every call through one function

A config is data, with no function in it, so the application builds it
from its own state in one place and sends every call through one
function. `Api.elm`:

```elm examples/notes/elm/src/Api.elm#wrapper
rpc : Shared -> Rpc.Call req res -> Task Rpc.Error res
rpc shared call =
    Rpc.task (config shared) call


config : Shared -> Rpc.Config
config shared =
    let
        base =
            Rpc.config shared.apiUrl
    in
    { base
        | transport = shared.transport
        , headers = [ ( "Authorization", "Bearer " ++ shared.token ) ]
    }
```

`Shared` holds the page's origin, a token and the transport the page's
toggle chose. The token is a fixed string here; the server ignores it,
and it shows in the network tab as the `Authorization` header.

## A first call

A generated method applied to its request is an `Rpc.Call`; `Api.rpc`
sends it as a `Task`. Listing the notes, from `Main.elm`:

```elm examples/notes/elm/src/Main.elm#first-call
list : Model -> ( Model, Cmd Msg )
list model =
    let
        call =
            Notes.listNotes Notes.V1.defaultListNotesRequest
    in
    ( record call model
    , Api.rpc model.shared call |> Task.attempt Listed
    )
```

`record` keeps `Rpc.request (Api.config shared) call`, the HTTP request
the call becomes, built without sending anything; the page lists the
last few under "Sent".

## Reading an error

Creating a note without a title fails with `INVALID_ARGUMENT` and a
`google.rpc.BadRequest` detail; "Get notes/missing" fails with
`NOT_FOUND` and a `google.rpc.ErrorInfo`. The page shows the code, the
message, where the error was read from, the details it knows by type,
and every detail as JSON; an answer that stated no status shows the
code inferred from it and the body as it came:

```elm examples/notes/elm/src/Main.elm#error
viewError : Rpc.Error -> Html msg
viewError error =
    case error of
        Rpc.Status status answer ->
            section [ class "error" ]
                [ h2 [] [ text (Rpc.ErrorCode.toString status.code) ]
                , p [] [ text status.message ]
                , p [] [ text ("Read from " ++ sourceToString status.source ++ " (HTTP " ++ String.fromInt answer.statusCode ++ ")") ]
                , ul []
                    (List.map
                        (\violation -> li [] [ code [] [ text violation.field ], text (": " ++ violation.description) ])
                        (Rpc.details Google.Rpc.messageBadRequest error |> List.concatMap .fieldViolations)
                    )
                , ul []
                    (List.map
                        (\info -> li [] [ text (info.reason ++ " from " ++ info.domain) ])
                        (Rpc.details Google.Rpc.messageErrorInfo error)
                    )
                , div [] (List.map viewDetail status.details)
                ]

        Rpc.Http answer ->
            section [ class "error" ]
                [ h2 [] [ text (Rpc.ErrorCode.toString (Rpc.code error)) ]
                , p [] [ text (Rpc.message error) ]
                , p [] [ text ("Inferred from the HTTP status " ++ String.fromInt answer.statusCode ++ "; the body was:") ]
                , pre [] [ text answer.body ]
                ]

        Rpc.Transport _ ->
            section [ class "error" ] [ p [] [ text (Rpc.errorToString error) ] ]


viewDetail : Proto.Any.Any -> Html msg
viewDetail detail =
    pre [] [ text (Json.Encode.encode 2 (Proto.Any.encodeJson detail)) ]


sourceToString : Rpc.Source -> String
sourceToString source =
    case source of
        Rpc.ConnectBody ->
            "a Connect error body"

        Rpc.StatusBody ->
            "a google.rpc.Status body"

        Rpc.GrpcHeaders ->
            "the grpc-status header"
```

Over Connect the error arrives as a Connect error body
(`{"code": "invalid_argument", …}`, each detail with its JSON as
`debug`); over transcoding Vanguard sends a `google.rpc.Status` body
(`{"code": 3, …}`). The error is the same `Rpc.Error` either way, and
`source` says which body it was. The answer rides with the error as
`Rpc.Response`, its status, headers and body, so a body in a shape the
runtime does not read can still be shown, as the `Rpc.Http` branch does.

## The transport toggle

The toggle changes the transport in `Shared`, and every call after it,
from the same generated code, goes over the other wire form:

```elm examples/notes/elm/src/Main.elm#toggle
SetTransport transport ->
    let
        shared =
            model.shared
    in
    list { model | shared = { shared | transport = transport } }
```

## The update mask

Saving an edit sends the whole note and an update mask naming the fields
that changed, by proto name; the server copies only those:

```elm examples/notes/elm/src/Main.elm#update-mask
updateRequest : Draft -> Notes.V1.UpdateNoteRequest
updateRequest draft =
    let
        note =
            draft.original

        tags =
            draft.tags
                |> String.split ","
                |> List.map String.trim
                |> List.filter (not << String.isEmpty)

        changed field isChanged =
            if isChanged then
                Just field

            else
                Nothing
    in
    { note = Just { note | title = draft.title, body = draft.body, tags = tags }
    , updateMask =
        Just
            (List.filterMap identity
                [ changed "title" (draft.title /= note.title)
                , changed "body" (draft.body /= note.body)
                , changed "tags" (tags /= note.tags)
                ]
            )
    }
```

## What to look at in the network tab

The same actions, over each transport (requests to `127.0.0.1:8080`):

| Action | Connect | HTTP transcoding |
|---|---|---|
| list | `POST /notes.v1.NotesService/ListNotes`, body `{}` (every field at its default) | `GET /v1/notes` |
| create | `POST /notes.v1.NotesService/CreateNote`, body `{"note":{…}}` | `POST /v1/notes`, body the note |
| save title and tags | `POST /notes.v1.NotesService/UpdateNote`, body `{"note":{…},"updateMask":"title,tags"}` | `PATCH /v1/notes/welcome?update_mask=title,tags`, body the note |
| archive | `POST /notes.v1.NotesService/ArchiveNote`, body `{"name":"notes/…"}` | `POST /v1/notes/…:archive` |
| delete | `POST /notes.v1.NotesService/DeleteNote` | `DELETE /v1/notes/…` |
| get notes/missing | 404, a Connect error body | 404, a `google.rpc.Status` body |

Every Connect request carries `Connect-Protocol-Version: 1`; a call
sent to a rule's route does not. A failed create is a 400 either way,
with the detail in the body. The page loads `elm.js` and nothing else:

```html examples/notes/elm/index.html
<script src="elm.js"></script>
<script>
  Elm.Main.init({ node: document.getElementById("app"), flags: window.location.origin });
</script>
```

## The server

```sh
cd examples/notes/server
go run . -addr 127.0.0.1:8080                       # the API alone
go run . -addr 127.0.0.1:8080 -static ../elm/dist   # and the page, once built
```

It prints `listening on http://127.0.0.1:8080` and serves:

| Route | What |
|---|---|
| `POST /notes.v1.NotesService/<Method>` | Connect (connect-go also serves gRPC and gRPC-Web here) |
| `GET /notes.v1.NotesService/<Method>?connect=v1&…` | Connect GET, for `GetNote`, `ListNotes` and `Ping` |
| `GET /v1/{name=notes/*}` | `GetNote` |
| `GET /v1/notes?page_size=&page_token=&filter=&visibility=` | `ListNotes` |
| `POST /v1/notes` (body: the note) | `CreateNote` |
| `PATCH /v1/{note.name=notes/*}?update_mask=` (body: the note) | `UpdateNote` |
| `DELETE /v1/{name=notes/*}` | `DeleteNote` |
| `POST /v1/{name=notes/*}:archive` | `ArchiveNote` |
| `POST /notes.v1.NotesService/Ping` | `Ping`, which has no HTTP rule: the implicit route is its Connect route |
| `GET /healthz` | `ok` |
| `GET /`, `GET /<file>` | with `-static`, that directory's `index.html` and files |
| `/status/<status>/…` | that HTTP status with a plain-text body, for reading an answer without an error body |
| `/grpc-status/<code>/…` | HTTP 503 with no body and the error in `grpc-status` and `grpc-message` |
| `routes.v1.Routes` at its rules and Connect routes | the route fixtures' service, echoing each request (`server/routes.go`) |
| `/layer/<n>/…` | the bindings of `routes.v1.Routes` Vanguard will not serve beside the others |
| `GET /routes/layers` | where each binding of `routes.v1.Routes` is served, as JSON |

The store is in memory and starts with three notes: `notes/welcome`, with
every field set, `notes/slow` and `notes/flaky`. Calls naming
`notes/slow` take two seconds whatever their deadline; every other call
naming `notes/flaky` fails with `UNAVAILABLE`, starting with the first; a
request header `x-echo` comes back as a response header. Errors are
Connect error bodies on the Connect routes and `google.rpc.Status` bodies
on the REST routes, with their details (`google.rpc.ErrorInfo` for a
missing note, `google.rpc.BadRequest` for a note without a title).

```sh
curl -s http://127.0.0.1:8080/v1/notes/welcome
curl -s -X POST http://127.0.0.1:8080/notes.v1.NotesService/GetNote \
  -H 'Content-Type: application/json' -d '{"name": "notes/welcome"}'
```
