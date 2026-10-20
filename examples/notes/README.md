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
buf.yaml                     the modules: proto, routes and the vendored googleapis
third_party/googleapis/      the googleapis files the API imports (README.md: provenance)
buf.gen.yaml                 Go stubs into server/gen, Elm into elm/generated
buf.gen.google-rpc.yaml      Elm for google.rpc's error details into elm/generated
buf.gen.include-imports.yaml the Elm of both, run with --include-imports to check it adds nothing
buf.gen.gateway.yaml         grpc-gateway's proxies into server/gen
buf.gen.gateway-apart.yaml   the one routes.v1 method it generates apart
server/                      the Go server (connect-go, Vanguard and grpc-gateway); routes.go echoes routes.v1
elm/generated/               the generated Elm: Notes.V1, Notes.V1.NotesService, Google.Rpc
elm/src/Main.elm             the application
elm/src/Api.elm              the one function every call is sent through
elm/src/Snippets/            the root README's examples, compiled with the application
elm/tests/                   tests of the snippets that compute (UpdateMask), run by `just check`
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
generates `google/rpc/error_details.proto` from the vendored googleapis
module into `Google.Rpc`:

```sh
buf generate --template buf.gen.google-rpc.yaml
```

`just live-gen` runs both and fails if the output differs from what is
committed. It then runs `buf generate --include-imports --template
buf.gen.include-imports.yaml` into a scratch directory and fails unless
that gives the same files: with every import asked for, the plugin still
writes no `Google.Api` module, since it skips `google/api/http.proto`
and `google/api/annotations.proto`, which only carry `google.api.http`,
and `google.protobuf` maps to the runtime.
None of them needs the network: the googleapis files are in
`third_party/googleapis/`, and `just protos-refresh` re-exports them
from the Buf Schema Registry at the commit its README names.

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

```json examples/notes/elm/elm.json excerpt
            "elm/bytes": "1.0.8",
            "elm/http": "2.0.0",
            "elm/json": "1.1.4",
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
and every detail as JSON; an answer that stated no status, or a
successful one whose body is not the response, shows its code and the
body as it came:

```elm examples/notes/elm/src/Main.elm#error
viewError : Rpc.Error -> Html msg
viewError error =
    case error of
        Rpc.Error.RpcStatus status answer ->
            section [ class "error" ]
                [ h2 [] [ text (Rpc.Code.toString status.code) ]
                , p [] [ text status.message ]
                , p [] [ text ("Read from " ++ sourceToString status.source ++ " (HTTP " ++ String.fromInt answer.statusCode ++ ")") ]
                , ul []
                    (List.map
                        (\violation -> li [] [ code [] [ text violation.field ], text (": " ++ violation.description) ])
                        (Rpc.Error.details Google.Rpc.messageBadRequest error |> List.concatMap .fieldViolations)
                    )
                , ul []
                    (List.map
                        (\info -> li [] [ text (info.reason ++ " from " ++ info.domain) ])
                        (Rpc.Error.details Google.Rpc.messageErrorInfo error)
                    )
                , div [] (List.map viewDetail status.details)
                ]

        Rpc.Error.HttpStatus answer ->
            section [ class "error" ]
                [ h2 [] [ text (Rpc.Code.toString (Rpc.Error.code error)) ]
                , p [] [ text (Rpc.Error.message error) ]
                , p [] [ text ("Inferred from the HTTP status " ++ String.fromInt answer.statusCode ++ "; the body was:") ]
                , pre [] [ text (Maybe.withDefault "" (Rpc.Body.toText answer.body)) ]
                ]

        Rpc.Error.BadResponse _ answer ->
            section [ class "error" ]
                [ h2 [] [ text (Rpc.Code.toString (Rpc.Error.code error)) ]
                , p [] [ text (Rpc.Error.message error) ]
                , p [] [ text ("HTTP " ++ String.fromInt answer.statusCode ++ " with a body that is not the response:") ]
                , pre [] [ text (Maybe.withDefault "" (Rpc.Body.toText answer.body)) ]
                ]

        Rpc.Error.NoAnswer _ ->
            section [ class "error" ] [ p [] [ text (Rpc.Error.toString error) ] ]


viewDetail : Proto.Any.Any -> Html msg
viewDetail detail =
    pre [] [ text (Json.Encode.encode 2 (Proto.Json.encodeAny detail)) ]


sourceToString : Rpc.Error.Source -> String
sourceToString source =
    case source of
        Rpc.Error.ConnectBody ->
            "a Connect error body"

        Rpc.Error.StatusBody ->
            "a google.rpc.Status body"

        Rpc.Error.GrpcHeaders ->
            "the grpc-status header"
```

Over Connect the error arrives as a Connect error body
(`{"code": "invalid_argument", …}`, each detail with its JSON as
`debug`); over transcoding Vanguard sends a `google.rpc.Status` body
(`{"code": 3, …}`). The error is the same `Rpc.Error` either way, and
`source` says which body it was. The answer rides with the error as
`Rpc.Response`, its status, headers and body, so a body in a shape the
runtime does not read, or one that drifted from the schema, can still be
shown, as the `HttpStatus` and `BadResponse` branches do.

## The transport toggle

The toggle sets the transport in `Shared`, and the API's URL with it:
the server's own origin for Connect and for Vanguard's transcoding, the
`/gateway` beneath it for grpc-gateway's. Every call after it, from the
same generated code, goes over the other wire form:

```elm examples/notes/elm/src/Main.elm#toggle
SetWire wire ->
    let
        shared =
            model.shared

        ( transport, path ) =
            case wire of
                ViaConnect ->
                    ( Rpc.Transport.connect, "" )

                ViaVanguard ->
                    ( Rpc.Transport.transcode, "" )

                ViaGateway ->
                    ( Rpc.Transport.transcode, "/gateway" )
    in
    list
        { model
            | wire = wire
            , shared = { shared | transport = transport, apiUrl = model.origin ++ path }
        }
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
| `/gateway/…` | the rules' routes and `Ping`'s again, under grpc-gateway (below) |
| `/gateway/layer/1/…` | `routes.v1.Routes.UpdateMessageWhole`, which protoc-gen-grpc-gateway will not generate beside `UpdateMessage` |
| `GET /gateway/routes/layers` | where each binding of `routes.v1.Routes` is served under `/gateway`, as JSON |

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

## Behind grpc-gateway

The server serves the transcoding routes a second time under `/gateway`,
through [grpc-gateway](https://github.com/grpc-ecosystem/grpc-gateway)
v2, so the live suite runs the runtime against both transcoders. A client
of it needs only another `baseUrl`, `http://127.0.0.1:8080/gateway`; the
page's third transport choice, "HTTP transcoding via grpc-gateway", is
that URL (the toggle, above):

```sh
curl -s http://127.0.0.1:8080/gateway/v1/notes/welcome
```

grpc-gateway is a reverse proxy that calls the service over gRPC. buf
generates its Go: grpc-go's client (`protoc-gen-go-grpc`, in
`buf.gen.yaml`) and the proxy, with `generate_unbound_methods=true` so
that `Ping`, which has no rule, is served at its implicit route:

```yaml examples/notes/buf.gen.gateway.yaml
plugins:
  - local: protoc-gen-grpc-gateway
    out: server/gen
    opt:
      - module=github.com/bruckner/elm-connect/examples/notes/server/gen
      - Mroutes.proto=github.com/bruckner/elm-connect/examples/notes/server/gen/routes/v1;routesv1
      - generate_unbound_methods=true
```

`server/gateway.go` registers it on a gateway mux over a gRPC connection
to the server's own address, where connect-go answers, and mounts it with
the prefix stripped, so the rules' paths are served as written beneath it:

```go examples/notes/server/gateway.go
	conn, err := grpc.NewClient(target, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		return err
	}
	ctx := context.Background()
	gateway := runtime.NewServeMux()
	if err := notesv1.RegisterNotesServiceHandler(ctx, gateway, conn); err != nil {
		return err
	}
	if err := routesv1.RegisterRoutesHandler(ctx, gateway, conn); err != nil {
		return err
	}
	mux.Handle(gatewayPrefix+"/", http.StripPrefix(gatewayPrefix, gateway))
```

gRPC needs HTTP/2, which the server accepts without TLS beside HTTP/1.1:

```go examples/notes/server/main.go
	protocols := new(http.Protocols)
	protocols.SetHTTP1(true)
	protocols.SetUnencryptedHTTP2(true)
```

A service error crosses gRPC with its details, and the gateway writes it
as a `google.rpc.Status` body, as Vanguard does, so the runtime reads it
the same way. Where the two transcoders answer differently, an unknown
query parameter, a `FieldMask` in the query, a `/` in a single-segment
path variable, among others, is recorded in
`conformance/live/known-divergent-gateway.json` with a reading of who is
right.
