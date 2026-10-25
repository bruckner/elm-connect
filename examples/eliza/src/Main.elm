-- region main


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



-- endregion main
