module Rpc.StreamTest exposing (suite)

import Dict
import Expect
import Json.Decode as Decode
import Json.Encode as Encode
import Proto.Method as Method
import Rpc
import Rpc.Code as Code
import Rpc.Error as Error
import Rpc.Retry
import Rpc.Stream as Stream exposing (Event(..))
import Rpc.Stream.Session as Session exposing (Effect(..), Input(..), State(..))
import Rpc.Transport
import Test exposing (Test, describe, test)
import Time


type alias Item =
    { index : Int }


watch : Int -> Stream.StreamCall Int Item
watch after =
    Stream.call
        (Method.serverStreaming Encode.int
            (Decode.map Item (Decode.field "index" Decode.int))
            (Method.descriptor "feed.v1.Feed" "Watch" Method.IdempotencyNoSideEffects "feed.v1.WatchRequest" "feed.v1.Item" [])
        )
        after


decode : String -> Result String (Event Item)
decode json =
    Decode.decodeString (Stream.event (watch 0)) json |> Result.mapError Decode.errorToString


config : Rpc.Config
config =
    let
        base =
            Rpc.config "https://api.example.com"
    in
    { base | headers = [ ( "Authorization", "Bearer t" ) ], timeout = Just 5000 }


openJson : Rpc.Config -> Stream.StreamCall Int Item -> Result Error.Error Decode.Value
openJson cfg c =
    Stream.open cfg { id = "s", call = c }


field : List String -> Decode.Decoder a -> Result Error.Error Decode.Value -> Maybe a
field path decoder result =
    result |> Result.toMaybe |> Maybe.andThen (Decode.decodeValue (Decode.at path decoder) >> Result.toMaybe)


options : Session.Options Int Item
options =
    { config = config
    , call = \last -> watch (Maybe.map .index last |> Maybe.withDefault 0)
    , retry = Rpc.Retry.on [ Code.Unavailable ] |> Rpc.Retry.withoutJitter
    , idleTimeout = Just 1000
    , reconnectOnEnd = False
    }


{-| Feed inputs in order, keeping every effect.
-}
drive : List Input -> ( Session.Session Item, List (List (Effect Item)) )
drive inputs =
    List.foldl
        (\input ( session, effects ) ->
            let
                ( next, these ) =
                    Session.step options input session
            in
            ( next, effects ++ [ these ] )
        )
        ( Session.init "feed", [] )
        inputs


event : String -> List ( String, Encode.Value ) -> Input
event id fields =
    Incoming (Encode.object (( "id", Encode.string id ) :: fields))


message : String -> Int -> Input
message id index =
    event id [ ( "kind", Encode.string "message" ), ( "json", Encode.string ("{\"index\":" ++ String.fromInt index ++ "}") ) ]


opened : String -> Input
opened id =
    event id [ ( "kind", Encode.string "headers" ), ( "status", Encode.int 200 ), ( "headers", Encode.object [] ) ]


sentBody : List (Effect Item) -> List String
sentBody effects =
    List.filterMap
        (\e ->
            case e of
                Send value ->
                    Decode.decodeValue (Decode.at [ "open", "body" ] Decode.string) value |> Result.toMaybe

                _ ->
                    Nothing
        )
        effects


suite : Test
suite =
    describe "Rpc.Stream"
        [ describe "open"
            [ test "a Connect POST with the streaming content type and the call's own timeout" <|
                \_ ->
                    let
                        sent =
                            openJson config (watch 7 |> Stream.withTimeout 250)
                    in
                    Expect.equal
                        ( ( field [ "open", "url" ] Decode.string sent, field [ "open", "framing" ] Decode.string sent, field [ "open", "body" ] Decode.string sent )
                        , ( field [ "open", "headers" ] (Decode.list (Decode.list Decode.string)) sent, field [ "open", "timeoutMs" ] Decode.float sent )
                        )
                        ( ( Just "https://api.example.com/feed.v1.Feed/Watch", Just "connect", Just "7" )
                        , ( Just [ [ "Authorization", "Bearer t" ], [ "Connect-Protocol-Version", "1" ], [ "Connect-Timeout-Ms", "250" ], [ "Content-Type", "application/connect+json" ] ], Just 250 )
                        )
            , test "the config's timeout does not bound a stream" <|
                \_ -> Expect.equal (field [ "open", "timeoutMs" ] (Decode.nullable Decode.float) (openJson config (watch 0))) (Just Nothing)
            , test "never a GET, whatever the transport says" <|
                \_ -> Expect.equal (field [ "open", "method" ] Decode.string (openJson { config | transport = Rpc.Transport.connectGet } (watch 0))) (Just "POST")
            , test "the implicit route over transcoding speaks Connect" <|
                \_ -> Expect.equal (field [ "open", "framing" ] Decode.string (openJson { config | transport = Rpc.Transport.transcode } (watch 0))) (Just "connect")
            , test "an invalid header is an error, nothing sent" <|
                \_ -> Expect.equal (openJson config (watch 0 |> Stream.withHeaders [ ( "X", "a\nb" ) ])) (Err (Error.NoAnswer (Error.InvalidHeader "X")))
            , test "cancel" <|
                \_ -> Expect.equal (Encode.encode 0 (Stream.cancel "s")) "{\"cancel\":\"s\"}"
            ]
        , describe "event"
            [ test "headers" <|
                \_ -> Expect.equal (decode """{"id":"s","kind":"headers","status":200,"headers":{"x":"1"}}""") (Ok (Opened { status = 200, headers = Dict.fromList [ ( "x", "1" ) ] }))
            , test "a message" <|
                \_ -> Expect.equal (decode """{"id":"s","kind":"message","json":"{\\"index\\":3}"}""") (Ok (Message { index = 3 }))
            , test "a clean end with trailers" <|
                \_ -> Expect.equal (decode """{"id":"s","kind":"end","status":200,"error":null,"metadata":{"t":["1","2"]}}""") (Ok (Ended { trailers = Dict.fromList [ ( "t", [ "1", "2" ] ) ] }))
            , test "a Connect end-stream error with a detail" <|
                \_ ->
                    case decode """{"id":"s","kind":"end","status":200,"error":{"code":"failed_precondition","message":"stop","details":[{"type":"google.rpc.ErrorInfo","value":"CgE=","debug":{"reason":"R"}}]},"metadata":{}}""" of
                        Ok (Failed ((Error.RpcStatus status _) as err)) ->
                            Expect.equal ( ( Error.code err, status.message, status.source ), List.length status.details ) ( ( Code.FailedPrecondition, "stop", Error.ConnectEndStream ), 1 )

                        other ->
                            Expect.fail (Debug.toString other)
            , test "a gateway error line is a status body" <|
                \_ ->
                    case decode """{"id":"s","kind":"end","status":200,"error":{"code":9,"message":"stop"},"metadata":{}}""" of
                        Ok (Failed ((Error.RpcStatus status _) as err)) ->
                            Expect.equal ( Error.code err, status.source ) ( Code.FailedPrecondition, Error.StatusBody )

                        other ->
                            Expect.fail (Debug.toString other)
            , test "a non-200 without a status is an HTTP error" <|
                \_ ->
                    case decode """{"id":"s","kind":"end","status":503,"error":null,"body":"busy"}""" of
                        Ok (Failed err) ->
                            Expect.equal (Error.code err) Code.Unavailable

                        other ->
                            Expect.fail (Debug.toString other)
            , test "transport failures" <|
                \_ ->
                    Expect.equal
                        [ decode """{"id":"s","kind":"error","reason":"timeout"}""", decode """{"id":"s","kind":"error","reason":"truncated"}""" ]
                        [ Ok (Failed (Error.NoAnswer Error.Timeout)), Ok (Failed (Error.NoAnswer Error.NetworkError)) ]
            , test "a message its decoder rejects is a bad response" <|
                \_ ->
                    case decode """{"id":"s","kind":"message","json":"{}"}""" of
                        Ok (Failed (Error.BadResponse _ _)) ->
                            Expect.pass

                        other ->
                            Expect.fail (Debug.toString other)
            ]
        , describe "Session"
            [ test "start opens feed#1 and arms the idle timer" <|
                \_ ->
                    let
                        ( session, effects ) =
                            drive [ Start ]
                    in
                    Expect.equal ( Session.state session, Session.liveId session, List.map sentBody effects ) ( Connecting, Just "feed#1", [ [ "0" ] ] )
            , test "messages move the cursor; a stale stream's events are ignored" <|
                \_ ->
                    let
                        ( session, _ ) =
                            drive [ Start, opened "feed#1", message "feed#1" 4, message "feed#0" 99 ]
                    in
                    Expect.equal ( Session.state session, Session.latest session ) ( Open, Just { index = 4 } )
            , test "an Unavailable error waits the backoff, then resumes from the cursor" <|
                \_ ->
                    let
                        ( session, effects ) =
                            drive
                                [ Start
                                , opened "feed#1"
                                , message "feed#1" 4
                                , event "feed#1" [ ( "kind", Encode.string "error" ), ( "reason", Encode.string "network" ) ]
                                , FailedAt (Error.NoAnswer Error.NetworkError) (Time.millisToPosix 1000)
                                ]

                        ( reopened, more ) =
                            Session.step options (Session.Fired (timerOf (List.concat effects))) session
                    in
                    Expect.equal ( Session.state session, Session.state reopened, ( Session.liveId reopened, sentBody more ) ) ( Waiting 200, Connecting, ( Just "feed#3", [ "4" ] ) )
            , test "the policy gives up after its attempts and delivers the error" <|
                \_ ->
                    let
                        err =
                            Error.NoAnswer Error.NetworkError

                        failOnce n =
                            [ event ("feed#" ++ String.fromInt n) [ ( "kind", Encode.string "error" ), ( "reason", Encode.string "network" ) ]
                            , FailedAt err (Time.millisToPosix (1000 * n))
                            ]

                        ( session, effects ) =
                            drive (Start :: failOnce 1)

                        step2 =
                            Session.step options (Session.Fired (timerOf (List.concat effects))) session

                        ( s2, e2 ) =
                            List.foldl (\i ( s, _ ) -> Session.step options i s) step2 (failOnce 3)

                        step3 =
                            Session.step options (Session.Fired (timerOf e2)) s2

                        ( s3, e3 ) =
                            List.foldl (\i ( s, _ ) -> Session.step options i s) step3 (failOnce 5)
                    in
                    Expect.equal ( Session.state s3, e3 ) ( Closed (Just err), [ Deliver (Failed err) ] )
            , test "a code the policy does not retry closes at once" <|
                \_ ->
                    let
                        ( session, _ ) =
                            drive
                                [ Start
                                , event "feed#1" [ ( "kind", Encode.string "end" ), ( "status", Encode.int 200 ), ( "error", Encode.object [ ( "code", Encode.string "permission_denied" ) ] ) ]
                                , FailedAt permissionDenied (Time.millisToPosix 0)
                                ]
                    in
                    Expect.equal (Session.state session) (Closed (Just permissionDenied))
            , test "no frame within the idle timeout cancels and treats the stream as lost" <|
                \_ ->
                    let
                        ( session, effects ) =
                            drive [ Start, opened "feed#1", Session.Fired (Session.Idle 1 1) ]
                    in
                    Expect.equal ( Session.state session, List.drop 2 effects ) ( Waiting 0, [ [ Send (Stream.cancel "feed#1"), NeedTime (Error.NoAnswer Error.Timeout) ] ] )
            , test "a frame re-arms the idle timer, so the old one does nothing" <|
                \_ ->
                    let
                        ( session, _ ) =
                            drive [ Start, opened "feed#1", message "feed#1" 1, Session.Fired (Session.Idle 1 1) ]
                    in
                    Expect.equal (Session.state session) Open
            , test "stop cancels the live stream" <|
                \_ ->
                    let
                        ( session, effects ) =
                            drive [ Start, Stop ]
                    in
                    Expect.equal ( Session.state session, List.drop 1 effects ) ( Closed Nothing, [ [ Send (Stream.cancel "feed#1") ] ] )
            ]
        ]


permissionDenied : Error.Error
permissionDenied =
    case decode """{"id":"s","kind":"end","status":200,"error":{"code":"permission_denied"},"metadata":{}}""" of
        Ok (Failed err) ->
            err

        _ ->
            Error.NoAnswer Error.Timeout


timerOf : List (Effect Item) -> Session.Timer
timerOf effects =
    List.foldl
        (\e found ->
            case e of
                After _ t ->
                    t

                _ ->
                    found
        )
        (Session.Idle -1 -1)
        effects
