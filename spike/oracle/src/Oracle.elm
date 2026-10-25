port module Oracle exposing (main)

{-| Rpc.Stream and its Session end to end: Elm builds each opening, the JS core
streams it from the notes server, and Elm decodes every event. Each scenario
reports what the session delivered through `report`.
-}

import Dict
import Google.Rpc
import Json.Decode as Decode
import Json.Encode as Encode
import Notes.V1 exposing (NoteEvent, WatchNotesRequest)
import Notes.V1.NotesService exposing (watchNotes)
import Rpc
import Rpc.Code as Code
import Rpc.Error as Error
import Rpc.Retry
import Rpc.Stream exposing (Event(..))
import Rpc.Stream.Session as Session exposing (Session)


port streamOut : Encode.Value -> Cmd msg


port streamIn : (Decode.Value -> msg) -> Sub msg


port report : Encode.Value -> Cmd msg


type alias Flags =
    { baseUrl : String, scenario : String }


type alias Model =
    { flags : Flags, session : Session NoteEvent, log : List String, token : Int }


type Msg
    = Feed Session.Msg


request : String -> Maybe NoteEvent -> WatchNotesRequest
request scenario latest =
    let
        after =
            Maybe.map .index latest |> Maybe.withDefault "0"
    in
    case scenario of
        "fail" ->
            { count = 3, intervalMs = 10, after = after, fail = True }

        "resume" ->
            { count = 2, intervalMs = 10, after = after, fail = False }

        "idle" ->
            { count = 3, intervalMs = 400, after = after, fail = False }

        _ ->
            { count = 3, intervalMs = 10, after = after, fail = False }


options : Model -> Session.Options WatchNotesRequest NoteEvent
options model =
    let
        base =
            Rpc.config model.flags.baseUrl
    in
    { config = { base | headers = [ ( "Authorization", "Bearer " ++ String.fromInt model.token ) ] }
    , call = \latest -> watchNotes (request model.flags.scenario latest)
    , retry =
        Rpc.Retry.on [ Code.Unavailable, Code.DeadlineExceeded ]
            |> Rpc.Retry.withBackoff 20
            |> Rpc.Retry.withAttempts 3
    , idleTimeout =
        if model.flags.scenario == "idle" then
            Just 100

        else
            Just 5000
    , reconnectOnEnd = model.flags.scenario == "resume"
    }


ports : Session.Ports Msg
ports =
    { out = streamOut, toMsg = Feed }


main : Program Flags Model Msg
main =
    Platform.worker
        { init =
            \flags ->
                update (Feed Session.start) { flags = flags, session = Session.init "watch", log = [], token = 1 }
        , update = update
        , subscriptions = \_ -> streamIn (Feed << Session.incoming)
        }


update : Msg -> Model -> ( Model, Cmd Msg )
update (Feed sessionMsg) model =
    let
        ( session, cmd, event ) =
            Session.update (options model) ports sessionMsg model.session

        line =
            Maybe.map describe event

        next =
            { model | session = session, log = model.log ++ (Maybe.map List.singleton line |> Maybe.withDefault []), token = model.token + 1 }

        finished =
            case ( Session.state session, model.flags.scenario, Session.latest session ) of
                ( Session.Closed _, _, _ ) ->
                    True

                ( _, "resume", Just latest ) ->
                    String.toInt latest.index |> Maybe.map (\i -> i >= 6) |> Maybe.withDefault False

                _ ->
                    False
    in
    if finished && Session.state model.session /= Session.Closed Nothing then
        ( next
        , Cmd.batch
            [ cmd
            , Session.liveId session |> Maybe.map (Rpc.Stream.cancel >> streamOut) |> Maybe.withDefault Cmd.none
            , report (Encode.object [ ( "state", Encode.string (stateName (Session.state session)) ), ( "log", Encode.list Encode.string next.log ) ])
            ]
        )

    else
        ( next, cmd )


stateName : Session.State -> String
stateName state =
    case state of
        Session.Connecting ->
            "connecting"

        Session.Open ->
            "open"

        Session.Waiting ms ->
            "waiting " ++ String.fromFloat ms

        Session.Closed Nothing ->
            "closed"

        Session.Closed (Just err) ->
            "closed: " ++ Code.toString (Error.code err)


describe : Event NoteEvent -> String
describe event =
    case event of
        Opened { status } ->
            "opened " ++ String.fromInt status

        Message m ->
            "message " ++ m.index

        Ended { trailers } ->
            "ended " ++ String.join "," (Dict.keys trailers)

        Failed err ->
            "failed "
                ++ Code.toString (Error.code err)
                ++ (case err of
                        Error.RpcStatus status _ ->
                            " "
                                ++ (case status.source of
                                        Error.ConnectEndStream ->
                                            "ConnectEndStream"

                                        _ ->
                                            "other"
                                   )
                                ++ " "
                                ++ String.join "," (List.map .reason (Error.details Google.Rpc.messageErrorInfo err))

                        Error.NoAnswer _ ->
                            " no answer"

                        _ ->
                            ""
                   )
