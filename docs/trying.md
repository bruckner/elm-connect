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

The service's streaming methods, `Introduce` and `Converse`, are left
out with a warning: `--streaming skip` generates the unary `Say` alone.
[A stream](#a-stream) generates `Introduce` too. `Say` becomes:

```elm examples/eliza/generated/Connectrpc/Eliza/V1/ElizaService.elm excerpt
say : Connectrpc.Eliza.V1.SayRequest -> Rpc.Call Connectrpc.Eliza.V1.SayRequest Connectrpc.Eliza.V1.SayResponse
```

## 3. The page

An `elm.json` as [install.md](install.md#the-runtime) shows it, with
`src`, `generated` and the runtime clone's `src` as source directories,
and `src/Main.elm`, which sends what was typed and shows the reply or
the error's text. The page as committed also streams `Introduce`, its
second form, which [A stream](#a-stream) explains; for `Say` alone,
leave out the ports, the second form and every name with `introduc` or
`Session` in it:

```elm examples/eliza/src/Main.elm#main
port module Main exposing (main)

import Browser
import Connectrpc.Eliza.V1
import Connectrpc.Eliza.V1.ElizaService as ElizaService
import Html exposing (Html)
import Html.Attributes as Attributes
import Html.Events as Events
import Json.Decode
import Json.Encode
import Rpc
import Rpc.Error
import Rpc.Retry
import Rpc.Stream exposing (Event(..))
import Rpc.Stream.Session as Session exposing (Session)


port streamOut : Json.Encode.Value -> Cmd msg


port streamIn : (Json.Decode.Value -> msg) -> Sub msg


type alias Model =
    { sentence : String
    , reply : String
    , name : String
    , introduction : List String
    , session : Session Connectrpc.Eliza.V1.IntroduceResponse
    }


type Msg
    = Typed String
    | Asked
    | GotReply (Result Rpc.Error Connectrpc.Eliza.V1.SayResponse)
    | Named String
    | Introduce
    | Cancel
    | Introducing Session.Msg


main : Program () Model Msg
main =
    Browser.element
        { init = \_ -> ( { sentence = "", reply = "", name = "", introduction = [], session = Session.init "introduce" }, Cmd.none )
        , update = update
        , view = view
        , subscriptions = \_ -> streamIn (Introducing << Session.incoming)
        }


config : Rpc.Config
config =
    Rpc.config "https://demo.connectrpc.com"


introduction : Model -> Session.Options Connectrpc.Eliza.V1.IntroduceRequest Connectrpc.Eliza.V1.IntroduceResponse
introduction model =
    { config = config
    , call = \_ -> ElizaService.introduce { name = model.name }
    , retry = Rpc.Retry.on []
    , idleTimeout = Just 10000
    , reconnectOnEnd = False
    }


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        Typed sentence ->
            ( { model | sentence = sentence }, Cmd.none )

        Asked ->
            ( model
            , ElizaService.say { sentence = model.sentence }
                |> Rpc.send config GotReply
            )

        GotReply (Ok response) ->
            ( { model | reply = response.sentence }, Cmd.none )

        GotReply (Err error) ->
            ( { model | reply = Rpc.Error.toString error }, Cmd.none )

        Named name ->
            ( { model | name = name }, Cmd.none )

        Introduce ->
            introducing Session.start { model | introduction = [] }

        Cancel ->
            introducing Session.stop model

        Introducing sessionMsg ->
            introducing sessionMsg model


introducing : Session.Msg -> Model -> ( Model, Cmd Msg )
introducing sessionMsg model =
    let
        ( session, cmd, event ) =
            Session.update (introduction model) { out = streamOut, toMsg = Introducing } sessionMsg model.session

        said =
            case event of
                Just (Message response) ->
                    [ response.sentence ]

                Just (Failed error) ->
                    [ Rpc.Error.toString error ]

                _ ->
                    []
    in
    ( { model | session = session, introduction = model.introduction ++ said }, cmd )


view : Model -> Html Msg
view model =
    Html.div []
        [ Html.form [ Events.onSubmit Asked ]
            [ Html.input [ Attributes.value model.sentence, Events.onInput Typed ] []
            , Html.button [] [ Html.text "Say" ]
            , Html.p [] [ Html.text model.reply ]
            ]
        , Html.form [ Events.onSubmit Introduce ]
            [ Html.input [ Attributes.value model.name, Events.onInput Named, Attributes.placeholder "your name" ] []
            , Html.button [] [ Html.text "Introduce" ]
            , Html.button [ Attributes.type_ "button", Events.onClick Cancel ] [ Html.text "Cancel" ]
            , Html.p [ Attributes.id "state" ] [ Html.text (state (Session.state model.session)) ]
            , Html.ol [] (List.map (\line -> Html.li [] [ Html.text line ]) model.introduction)
            ]
        ]


state : Session.State -> String
state current =
    case current of
        Session.Connecting ->
            "connecting"

        Session.Open ->
            "open"

        Session.Waiting ms ->
            "reconnecting in " ++ String.fromFloat ms ++ " ms"

        Session.Closed Nothing ->
            "closed"

        Session.Closed (Just error) ->
            "closed: " ++ Rpc.Error.toString error
```

## 4. Build and open

```sh
elm make src/Main.elm --output=index.html
```

for the `Say`-only page, and open `index.html`, from the disk or any
local server. Type a
sentence and press Say: the network tab shows a preflight `OPTIONS`, the
`POST` to `/connectrpc.eliza.v1.ElizaService/Say`, and the page shows
Eliza's reply. [quickstart.md](quickstart.md) goes on to reading errors and
testing without a server.

## A stream

`Introduce` is a server stream: given a name, Eliza sends four
sentences about half a second apart and ends the stream. Generate with
`--streaming server` and the method becomes a stream call:

```elm examples/eliza/generated/Connectrpc/Eliza/V1/ElizaService.elm excerpt
introduce : Connectrpc.Eliza.V1.IntroduceRequest -> Rpc.Stream.StreamCall Connectrpc.Eliza.V1.IntroduceRequest Connectrpc.Eliza.V1.IntroduceResponse
```

`--streaming server` still refuses a client or bidirectional stream,
and Eliza's `Converse` is one, so the example generates from a copy of
the proto without it (`spike/eliza-proto`):

```sh
elm-connect gen -I ../../spike/eliza-proto connectrpc/eliza/v1/eliza.proto --streaming server --out generated
```

elm/http hands a program a whole body at once, so a stream is read by
a small JavaScript companion, `runtime/stream.js`, through two ports.
`Rpc.Stream.Session` keeps the stream's state in the model; its
options are read at every (re)open:

```elm examples/eliza/src/Main.elm excerpt
port streamOut : Json.Encode.Value -> Cmd msg


port streamIn : (Json.Decode.Value -> msg) -> Sub msg
introduction : Model -> Session.Options Connectrpc.Eliza.V1.IntroduceRequest Connectrpc.Eliza.V1.IntroduceResponse
introduction model =
    { config = config
    , call = \_ -> ElizaService.introduce { name = model.name }
    , retry = Rpc.Retry.on []
    , idleTimeout = Just 10000
    , reconnectOnEnd = False
    }
```

The form's submit starts the session, the cancel button stops it, and
every session message goes through `Session.update`, which gives the
event to fold, here a sentence to append:

```elm examples/eliza/src/Main.elm excerpt
        Introduce ->
            introducing Session.start { model | introduction = [] }

        Cancel ->
            introducing Session.stop model
introducing : Session.Msg -> Model -> ( Model, Cmd Msg )
introducing sessionMsg model =
    let
        ( session, cmd, event ) =
            Session.update (introduction model) { out = streamOut, toMsg = Introducing } sessionMsg model.session
```

The page loads the compiled program and wires the ports to the
companion (in a project of your own, copy `runtime/stream.js` beside
the page and import `./stream.js`):

```html examples/eliza/index.html
    <script type="module">
      import { createStreams } from "../../runtime/stream.js";

      const app = Elm.Main.init({ node: document.getElementById("app") });
      const streams = createStreams((event) => app.ports.streamIn.send(event));
      app.ports.streamOut.subscribe((command) => streams.run(command));
    </script>
```

A module script does not load from the disk, so serve the repository
and open the page from there:

```sh
elm make src/Main.elm --output=elm.js
python3 -m http.server 8000 -d ../..
```

then `http://127.0.0.1:8000/examples/eliza/`. Type a name and press
Introduce: the state reads `connecting`, then `open` with the first
sentence (the server sends its headers with its first message), the
sentences arrive one by one, and `closed` follows Eliza's end of the
stream. Cancel stops it where it is.

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
