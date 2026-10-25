module Rpc.Stream.Session exposing
    ( Session, init, State(..), state, latest, liveId
    , Options, Ports, Msg, incoming, update
    , start, stop, reconnectNow
    , Input(..), Effect(..), Timer(..), step
    )

{-| A stream kept open: opened again after it is lost, with a backoff from an
[`Rpc.Retry`](Rpc-Retry) policy, resumed from the latest message, and treated
as lost when no frame arrives for a while. It lives in the application's
model; its options, which hold functions, are given to each update instead.

    type alias Model =
        { feed : Session NoteEvent, … }

    feedOptions : Model -> Session.Options WatchNotesRequest NoteEvent
    feedOptions model =
        { config = configFor model -- headers built now, so a fresh token
        , call = \latest -> watchNotes { after = Maybe.map .index latest |> Maybe.withDefault 0 }
        , retry = Rpc.Retry.on [ Rpc.Code.Unavailable ] |> Rpc.Retry.withAttempts 10
        , idleTimeout = Just 30000
        , reconnectOnEnd = False
        }

    ports : Session.Ports Msg
    ports =
        { out = streamOut, toMsg = FeedMsg }

    -- in update
    FeedMsg sessionMsg ->
        let
            ( feed, cmd, event ) =
                Session.update (feedOptions model) ports sessionMsg model.feed
        in
        ( foldEvent event { model | feed = feed }, cmd )

    -- in subscriptions
    streamIn (FeedMsg << Session.incoming)

@docs Session, init, State, state, latest, liveId
@docs Options, Ports, Msg, incoming, update
@docs start, stop, reconnectNow


# The machine

[`update`](#update) runs this pure machine's effects as commands; tests, and
an application that runs effects itself, drive it directly.

@docs Input, Effect, Timer, step

-}

import Dict
import Json.Decode as Decode
import Json.Encode as Encode
import Process
import Rpc
import Rpc.Body
import Rpc.Error as Error exposing (Error)
import Rpc.Retry exposing (Retry)
import Rpc.Stream as Stream exposing (Event(..), StreamCall)
import Task
import Time


{-| What a session is doing:

  - `Connecting`: a stream is open, no status yet.
  - `Open`: the server answered 200; messages may be arriving.
  - `Waiting ms`: lost, opening again after `ms` milliseconds.
  - `Closed err`: stopped, by the application or the stream's end (`Nothing`),
    or by an error the policy does not retry (`Just err`).

-}
type State
    = Connecting
    | Open
    | Waiting Float
    | Closed (Maybe Error)


{-| A session's state: data only, so it can sit in a model and be compared.
-}
type Session res
    = Session
        { key : String
        , generation : Int
        , tried : Int
        , since : Maybe Time.Posix
        , latest : Maybe res
        , frames : Int
        , state : State
        }


{-| A closed session; streams it opens get ids `key#1`, `key#2`, ….
-}
init : String -> Session res
init key =
    Session { key = key, generation = 0, tried = 0, since = Nothing, latest = Nothing, frames = 0, state = Closed Nothing }


{-| What the session is doing.
-}
state : Session res -> State
state (Session s) =
    s.state


{-| The latest message received, across reconnects: the resume cursor.
-}
latest : Session res -> Maybe res
latest (Session s) =
    s.latest


{-| The id of the stream open now, if one is.
-}
liveId : Session res -> Maybe String
liveId (Session s) =
    case s.state of
        Connecting ->
            Just (streamId s)

        Open ->
            Just (streamId s)

        _ ->
            Nothing


streamId : { r | key : String, generation : Int } -> String
streamId s =
    s.key ++ "#" ++ String.fromInt s.generation


{-| How to open and reopen the stream, read at every update so that the config
(and its credentials) and the resume request are current:

  - `config`: where, and the headers each opening sends.
  - `call`: the call to open, from the latest message received (`Nothing` at
    first): a resume cursor is derived from it.
  - `retry`: when to reopen after an error, and after how long. The call's
    idempotency gates it as for a unary call, so a watch method should be
    declared `NO_SIDE_EFFECTS`.
  - `idleTimeout`: with no frame for this many milliseconds the stream is
    treated as lost (`NoAnswer Timeout`) and the policy decides.
  - `reconnectOnEnd`: open again after a clean end, as after an error with
    code `Unavailable`, for a stream the server may end at will (a transcoder
    may also hide an error behind a clean end).

-}
type alias Options req res =
    { config : Rpc.Config
    , call : Maybe res -> StreamCall req res
    , retry : Retry
    , idleTimeout : Maybe Float
    , reconnectOnEnd : Bool
    }


{-| The application's outgoing port and its message for the session.
-}
type alias Ports msg =
    { out : Encode.Value -> Cmd msg
    , toMsg : Msg -> msg
    }


{-| A session's message.
-}
type Msg
    = Run Input
    | Clock Error Time.Posix


{-| An event from the incoming port, as a message for the session.
-}
incoming : Decode.Value -> Msg
incoming value =
    Run (Incoming value)


{-| Open the stream.
-}
start : Msg
start =
    Run Start


{-| Cancel the stream and close the session.
-}
stop : Msg
stop =
    Run Stop


{-| Cancel any stream and open a new one at once, forgetting the backoff: for
"the network is back" or "the tab is visible again".
-}
reconnectNow : Msg
reconnectNow =
    Run ReconnectNow


{-| The machine's inputs.
-}
type Input
    = Start
    | Stop
    | ReconnectNow
    | Incoming Decode.Value
    | Fired Timer
    | FailedAt Error Time.Posix


{-| A timer the machine asked for, reported back as `Fired`: reopen the
stream of a generation, or check that a stream of a generation has had no
frame since its `n`th.
-}
type Timer
    = Reopen Int
    | Idle Int Int


{-| What the machine asks for:

  - `Send value`: send it through the outgoing port.
  - `After ms timer`: report `Fired timer` after `ms` milliseconds.
  - `NeedTime err`: report `FailedAt err now`; the backoff's jitter is drawn
    from the time.
  - `Deliver event`: an event for the application.

-}
type Effect res
    = Send Encode.Value
    | After Float Timer
    | NeedTime Error
    | Deliver (Event res)


{-| One step of the machine.
-}
step : Options req res -> Input -> Session res -> ( Session res, List (Effect res) )
step options input ((Session s) as session) =
    case input of
        Start ->
            openNext options { s | tried = 0, since = Nothing }

        ReconnectNow ->
            let
                ( next, effects ) =
                    openNext options { s | tried = 0, since = Nothing }
            in
            ( next, cancelLive s ++ effects )

        Stop ->
            ( Session { s | generation = s.generation + 1, state = Closed Nothing }, cancelLive s )

        Incoming value ->
            case Decode.decodeValue Stream.eventId value of
                Ok id ->
                    if id == streamId s && live s then
                        case Decode.decodeValue (Stream.event (options.call s.latest)) value of
                            Ok event ->
                                received options event s

                            Err problem ->
                                ( session, [ NeedTime (Error.BadResponse (Decode.errorToString problem) emptyAnswer) ] )

                    else
                        ( session, [] )

                Err _ ->
                    ( session, [] )

        Fired (Reopen generation) ->
            case s.state of
                Waiting _ ->
                    if generation == s.generation then
                        openNext options s

                    else
                        ( session, [] )

                _ ->
                    ( session, [] )

        Fired (Idle generation frames) ->
            if generation == s.generation && frames == s.frames && live s then
                ( Session { s | generation = s.generation + 1, state = Waiting 0 }
                , cancelLive s ++ [ NeedTime (Error.NoAnswer Error.Timeout) ]
                )

            else
                ( session, [] )

        FailedAt err now ->
            let
                started =
                    Maybe.withDefault now s.since

                tried =
                    s.tried + 1

                wait =
                    Rpc.Retry.next options.retry
                        { tried = tried
                        , code = Error.code err
                        , idempotency = Stream.idempotency (options.call s.latest)
                        , now = now
                        , elapsed = toFloat (Time.posixToMillis now - Time.posixToMillis started)
                        }
            in
            case wait of
                Just ms ->
                    ( Session { s | tried = tried, since = Just started, state = Waiting ms }
                    , [ After ms (Reopen s.generation) ]
                    )

                Nothing ->
                    ( Session { s | tried = tried, state = Closed (Just err) }, [ Deliver (Failed err) ] )


live : { r | state : State } -> Bool
live s =
    s.state == Connecting || s.state == Open


cancelLive : { r | key : String, generation : Int, state : State } -> List (Effect res)
cancelLive s =
    if live s then
        [ Send (Stream.cancel (streamId s)) ]

    else
        []


openNext : Options req res -> { key : String, generation : Int, tried : Int, since : Maybe Time.Posix, latest : Maybe res, frames : Int, state : State } -> ( Session res, List (Effect res) )
openNext options s =
    let
        next =
            { s | generation = s.generation + 1, state = Connecting }
    in
    case Stream.open options.config { id = streamId next, call = options.call s.latest } of
        Ok command ->
            ( Session next, Send command :: idleTimer options next )

        Err err ->
            ( Session { next | state = Closed (Just err) }, [ Deliver (Failed err) ] )


idleTimer : Options req res -> { r | generation : Int, frames : Int } -> List (Effect res)
idleTimer options s =
    case options.idleTimeout of
        Just ms ->
            [ After ms (Idle s.generation s.frames) ]

        Nothing ->
            []


received : Options req res -> Event res -> { key : String, generation : Int, tried : Int, since : Maybe Time.Posix, latest : Maybe res, frames : Int, state : State } -> ( Session res, List (Effect res) )
received options event s =
    let
        framed =
            { s | frames = s.frames + 1 }
    in
    case event of
        Opened { status } ->
            ( Session
                { framed
                    | state =
                        if status == 200 then
                            Open

                        else
                            s.state
                }
            , Deliver event :: idleTimer options framed
            )

        Message res ->
            ( Session { framed | latest = Just res, tried = 0, since = Nothing, state = Open }
            , Deliver event :: idleTimer options framed
            )

        Ended _ ->
            if options.reconnectOnEnd then
                ( Session { framed | generation = s.generation + 1, state = Waiting 0 }
                , [ Deliver event, NeedTime (Error.NoAnswer Error.NetworkError) ]
                )

            else
                ( Session { framed | state = Closed Nothing }, [ Deliver event ] )

        Failed err ->
            ( Session { framed | generation = s.generation + 1, state = Waiting 0 }, [ NeedTime err ] )


emptyAnswer : Rpc.Response
emptyAnswer =
    { url = "", statusCode = 200, statusText = "", headers = Dict.empty, body = Rpc.Body.text "" }


{-| Run one message: the new session, the commands its effects stand for, and
the event for the application, if one came (a `Failed` only once the policy
has given up; the errors it retries are not delivered).
-}
update : Options req res -> Ports msg -> Msg -> Session res -> ( Session res, Cmd msg, Maybe (Event res) )
update options ports msg session =
    let
        ( next, effects ) =
            case msg of
                Run input ->
                    step options input session

                Clock err now ->
                    step options (FailedAt err now) session
    in
    ( next
    , Cmd.batch (List.map (run ports) effects)
    , List.foldl
        (\effect found ->
            case effect of
                Deliver event ->
                    Just event

                _ ->
                    found
        )
        Nothing
        effects
    )


run : Ports msg -> Effect res -> Cmd msg
run ports effect =
    case effect of
        Send value ->
            ports.out value

        After ms timer ->
            Task.perform (\_ -> ports.toMsg (Run (Fired timer))) (Process.sleep ms)

        NeedTime err ->
            Task.perform (ports.toMsg << Clock err) Time.now

        Deliver _ ->
            Cmd.none
