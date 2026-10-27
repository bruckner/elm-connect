-- The Eliza example over Connect proto at the stack head, generated with
-- codec=binary: the before side of H2.


module Main exposing (main)

import Browser
import Connectrpc.Eliza.V1
import Connectrpc.Eliza.V1.ElizaService as ElizaService
import Html exposing (Html)
import Html.Attributes as Attributes
import Html.Events as Events
import Rpc
import Rpc.Error
import Rpc.Transport


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
                |> Rpc.send (let c = Rpc.config "https://demo.connectrpc.com" in { c | transport = Rpc.Transport.withCodec Rpc.Transport.Proto Rpc.Transport.connect }) GotReply
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



