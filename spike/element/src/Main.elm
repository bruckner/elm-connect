module Main exposing (main)

{-| Eliza's Introduce through `<connect-stream>` instead of ports: the
Session still decides when a stream is open and with which id, and the view
renders the element for it; no ports, and the Session's Send effects are
dropped because the view carries them.
-}

import Browser
import Connectrpc.Eliza.V1
import Connectrpc.Eliza.V1.ElizaService as ElizaService
import Html exposing (Html)
import Html.Attributes as Attributes
import Html.Events as Events
import Html.Keyed
import Rpc
import Rpc.Error
import Rpc.Retry
import Rpc.Stream exposing (Event(..))
import Rpc.Stream.Element
import Rpc.Stream.Session as Session exposing (Session)


type alias Model =
    { name : String
    , token : Int
    , shown : Bool
    , introduction : List String
    , session : Session Connectrpc.Eliza.V1.IntroduceResponse
    }


type Msg
    = Named String
    | Introduce
    | Cancel
    | Toggle
    | Introducing Session.Msg


main : Program () Model Msg
main =
    Browser.element
        { init = \_ -> ( { name = "", token = 0, shown = True, introduction = [], session = Session.init "introduce" }, Cmd.none )
        , update = update
        , view = view
        , subscriptions = \_ -> Sub.none
        }


introduction : Model -> Session.Options Connectrpc.Eliza.V1.IntroduceRequest Connectrpc.Eliza.V1.IntroduceResponse
introduction model =
    let
        base =
            Rpc.config "https://demo.connectrpc.com"
    in
    { config = { base | headers = [ ( "Authorization", "Bearer secret-" ++ String.fromInt model.token ) ] }
    , call = \_ -> ElizaService.introduce { name = model.name }
    , retry = Rpc.Retry.on []
    , idleTimeout = Just 10000
    , reconnectOnEnd = False
    }


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        Named name ->
            ( { model | name = name }, Cmd.none )

        Introduce ->
            introducing Session.start { model | introduction = [] }

        Cancel ->
            introducing Session.stop model

        Toggle ->
            ( { model | shown = not model.shown }, Cmd.none )

        Introducing sessionMsg ->
            introducing sessionMsg model


introducing : Session.Msg -> Model -> ( Model, Cmd Msg )
introducing sessionMsg model =
    let
        ( session, cmd, event ) =
            Session.update (introduction model) { out = \_ -> Cmd.none, toMsg = Introducing } sessionMsg model.session

        said =
            case event of
                Just (Message response) ->
                    [ response.sentence ]

                Just (Failed error) ->
                    [ Rpc.Error.toString error ]

                _ ->
                    []
    in
    -- Every update bumps the token, as a refreshed credential would.
    ( { model | session = session, introduction = model.introduction ++ said, token = model.token + 1 }, cmd )


view : Model -> Html Msg
view model =
    let
        options =
            introduction model

        command =
            Session.liveId model.session
                |> Maybe.andThen (\id -> Rpc.Stream.open options.config { id = id, call = options.call (Session.latest model.session) } |> Result.toMaybe)
    in
    Html.div []
        [ Html.form [ Events.onSubmit Introduce ]
            [ Html.input [ Attributes.value model.name, Events.onInput Named ] []
            , Html.button [] [ Html.text "Introduce" ]
            , Html.button [ Attributes.type_ "button", Events.onClick Cancel ] [ Html.text "Cancel" ]
            , Html.button [ Attributes.type_ "button", Attributes.id "toggle", Events.onClick Toggle ] [ Html.text "Hide/show" ]
            ]
        , Html.Keyed.node "div"
            []
            (if model.shown then
                [ ( "stream", Rpc.Stream.Element.view { command = command, onEvent = Introducing << Session.incoming } ) ]

             else
                []
            )
        , Html.p [ Attributes.id "state" ] [ Html.text (Debug.toString (Session.state model.session)) ]
        , Html.ol [] (List.map (\line -> Html.li [] [ Html.text line ]) model.introduction)
        ]
