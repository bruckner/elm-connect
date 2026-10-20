port module Live exposing (main)

{-| The live runner: a headless program that sends the calls `run.mjs` gives
it over the `requests` port with the runtime, and answers each over `results`
with the outcome and the trace. The envelope and result formats are in
`conformance/README.md`.
-}

import Dict exposing (Dict)
import Http
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode exposing (Value)
import Live.Call exposing (Entry, Envelope, Outcome, Sending(..), Transport(..))
import Live.Conformance
import Live.Notes
import Live.Routes
import Process
import Rpc
import Rpc.Code
import Rpc.Retry
import Rpc.Transport
import Set exposing (Set)
import Task


port requests : (Value -> msg) -> Sub msg


port results : Value -> Cmd msg


{-| Every method the runner can call, from every dispatch table.
-}
tables : Dict ( String, String ) (Entry Msg)
tables =
    Dict.fromList (Live.Notes.table ++ Live.Conformance.table ++ Live.Routes.table)


main : Program () Model Msg
main =
    Platform.worker
        { init = \() -> ( { inFlight = Set.empty, progress = Dict.empty }, Cmd.none )
        , update = update
        , subscriptions = subscriptions
        }


{-| The ids of the calls in flight, and the progress seen so far of each with
a tracker, by its id.

A call is reported once, by the first outcome: a cancelled call can have two,
its result and the cancellation the runner records, when the answer comes in
before the cancellation runs, and the later is dropped.

-}
type alias Model =
    { inFlight : Set String, progress : Dict String Progress }


type alias Progress =
    { tracker : String, sending : Int, receiving : Int }


type Msg
    = Received Value
    | Finished Outcome
    | Tracked String Http.Progress
    | CancelDue String (Cmd Msg)


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        Received json ->
            case Decode.decodeValue envelope json of
                Err problem ->
                    ( model
                    , refuse
                        (Decode.decodeValue (Decode.field "id" Decode.string) json |> Result.withDefault "")
                        ("the envelope does not decode: " ++ Decode.errorToString problem)
                    )

                Ok e ->
                    case Dict.get ( e.service, e.method ) tables of
                        Nothing ->
                            ( model, refuse e.id ("no method " ++ e.service ++ "/" ++ e.method) )

                        Just send ->
                            case send e Finished of
                                Ok sent ->
                                    ( { inFlight = Set.insert e.id model.inFlight
                                      , progress =
                                            case e.tracker of
                                                Just name ->
                                                    Dict.insert e.id { tracker = name, sending = 0, receiving = 0 } model.progress

                                                Nothing ->
                                                    model.progress
                                      }
                                    , case ( sent.cancel, e.cancelAfter ) of
                                        ( Just cancel, Just ms ) ->
                                            Cmd.batch
                                                [ sent.send
                                                , Process.sleep (toFloat ms) |> Task.perform (\() -> CancelDue e.id cancel)
                                                ]

                                        _ ->
                                            sent.send
                                    )

                                Err problem ->
                                    ( model, refuse e.id problem )

        Finished outcome ->
            if Set.member outcome.id model.inFlight then
                report outcome model

            else
                ( model, Cmd.none )

        CancelDue id cancel ->
            ( model
            , if Set.member id model.inFlight then
                cancel

              else
                Cmd.none
            )

        Tracked id progress ->
            ( { model
                | progress =
                    Dict.update id
                        (Maybe.map
                            (\seen ->
                                case progress of
                                    Http.Sending _ ->
                                        { seen | sending = seen.sending + 1 }

                                    Http.Receiving _ ->
                                        { seen | receiving = seen.receiving + 1 }
                            )
                        )
                        model.progress
              }
            , Cmd.none
            )


report : Outcome -> Model -> ( Model, Cmd Msg )
report outcome model =
    ( { inFlight = Set.remove outcome.id model.inFlight, progress = Dict.remove outcome.id model.progress }
    , results
        (Encode.object
            ([ ( "id", Encode.string outcome.id )
             , ( "result", outcome.result )
             , ( "trace", outcome.trace )
             , ( "response", outcome.response )
             ]
                ++ (case Dict.get outcome.id model.progress of
                        Just progress ->
                            [ ( "progress"
                              , Encode.object
                                    [ ( "sending", Encode.int progress.sending )
                                    , ( "receiving", Encode.int progress.receiving )
                                    ]
                              )
                            ]

                        Nothing ->
                            []
                   )
            )
        )
    )


subscriptions : Model -> Sub Msg
subscriptions model =
    Sub.batch
        (requests Received
            :: List.map (\( id, seen ) -> Http.track seen.tracker (Tracked id)) (Dict.toList model.progress)
        )


{-| The result of an envelope that could not be sent.
-}
refuse : String -> String -> Cmd msg
refuse id problem =
    results
        (Encode.object
            [ ( "id", Encode.string id )
            , ( "result", Encode.object [ ( "runner", Encode.string problem ) ] )
            , ( "trace", Encode.null )
            ]
        )



-- ENVELOPES


envelope : Decoder Envelope
envelope =
    Decode.field "transport" transport
        |> Decode.andThen
            (\t ->
                Decode.succeed Envelope
                    |> with (Decode.field "id" Decode.string)
                    |> with (Decode.field "service" Decode.string)
                    |> with (Decode.field "method" Decode.string)
                    |> with (optional "request" Decode.value (Encode.object []))
                    |> with (Decode.succeed t)
                    |> with (Decode.field "config" (config t))
                    |> with (optional "binding" (Decode.nullable Decode.int) Nothing)
                    |> with (optional "headers" (Decode.list pair) [])
                    |> with (optional "rewrite" (Decode.list pair) [])
                    |> with (optional "send" sending Traced)
                    |> with (optional "tracker" (Decode.nullable Decode.string) Nothing)
                    |> with (optional "cancelAfterMs" (Decode.nullable Decode.int) Nothing)
            )


with : Decoder a -> Decoder (a -> b) -> Decoder b
with =
    Decode.map2 (|>)


transport : Decoder Transport
transport =
    oneOfNames "transport" [ ( "connect", Connect ), ( "transcode", Transcode ) ]


sending : Decoder Sending
sending =
    oneOfNames "send" [ ( "sendTraced", Traced ), ( "send", Plain ), ( "task", AsTask ), ( "halves", Halves ), ( "taskFromRequest", FromRequest ) ]


oneOfNames : String -> List ( String, a ) -> Decoder a
oneOfNames what names =
    Decode.string
        |> Decode.andThen
            (\name ->
                case List.filter (\( n, _ ) -> n == name) names of
                    ( _, value ) :: _ ->
                        Decode.succeed value

                    [] ->
                        Decode.fail ("no " ++ what ++ " " ++ name)
            )


config : Transport -> Decoder Rpc.Config
config t =
    Decode.map8
        (\baseUrl headers timeout withCredentials useGet maxGetUrl readMaxBytes retry ->
            { transport =
                (case t of
                    Connect ->
                        connectTransport useGet maxGetUrl

                    Transcode ->
                        Rpc.Transport.transcode
                )
                    |> (Maybe.map Rpc.Transport.withReadMaxBytes readMaxBytes |> Maybe.withDefault identity)
            , baseUrl = baseUrl
            , headers = headers
            , timeout = timeout
            , withCredentials = withCredentials
            , retry = retry
            }
        )
        (Decode.field "baseUrl" Decode.string)
        (optional "headers" (Decode.list pair) [])
        (optional "timeout" (Decode.nullable Decode.float) Nothing)
        (optional "withCredentials" Decode.bool False)
        (optional "useGet" Decode.bool False)
        (optional "maxGetUrl" (Decode.nullable Decode.int) Nothing)
        (optional "readMaxBytes" (Decode.nullable Decode.int) Nothing)
        (optional "retry" (Decode.nullable retryPolicy) Nothing)


pair : Decoder ( String, String )
pair =
    Decode.map2 Tuple.pair
        (Decode.index 0 Decode.string)
        (Decode.index 1 Decode.string)


{-| The Connect transport an envelope's `useGet` and `maxGetUrl` describe.
-}
connectTransport : Bool -> Maybe Int -> Rpc.Transport.Transport
connectTransport useGet maxGetUrl =
    let
        connectOrGet =
            if useGet then
                Rpc.Transport.connectGet

            else
                Rpc.Transport.connect
    in
    case maxGetUrl of
        Just limit ->
            Rpc.Transport.withMaxGetUrl limit connectOrGet

        Nothing ->
            connectOrGet


{-| A retry policy as a case writes it: `codes` and `attempts`, `backoff`
(default 0), `maxBackoff` (default the runtime's), `idempotentOnly` (default
false) and `jitter` (default false), so a case's waits are the bounds it
states unless it asks for jitter.
-}
retryPolicy : Decoder Rpc.Retry.Retry
retryPolicy =
    Decode.map6
        (\codes attempts backoff maxBackoff idempotentOnly jitter ->
            Rpc.Retry.on codes
                |> Rpc.Retry.withAttempts attempts
                |> Rpc.Retry.withBackoff backoff
                |> (Maybe.map Rpc.Retry.withMaxBackoff maxBackoff |> Maybe.withDefault identity)
                |> (if idempotentOnly then
                        identity

                    else
                        Rpc.Retry.allowNonIdempotent
                   )
                |> (if jitter then
                        identity

                    else
                        Rpc.Retry.withoutJitter
                   )
        )
        (Decode.field "codes" (Decode.list errorCode))
        (Decode.field "attempts" Decode.int)
        (optional "backoff" Decode.float 0)
        (optional "maxBackoff" (Decode.map Just Decode.float) Nothing)
        (optional "idempotentOnly" Decode.bool False)
        (optional "jitter" Decode.bool False)


errorCode : Decoder Rpc.Code.Code
errorCode =
    Decode.string
        |> Decode.andThen
            (\name ->
                case Rpc.Code.fromString name of
                    Just code ->
                        Decode.succeed code

                    Nothing ->
                        Decode.fail ("no error code " ++ name)
            )


{-| The field's value, or the default when the field is absent; a field that
is present must decode.
-}
optional : String -> Decoder a -> a -> Decoder a
optional key decoder default =
    Decode.maybe (Decode.field key Decode.value)
        |> Decode.andThen
            (\found ->
                case found of
                    Nothing ->
                        Decode.succeed default

                    Just _ ->
                        Decode.field key decoder
            )
