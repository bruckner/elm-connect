# Quick start

From a proto with one service to a call sent from Elm, then the same
call checked in `elm repl` and in a test, with no server. It assumes the
binaries and the runtime are installed as [install.md](install.md) says.

## 1. A proto

The notes example's API, `notes.v1.NotesService`, in
`proto/notes/v1/notes.proto`. Two of its methods, from a file that also
declares their messages and imports `google/protobuf/empty.proto`:

```proto examples/notes/proto/notes/v1/notes.proto excerpt
syntax = "proto3";

package notes.v1;

import "google/api/annotations.proto";

service NotesService {
  rpc GetNote(GetNoteRequest) returns (Note) {
    option idempotency_level = NO_SIDE_EFFECTS;
    option (google.api.http) = {get: "/v1/{name=notes/*}"};
  }
  rpc Ping(google.protobuf.Empty) returns (google.protobuf.Empty) {
    option idempotency_level = NO_SIDE_EFFECTS;
  }
}
```

`GetNote` has a `google.api.http` rule, so over transcoding it is
`GET /v1/notes/<id>`. `Ping` has none, and is sent on the implicit
route ([transcoding.md](transcoding.md#methods-without-an-http-rule)).

The whole file is
[`examples/notes/proto/notes/v1/notes.proto`](https://github.com/bruckner/elm-connect/blob/0.1.0/examples/notes/proto/notes/v1/notes.proto).
To follow along, fetch it into the layout the commands below assume:

```sh
mkdir -p proto/notes/v1
curl -fL -o proto/notes/v1/notes.proto \
  https://raw.githubusercontent.com/bruckner/elm-connect/0.1.0/examples/notes/proto/notes/v1/notes.proto
```

The CLI carries the `google/api` files the proto imports, and the
`google/protobuf` ones map to the runtime, so `notes.proto` is the only
file it needs. protoc and buf need the googleapis files as well
([install.md](install.md#googleapis)).

## 2. Generate

With the CLI, naming the proto by its path under the include directory:

```sh
elm-connect gen -I proto notes/v1/notes.proto --out generated
```

or with buf, from a `buf.gen.yaml` naming the plugin
([install.md](install.md#with-buf)):

```sh
buf generate
```

Both write the same modules: `Notes.V1`, the types and their JSON
codecs; `Notes.V1.NotesService`, one function per method; and a module of
descriptors per message and enum, such as `Notes.V1.Note`. Each method's
function gives a call:

```elm examples/notes/elm/generated/Notes/V1/NotesService.elm excerpt
getNote : Notes.V1.GetNoteRequest -> Rpc.Call Rpc.Json Notes.V1.GetNoteRequest Notes.V1.Note
ping : () -> Rpc.Call Rpc.Json () ()
```

`Rpc.Json` is the call's codec: its messages travel as proto3 JSON, the
generator's default ([calling.md](calling.md#choosing-the-codec)).
[generator.md](generator.md) lists what each proto construct becomes.

## 3. Add the runtime

Put `generated` and the runtime's `src` in the application's
`source-directories`, with its dependencies, as
[install.md](install.md#the-runtime) shows.

## 4. Send a call

A call is data: the method and its request. A client says where to
send it and over which protocol. `Rpc.send` sends a call with a client
and gives the result to a message:

```elm examples/notes/elm/src/Snippets/Sending.elm#sending
import Notes.V1
import Notes.V1.NotesService as Notes
import Rpc
import Rpc.Protocol


type Msg
    = GotNote (Result Rpc.Error Notes.V1.Note)


client : Rpc.Client Rpc.Json
client =
    Rpc.client Rpc.Protocol.connect "https://api.example.com"


viaConnect : Cmd Msg
viaConnect =
    -- POST https://api.example.com/notes.v1.NotesService/GetNote
    Notes.getNote { name = "notes/42" }
        |> Rpc.send client GotNote


viaTranscoding : Cmd Msg
viaTranscoding =
    -- GET https://api.example.com/v1/notes/42
    Notes.getNote { name = "notes/42" }
        |> Rpc.send (Rpc.client Rpc.Protocol.transcode "https://api.example.com") GotNote
```

A message is a record, so build one from its default by record update
rather than as a full record literal: the update keeps compiling when
the message gains a field
([generator.md](generator.md#what-a-proto-becomes)). Elm's record update
takes an unqualified name, and `{ Notes.V1.defaultNote | … }` does not
compile, so bind the default first:

```elm examples/notes/elm/src/Snippets/Sending.elm#building
milk : Notes.V1.Note
milk =
    let
        note =
            Notes.V1.defaultNote
    in
    { note | title = "Milk" }
```

With `import Notes.V1 exposing (defaultNote)`,
`{ defaultNote | title = "Milk" }` is enough.

`Rpc.task` gives a `Task` instead, for chaining calls.

`api.example.com` stands for your server. To send a real call before
you have one, [trying.md](trying.md) builds a page that calls
ConnectRPC's public demo server.

## 5. Read the result

An error is one type for both protocols, `Rpc.Error`, of four kinds:

```elm examples/notes/elm/src/Snippets/Reading.elm#reading
import Notes.V1
import Rpc
import Rpc.Code
import Rpc.Error


type Msg
    = GotNote (Result Rpc.Error Notes.V1.Note)


type alias Model =
    { note : Maybe Notes.V1.Note
    , problem : Maybe String
    }


update : Msg -> Model -> Model
update msg model =
    case msg of
        GotNote (Ok note) ->
            { model | note = Just note, problem = Nothing }

        GotNote (Err error) ->
            { model | problem = Just (describe error) }


describe : Rpc.Error -> String
describe error =
    case error of
        Rpc.Error.RpcStatus status _ ->
            -- The server stated a status: a Connect error body, a
            -- google.rpc.Status body or the grpc-status headers.
            Rpc.Code.toString status.code ++ ": " ++ status.message

        Rpc.Error.HttpStatus response ->
            -- A failure with no status in it, such as a proxy's 502 page.
            "HTTP " ++ String.fromInt response.statusCode

        Rpc.Error.BadResponse problem _ ->
            -- A success whose body is not the response.
            "unexpected answer: " ++ problem

        Rpc.Error.NoAnswer _ ->
            -- A timeout, a network failure, or a call that was never sent.
            Rpc.Error.toString error
```

Most code needs less: every error has a code and a message,
`Rpc.Error.code error` and `Rpc.Error.message error`.
[calling.md](calling.md#errors) has the kinds in full.

## 6. Try it in `elm repl`

`Rpc.request` gives the HTTP request a call stands for, without sending
it. From the application's directory, `elm repl` shows what each
protocol sends:

```text
> import Notes.V1.NotesService as Notes
> import Rpc
> import Rpc.Protocol
> client = Rpc.client Rpc.Protocol.connect "https://api.example.com"
Client { baseUrl = "https://api.example.com", headers = [], protocol = Protocol { codec = "json", name = "connect", options = { get = False, maxGetUrl = Nothing, readMaxBytes = Nothing, writeMaxBytes = Nothing }, wire = Text { build = <function>, message = <function>, overRead = <function>, routed = False, timeoutHeader = <function>, tooLarge = <function> } }, retry = Nothing, timeout = Nothing, withCredentials = False }
    : Rpc.Client Rpc.Protocol.Json
> Rpc.request client (Notes.getNote { name = "notes/42" })
{ body = Text "{\"name\":\"notes/42\"}", headers = [("Connect-Protocol-Version","1")], method = "POST", timeout = Nothing, url = "https://api.example.com/notes.v1.NotesService/GetNote", withCredentials = False }
    : Rpc.Request
> Rpc.request (Rpc.client Rpc.Protocol.transcode "https://api.example.com") (Notes.getNote { name = "notes/42" })
{ body = None, headers = [], method = "GET", timeout = Nothing, url = "https://api.example.com/v1/notes/42", withCredentials = False }
    : Rpc.Request
```

Over Connect the call is a POST to the method's path with the request as
JSON; over transcoding it is the rule's `GET`, the name in the path. A
body is sent as `application/json`, which elm/http adds, so the request's
`headers` do not list `Content-Type`.

## 7. Test without a server

`Rpc.response` is the other half: it reads an `Http.Response String` as
the call's answer. Together the two check a client in elm-test, with no
server and no HTTP. Set up the tests once, from the application's
directory, with [elm-test-rs](https://github.com/mpizenberg/elm-test-rs)
or [elm-test](https://github.com/rtfeldman/node-test-runner):

```sh
elm-test-rs init    # or: elm-test init
```

Either adds `elm-explorations/test` to the `elm.json`'s
`test-dependencies` ([install.md](install.md#the-runtime) shows the
result) and creates `tests/`. A test module in `tests/`, run by
`elm-test-rs` (or `elm-test`):

```elm examples/notes/elm/tests/Snippets/OfflineTest.elm#offline
import Dict
import Expect
import Http
import Notes.V1.NotesService as Notes
import Rpc
import Rpc.Code
import Rpc.Error
import Rpc.Protocol
import Test exposing (Test, describe, test)


client : Rpc.Client Rpc.Json
client =
    Rpc.client Rpc.Protocol.connect "https://api.example.com"


answer : Int -> String -> Http.Response String
answer status body =
    let
        metadata =
            { url = "", statusCode = status, statusText = "", headers = Dict.empty }
    in
    if status == 200 then
        Http.GoodStatus_ metadata body

    else
        Http.BadStatus_ metadata body


suite : Test
suite =
    describe "GetNote"
        [ test "is a POST to its Connect path" <|
            \_ ->
                (Rpc.request client (Notes.getNote { name = "notes/42" })).url
                    |> Expect.equal "https://api.example.com/notes.v1.NotesService/GetNote"
        , test "reads a note" <|
            \_ ->
                answer 200 """{"name": "notes/42", "title": "groceries"}"""
                    |> Rpc.response client (Notes.getNote { name = "notes/42" })
                    |> Result.map .title
                    |> Expect.equal (Ok "groceries")
        , test "reads a Connect error" <|
            \_ ->
                answer 404 """{"code": "not_found", "message": "no such note"}"""
                    |> Rpc.response client (Notes.getNote { name = "notes/42" })
                    |> Result.mapError Rpc.Error.code
                    |> Expect.equal (Err Rpc.Code.NotFound)
        ]
```

## Next

- [calling.md](calling.md): headers, timeouts, retries, Connect GET, the
  errors in full, tracing and cancelling.
- [Outside the browser](calling.md#outside-the-browser): running a
  generated client under Node, against a real server.
- [The notes example](../examples/notes/README.md): a browser
  application on this API, its server, and what each call looks like in
  the network tab.
