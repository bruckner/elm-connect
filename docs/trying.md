# Trying a call

Before you have a server of your own, call someone else's. ConnectRPC's
public demo server, `https://demo.connectrpc.com`, runs the Eliza
service, `connectrpc.eliza.v1.ElizaService`, with CORS open to any page.
This page builds a browser page that sends its unary method, `Say`. It
needs the CLI and the runtime as [install.md](install.md) says, and no
server; the finished program is [`examples/eliza`](../examples/eliza).
A Connect unary call is a JSON `POST` to the method's path:

```sh
curl -X POST https://demo.connectrpc.com/connectrpc.eliza.v1.ElizaService/Say \
  -H 'content-type: application/json' -d '{"sentence":"hi"}'
```

The server answers `{"sentence":"Hello, how are you feeling today?"}`,
or another of Eliza's replies.

## 1. The proto

ConnectRPC publishes `eliza.proto` with its Go examples. In a new
directory:

```sh
mkdir -p proto/connectrpc/eliza/v1
curl -fL -o proto/connectrpc/eliza/v1/eliza.proto \
  https://raw.githubusercontent.com/connectrpc/examples-go/main/proto/connectrpc/eliza/v1/eliza.proto
```

or, with buf, `buf export buf.build/connectrpc/eliza -o proto`.

## 2. Generate

```sh
elm-connect gen -I proto connectrpc/eliza/v1/eliza.proto --streaming skip --out generated
```

The service's streaming methods, `Introduce` and `Converse`, are out of
scope: elm-connect generates unary calls only, and `--streaming skip`
leaves them out with a warning rather than an error (server streaming
is on the [roadmap](roadmap.md)). `Say` becomes:

```elm examples/eliza/generated/Connectrpc/Eliza/V1/ElizaService.elm excerpt
say : Connectrpc.Eliza.V1.SayRequest -> Rpc.Call Connectrpc.Eliza.V1.SayRequest Connectrpc.Eliza.V1.SayResponse
```

## 3. The page

An `elm.json` as [install.md](install.md#the-runtime) shows it, with
`src`, `generated` and the runtime clone's `src` as source directories,
and `src/Main.elm`, which sends what was typed and shows the reply or
the error's text:

```elm examples/eliza/src/Main.elm#main
module Main exposing (main)

import Browser
import Connectrpc.Eliza.V1
import Connectrpc.Eliza.V1.ElizaService as ElizaService
import Html exposing (Html)
import Html.Attributes as Attributes
import Html.Events as Events
import Rpc
import Rpc.Error


type alias Model =
    { sentence : String
    , reply : String
    }


type Msg
    = Typed String
    | Asked
    | GotReply (Result Rpc.Error Connectrpc.Eliza.V1.SayResponse)


main : Program () Model Msg
main =
    Browser.element
        { init = \_ -> ( { sentence = "", reply = "" }, Cmd.none )
        , update = update
        , view = view
        , subscriptions = \_ -> Sub.none
        }


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        Typed sentence ->
            ( { model | sentence = sentence }, Cmd.none )

        Asked ->
            ( model
            , ElizaService.say { sentence = model.sentence }
                |> Rpc.send (Rpc.config "https://demo.connectrpc.com") GotReply
            )

        GotReply (Ok response) ->
            ( { model | reply = response.sentence }, Cmd.none )

        GotReply (Err error) ->
            ( { model | reply = Rpc.Error.toString error }, Cmd.none )


view : Model -> Html Msg
view model =
    Html.form [ Events.onSubmit Asked ]
        [ Html.input [ Attributes.value model.sentence, Events.onInput Typed ] []
        , Html.button [] [ Html.text "Say" ]
        , Html.p [] [ Html.text model.reply ]
        ]
```

## 4. Build and open

```sh
elm make src/Main.elm --output=index.html
```

and open `index.html`, from the disk or any local server. Type a
sentence and press Say: the network tab shows a preflight `OPTIONS`, the
`POST` to `/connectrpc.eliza.v1.ElizaService/Say`, and the page shows
Eliza's reply. [quickstart.md](quickstart.md) goes on to reading errors and
testing without a server.

## Over transcoding, from a file server

Over `Rpc.Transport.transcode`, a method with a `get` rule is a plain
`GET` of the rule's path, so a static file server answers it with a JSON
file there. Eliza has no rules; the quick start's `GetNote`,
`get: "/v1/{name=notes/*}"`, sends `GET /v1/notes/42`. With a page
making that call (the quick start's `viaTranscoding`, base URL
`http://127.0.0.1:8000`) built as `index.html`:

```sh
mkdir -p site/v1/notes
echo '{"name": "notes/42", "title": "Milk"}' > site/v1/notes/42
cp index.html site/
python3 -m http.server 8000 -d site
```

and open `http://127.0.0.1:8000`. The page comes from the same server
because `http.server` sends no CORS headers. The runtime reads the body
whatever its content type (here `application/octet-stream`). Any other
method gets 501, so other rules need a real transcoder, such as
[Envoy](envoy.md#for-your-own-service).
