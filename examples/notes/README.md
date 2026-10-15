# The notes example

A small API, `notes.v1.NotesService`, served by a Go server over the
Connect protocol and over HTTP transcoding from one port, with the Elm
client elm-connect generates for it. The live suite
(`conformance/live/`, `just live`) runs the runtime against this server.

```
proto/notes/v1/notes.proto   the API; its comments document each method's errors
routes/                      a link to conformance/routes: the route fixtures' API, served too
buf.yaml, buf.lock           the modules; googleapis comes from the Buf Schema Registry
buf.gen.yaml                 Go stubs into server/gen, Elm into elm/generated
server/                      the Go server (connect-go and Vanguard); routes.go echoes routes.v1
elm/generated/               the generated Elm client
```

## Running the server

From the repository root, with the tools `mise install` provides:

```sh
cd examples/notes/server
go run . -addr 127.0.0.1:8080
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

## Regenerating

`just live-gen` builds the plugins (`protoc-gen-go` and
`protoc-gen-connect-go` at the versions `server/go.mod` pins as tools,
`protoc-gen-elm-connect` from this workspace) and runs `buf generate`
here, then fails if the output differs from what is committed. buf hands
the plugins `google/api/annotations.proto` and `google/api/http.proto`
from the googleapis dependency as imports only, so nothing is generated
for them, and the Elm plugin reads the `google.api.http` rules from the
imported descriptors; no `--include-imports` is needed.

A browser application over either transport, with a walkthrough, is the
next step for this example.
