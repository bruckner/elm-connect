module RpcTest exposing (suite)

import Dict
import Expect
import Fuzz exposing (Fuzzer)
import Http
import Json.Decode
import Json.Encode
import Proto.Any
import Proto.Duration
import Proto.Http
import Proto.Json
import Proto.Message exposing (Message)
import Proto.Method exposing (Idempotency(..))
import Proto.WellKnown
import Rpc
import Rpc.Body
import Rpc.Call
import Rpc.Code exposing (Code(..))
import Rpc.Error exposing (Error(..), Reason(..), Source(..))
import Rpc.Internal.Call
import Rpc.Internal.Http
import Rpc.Internal.Retry as Retry
import Rpc.Internal.Trace
import Rpc.Internal.Wire
import Rpc.Retry
import Rpc.Trace
import Rpc.Transport
import Test exposing (Test, describe, fuzz, test)
import Time


type alias GetNote =
    { name : String }


encodeGetNote : GetNote -> Json.Encode.Value
encodeGetNote r =
    Json.Encode.object [ ( "name", Json.Encode.string r.name ) ]


title : Message String
title =
    Proto.Message.message (\t -> Json.Encode.object [ ( "title", Json.Encode.string t ) ])
        (Json.Decode.field "title" Json.Decode.string)
        ""
        (Proto.Message.descriptor "notes.v1.Note" [])


notes : String -> Idempotency -> List Proto.Http.Binding -> GetNote -> Rpc.Call GetNote String
notes name idempotency bindings =
    Rpc.call
        (Proto.Method.method encodeGetNote
            (Proto.Message.decoder title)
            (Proto.Method.descriptor "notes.v1.Notes" name idempotency "notes.v1.GetNoteRequest" "notes.v1.Note" bindings)
        )


getNote : GetNote -> Rpc.Call GetNote String
getNote =
    notes "GetNote" IdempotencyNoSideEffects []


createNote : GetNote -> Rpc.Call GetNote String
createNote =
    notes "CreateNote" IdempotencyUnknown []


{-| A method whose repeat changes nothing more, though it has effects.
-}
deleteNote : GetNote -> Rpc.Call GetNote String
deleteNote =
    notes "DeleteNote" IdempotencyIdempotent []


{-| A method with a rule and one additional binding.
-}
listNotes : GetNote -> Rpc.Call GetNote String
listNotes =
    notes "ListNotes"
        IdempotencyNoSideEffects
        [ Proto.Http.binding { method = "GET", path = [ Proto.Http.literal "v1", Proto.Http.literal "notes" ], customVerb = Nothing, body = Proto.Http.noBody, responseBody = Nothing, query = [] }
        , Proto.Http.binding { method = "GET", path = [ Proto.Http.literal "v2", Proto.Http.literal "notes" ], customVerb = Nothing, body = Proto.Http.noBody, responseBody = Nothing, query = [] }
        ]


base : Rpc.Config
base =
    Rpc.config "https://api.example.com"


getting : Maybe Int -> Rpc.Config
getting maxGetUrl =
    { base
        | transport =
            case maxGetUrl of
                Just limit ->
                    Rpc.Transport.withMaxGetUrl limit Rpc.Transport.connectGet

                Nothing ->
                    Rpc.Transport.connectGet
    }


metadata : Int -> String -> Http.Metadata
metadata status text =
    { url = "https://api.example.com/notes.v1.Notes/GetNote"
    , statusCode = status
    , statusText = text
    , headers = Dict.empty
    }


failed : Int -> String -> String -> Result Error String
failed status text body =
    Rpc.response base (getNote { name = "x" }) (Http.BadStatus_ (metadata status text) body)
        |> withoutResponse


{-| An error with its answer blanked, for tests about what was read from it;
an `HttpStatus` error keeps its status and status text, which are what it says.
`keptResponses` checks the answer itself.
-}
withoutResponse : Result Error a -> Result Error a
withoutResponse =
    Result.mapError
        (\error ->
            case error of
                RpcStatus r _ ->
                    RpcStatus r blank

                HttpStatus answer ->
                    httpError answer.statusCode answer.statusText

                _ ->
                    error
        )


blank : Rpc.Response
blank =
    { url = "", statusCode = 0, statusText = "", headers = Dict.empty, body = Rpc.Body.text "" }


httpError : Int -> String -> Error
httpError status text =
    HttpStatus { blank | statusCode = status, statusText = text }


{-| An error with the code and message `Rpc.Error.code` and `Rpc.Error.message` read from
it.
-}
withCode : Result Error a -> Result ( Error, Code, String ) a
withCode =
    Result.mapError (\error -> ( error, Rpc.Error.code error, Rpc.Error.message error ))


fromBody : Code -> String -> Result Error String
fromBody code message =
    Err (RpcStatus { code = code, message = message, details = [], source = ConnectBody } blank)


problemWord : Proto.Any.Problem -> String
problemWord problem =
    case problem of
        Proto.Any.Json _ ->
            "json"

        Proto.Any.BinaryOnly ->
            "binary only"


suite : Test
suite =
    describe "Rpc"
        [ calls
        , requests
        , responses
        , keptResponses
        , retries
        , transports
        , configs
        , receiveLimits
        , sendLimits
        , headerRules
        , bodies
        , traces
        , trailers
        , percentEncoding
        ]


percentEncoding : Test
percentEncoding =
    let
        encode : String -> String
        encode =
            Rpc.Internal.Http.percentEncode Rpc.Internal.Http.unreserved
    in
    describe "percentEncode"
        [ test "writes a character outside the BMP as four bytes" <|
            \_ -> encode "😀" |> Expect.equal "%F0%9F%98%80"
        , test "writes a lone surrogate as U+FFFD" <|
            \_ -> encode (String.left 1 "😀") |> Expect.equal "%EF%BF%BD"
        , test "decodes 100,000 characters without exhausting the stack" <|
            \_ ->
                Rpc.Internal.Http.percentDecode (String.repeat 100000 "x")
                    |> Expect.equal (Just (String.repeat 100000 "x"))
        , test "decodes 100,000 escapes without exhausting the stack" <|
            \_ ->
                Rpc.Internal.Http.percentDecode (String.repeat 25000 "%F0%9F%98%80")
                    |> Expect.equal (Just (String.repeat 25000 "😀"))
        , test "fails on a byte that is not UTF-8 at the end of a long text" <|
            \_ ->
                Rpc.Internal.Http.percentDecode (String.repeat 100000 "x" ++ "%FF")
                    |> Expect.equal Nothing
        , test "a base URL with a query or a fragment is a bad URL" <|
            \_ ->
                [ "https://api.example.com", "/api/", "https://api.example.com/base?x=1", "https://api.example.com#top", "?" ]
                    |> List.map Rpc.Internal.Http.badBaseUrl
                    |> Expect.equal [ False, False, True, True, True ]
        ]


type Msg
    = GotNote (Result Error String)


{-| `cancel` is a command, which elm-test cannot run; this checks that it is
one of any message type, reporting nothing.
-}
cancelGotNote : Cmd Msg
cancelGotNote =
    Rpc.cancel "note-42"


calls : Test
calls =
    let
        c =
            getNote { name = "notes/42" }
    in
    describe "calls"
        [ test "read back" <|
            \_ ->
                ( ( Rpc.Call.serviceName c, Rpc.Call.methodName c ), ( Rpc.Call.idempotency c, Rpc.Call.requestMessage c ) )
                    |> Expect.equal ( ( "notes.v1.Notes", "GetNote" ), ( Proto.Method.IdempotencyNoSideEffects, { name = "notes/42" } ) )
        , test "the method and its descriptor are the ones the call was made from" <|
            \_ ->
                ( ( Proto.Method.input (Proto.Method.toDescriptor (Rpc.Call.method c)), Json.Encode.encode 0 (Proto.Method.encodeRequest (Rpc.Call.method c) { name = "x" }) ), Proto.Method.name (Rpc.Call.descriptor c), Proto.Method.output (Rpc.Call.descriptor c) )
                    |> Expect.equal ( ( "notes.v1.GetNoteRequest", "{\"name\":\"x\"}" ), "GetNote", "notes.v1.Note" )
        , test "requestJson is the request's JSON" <|
            \_ ->
                Json.Encode.encode 0 (Rpc.Call.requestJson c)
                    |> Expect.equal "{\"name\":\"notes/42\"}"
        , test "viaBinding gives a call for each binding the method has, and only those" <|
            \_ ->
                [ -1, 0, 1, 2 ]
                    |> List.map (\index -> Rpc.Call.viaBinding index (listNotes { name = "x" }) |> Maybe.map Rpc.Call.methodName)
                    |> Expect.equal [ Nothing, Just "ListNotes", Just "ListNotes", Nothing ]
        , test "a method without bindings has none to choose" <|
            \_ ->
                [ -1, 0, 1 ]
                    |> List.map (\index -> Rpc.Call.viaBinding index c |> Maybe.map Rpc.Call.methodName)
                    |> Expect.equal [ Nothing, Nothing, Nothing ]
        , test "toJson names the method and holds the request" <|
            \_ ->
                Json.Encode.encode 0 (Rpc.Call.toJson (Rpc.Call.withTimeout 5 c))
                    |> Expect.equal "{\"service\":\"notes.v1.Notes\",\"method\":\"GetNote\",\"request\":{\"name\":\"notes/42\"}}"
        ]


requests : Test
requests =
    describe "request"
        [ test "a POST to the service and method" <|
            \_ ->
                Rpc.request base (getNote { name = "notes/42" })
                    |> Expect.equal
                        { method = "POST"
                        , url = "https://api.example.com/notes.v1.Notes/GetNote"
                        , headers = [ ( "Connect-Protocol-Version", "1" ) ]
                        , body = Rpc.Body.text "{\"name\":\"notes/42\"}"
                        , timeout = Nothing
                        , withCredentials = False
                        }
        , test "the config's headers come first, and a trailing slash is dropped" <|
            \_ ->
                Rpc.request
                    { base | baseUrl = "/api/", headers = [ ( "Authorization", "Bearer t" ) ] }
                    (getNote { name = "x" })
                    |> (\r -> ( r.url, r.headers ))
                    |> Expect.equal
                        ( "/api/notes.v1.Notes/GetNote"
                        , [ ( "Authorization", "Bearer t" ), ( "Connect-Protocol-Version", "1" ) ]
                        )
        , test "a call's headers follow the config's, in the order added" <|
            \_ ->
                getNote { name = "x" }
                    |> Rpc.Call.withHeaders [ ( "X-A", "1" ) ]
                    |> Rpc.Call.withHeaders [ ( "X-B", "2" ) ]
                    |> Rpc.request { base | headers = [ ( "Authorization", "Bearer t" ) ] }
                    |> .headers
                    |> Expect.equal
                        [ ( "Authorization", "Bearer t" ), ( "X-A", "1" ), ( "X-B", "2" ), ( "Connect-Protocol-Version", "1" ) ]
        , test "a timeout is sent in whole milliseconds, rounded up" <|
            \_ ->
                Rpc.request { base | timeout = Just 1500.2 } (getNote { name = "x" })
                    |> (\r -> ( r.headers, r.timeout ))
                    |> Expect.equal
                        ( [ ( "Connect-Protocol-Version", "1" ), ( "Connect-Timeout-Ms", "1501" ) ]
                        , Just 1500.2
                        )
        , test "a call's timeout replaces the config's" <|
            \_ ->
                getNote { name = "x" }
                    |> Rpc.Call.withTimeout 20
                    |> Rpc.request { base | timeout = Just 1000 }
                    |> (\r -> ( r.headers, r.timeout ))
                    |> Expect.equal
                        ( [ ( "Connect-Protocol-Version", "1" ), ( "Connect-Timeout-Ms", "20" ) ]
                        , Just 20
                        )
        , test "a timeout is at least one millisecond and at most ten digits" <|
            \_ ->
                [ 0.4, 1.0e12 ]
                    |> List.map (\t -> (Rpc.request { base | timeout = Just t } (getNote { name = "x" })).headers)
                    |> Expect.equal
                        [ [ ( "Connect-Protocol-Version", "1" ), ( "Connect-Timeout-Ms", "1" ) ]
                        , [ ( "Connect-Protocol-Version", "1" ), ( "Connect-Timeout-Ms", "9999999999" ) ]
                        ]
        , test "a timeout that is not a positive number is no timeout" <|
            \_ ->
                [ 0, -5, 0 / 0, 1 / 0, -(1 / 0) ]
                    |> List.map (\t -> Rpc.request { base | timeout = Just t } (getNote { name = "x" }))
                    |> List.map (\r -> ( r.headers, r.timeout ))
                    |> Expect.equal (List.repeat 5 ( [ ( "Connect-Protocol-Version", "1" ) ], Nothing ))
        , test "a call's timeout that is not a positive number leaves the config's" <|
            \_ ->
                [ 0, -5, 0 / 0 ]
                    |> List.map (\t -> Rpc.request { base | timeout = Just 1000 } (Rpc.Call.withTimeout t (getNote { name = "x" })))
                    |> List.map (\r -> ( r.headers, r.timeout ))
                    |> Expect.equal (List.repeat 3 ( [ ( "Connect-Protocol-Version", "1" ), ( "Connect-Timeout-Ms", "1000" ) ], Just 1000 ))
        , test "withCredentials is carried to the request" <|
            \_ ->
                (Rpc.request { base | withCredentials = True } (getNote { name = "x" })).withCredentials
                    |> Expect.equal True
        , test "connectGet sends a call without side effects as a GET with the message in the query" <|
            \_ ->
                Rpc.request { base | transport = Rpc.Transport.connectGet, timeout = Just 20 }
                    (getNote { name = "notes/42 é" })
                    |> Expect.equal
                        { method = "GET"
                        , url =
                            "https://api.example.com/notes.v1.Notes/GetNote"
                                ++ "?connect=v1&encoding=json&message="
                                ++ "%7B%22name%22%3A%22notes%2F42%20%C3%A9%22%7D"
                        , headers = [ ( "Connect-Timeout-Ms", "20" ) ]
                        , body = Rpc.Body.none
                        , timeout = Just 20
                        , withCredentials = False
                        }
        , test "a GET carries the config's headers, then the call's, then the timeout, and no protocol version" <|
            \_ ->
                getNote { name = "x" }
                    |> Rpc.Call.withHeaders [ ( "X-A", "1" ) ]
                    |> Rpc.Call.withHeaders [ ( "X-B", "2" ) ]
                    |> Rpc.request
                        { base
                            | transport = Rpc.Transport.connectGet
                            , headers = [ ( "Authorization", "Bearer t" ) ]
                            , timeout = Just 20
                        }
                    |> (\r -> ( r.method, r.headers ))
                    |> Expect.equal
                        ( "GET"
                        , [ ( "Authorization", "Bearer t" ), ( "X-A", "1" ), ( "X-B", "2" ), ( "Connect-Timeout-Ms", "20" ) ]
                        )
        , test "connectGet still POSTs a call with side effects" <|
            \_ ->
                (Rpc.request (getting Nothing) (createNote { name = "x" })).method
                    |> Expect.equal "POST"
        , test "connectGet POSTs an idempotent call with effects: only IdempotencyNoSideEffects is a GET" <|
            \_ ->
                ( (Rpc.request (getting Nothing) (deleteNote { name = "x" })).method, Rpc.Call.idempotency (deleteNote { name = "x" }) )
                    |> Expect.equal ( "POST", Proto.Method.IdempotencyIdempotent )
        , test "GET is off by default" <|
            \_ ->
                (Rpc.request base (getNote { name = "x" })).method
                    |> Expect.equal "POST"
        , test "withMaxGetUrl POSTs a call whose GET URL would be longer" <|
            \_ ->
                let
                    length =
                        String.length (Rpc.request (getting Nothing) (getNote { name = "x" })).url
                in
                [ length - 1, length, length + 1 ]
                    |> List.map (\limit -> (Rpc.request (getting (Just limit)) (getNote { name = "x" })).method)
                    |> Expect.equal [ "POST", "GET", "GET" ]
        , test "a POST's URL is the method's, with no query" <|
            \_ ->
                let
                    length =
                        String.length (Rpc.request (getting Nothing) (getNote { name = "x" })).url
                in
                [ Rpc.request base (getNote { name = "x" })
                , Rpc.request (getting (Just (length - 1))) (getNote { name = "x" })
                , Rpc.request (getting Nothing) (createNote { name = "x" })
                , Rpc.request (getting Nothing) (deleteNote { name = "x" })
                ]
                    |> List.map .url
                    |> Expect.equal
                        [ "https://api.example.com/notes.v1.Notes/GetNote"
                        , "https://api.example.com/notes.v1.Notes/GetNote"
                        , "https://api.example.com/notes.v1.Notes/CreateNote"
                        , "https://api.example.com/notes.v1.Notes/DeleteNote"
                        ]
        , test "a GET at or under withMaxGetUrl's limit carries the whole message in its URL" <|
            \_ ->
                let
                    url =
                        "https://api.example.com/notes.v1.Notes/GetNote?connect=v1&encoding=json&message=%7B%22name%22%3A%22x%22%7D"
                in
                [ Nothing, Just (String.length url), Just (String.length url + 1) ]
                    |> List.map (\limit -> Rpc.request (getting limit) (getNote { name = "x" }) |> (\r -> ( r.method, r.url )))
                    |> Expect.equal (List.repeat 3 ( "GET", url ))
        , test "Connect ignores the binding chosen" <|
            \_ ->
                listNotes { name = "x" }
                    |> Rpc.Call.viaBinding 1
                    |> Maybe.map (Rpc.request base)
                    |> Expect.equal (Just (Rpc.request base (listNotes { name = "x" })))
        ]


responses : Test
responses =
    describe "response"
        [ test "200 decodes the response" <|
            \_ ->
                Rpc.response base (getNote { name = "x" }) (Http.GoodStatus_ (metadata 200 "OK") "{\"title\":\"hi\"}")
                    |> Expect.equal (Ok "hi")
        , test "a 100,000-character grpc-message is decoded without exhausting the stack" <|
            \_ ->
                let
                    long =
                        String.repeat 50000 "%C3%A9" ++ String.repeat 50000 "x"
                in
                Rpc.response base
                    (getNote { name = "x" })
                    (Http.BadStatus_ { url = "", statusCode = 503, statusText = "", headers = Dict.fromList [ ( "grpc-status", "14" ), ( "grpc-message", long ) ] } "")
                    |> Result.mapError Rpc.Error.message
                    |> Expect.equal (Err (String.repeat 50000 "é" ++ String.repeat 50000 "x"))
        , test "a bad body's message quotes 300 characters of the problem, the error all of it" <|
            \_ ->
                let
                    body =
                        "[\"" ++ String.repeat 10000 "x" ++ "\"]"
                in
                case Rpc.response base (getNote { name = "x" }) (Http.GoodStatus_ (metadata 200 "OK") body) of
                    Err ((BadResponse problem _) as error) ->
                        ( ( String.length (Rpc.Error.message error), String.endsWith "…" (Rpc.Error.message error) )
                        , ( String.startsWith "bad response body: " (Rpc.Error.message error), String.length problem > 10000 )
                        )
                            |> Expect.equal ( ( 320, True ), ( True, True ) )

                    other ->
                        Expect.fail (Debug.toString other)
        , test "200 with a body that does not decode is a bad response, the answer kept" <|
            \_ ->
                case Rpc.response base (getNote { name = "x" }) (Http.GoodStatus_ (metadata 200 "OK") "{}") of
                    Err (BadResponse _ answer) ->
                        ( answer.statusCode, Maybe.withDefault "" (Rpc.Body.toText answer.body), answer.url )
                            |> Expect.equal ( 200, "{}", "https://api.example.com/notes.v1.Notes/GetNote" )

                    other ->
                        Expect.fail (Debug.toString other)
        , test "another 2xx is an error inferred from its status" <|
            \_ ->
                Rpc.response base (getNote { name = "x" }) (Http.GoodStatus_ (metadata 204 "No Content") "")
                    |> withoutResponse
                    |> withCode
                    |> Expect.equal (Err ( httpError 204 "No Content", Unknown, "No Content" ))
        , test "a Connect error body gives code, message and details" <|
            \_ ->
                failed 404
                    "Not Found"
                    """{"code":"not_found","message":"no note","details":[{"type":"google.rpc.RetryInfo","value":"CgIIPA"},{"type":"notes.v1.Note","value":"CgJoaQ","debug":{"title":"hi"}}]}"""
                    |> Result.mapError
                        (\error ->
                            case error of
                                RpcStatus r _ ->
                                    ( r.code, r.message, List.map (\detail -> ( Proto.Any.typeUrl detail, Json.Encode.encode 0 (Proto.Json.encodeAny detail) )) r.details )

                                _ ->
                                    ( Internal, "not a status", [] )
                        )
                    |> Expect.equal
                        (Err
                            ( NotFound
                            , "no note"
                            , [ ( "type.googleapis.com/google.rpc.RetryInfo", "{\"type\":\"google.rpc.RetryInfo\",\"value\":\"CgIIPA\"}" )
                              , ( "type.googleapis.com/notes.v1.Note", "{\"@type\":\"type.googleapis.com/notes.v1.Note\",\"title\":\"hi\"}" )
                              ]
                            )
                        )
        , test "a Connect detail without debug holds its binary alone" <|
            \_ ->
                failed 404 "Not Found" """{"code":"not_found","details":[{"type":"notes.v1.Note","value":"CgJoaQ"}]}"""
                    |> Result.mapError
                        (\error ->
                            case error of
                                RpcStatus r _ ->
                                    List.map
                                        (\detail ->
                                            ( Proto.Any.typeName detail
                                            , Proto.Any.unpack title detail |> Maybe.map (Result.mapError problemWord)
                                            , Json.Encode.encode 0 (Proto.Json.encodeAny detail)
                                            )
                                        )
                                        r.details

                                _ ->
                                    []
                        )
                    |> Expect.equal (Err [ ( "notes.v1.Note", Just (Err "binary only"), "{\"type\":\"notes.v1.Note\",\"value\":\"CgJoaQ\"}" ) ])
        , test "a Status body's details are proto3 JSON Any objects" <|
            \_ ->
                failed 404
                    "Not Found"
                    """{"code":5,"message":"no note","details":[{"@type":"type.googleapis.com/notes.v1.Note","title":"hi"},{"@type":"type.googleapis.com/google.protobuf.Duration","value":"2s"},{"no":"type"}]}"""
                    |> Result.mapError
                        (\error ->
                            ( Rpc.Error.details title error
                            , Rpc.Error.details Proto.WellKnown.duration error |> List.map Proto.Duration.toMilliseconds
                            , case error of
                                RpcStatus r _ ->
                                    Just ( r.code, r.source, List.length r.details )

                                _ ->
                                    Nothing
                            )
                        )
                    |> Expect.equal (Err ( [ "hi" ], [ 2000 ], Just ( NotFound, StatusBody, 2 ) ))
        , test "details gives those of a type that decode, and an HttpStatus or NoAnswer error has none" <|
            \_ ->
                ( failed 400
                    "Bad Request"
                    """{"code":"invalid_argument","details":[{"type":"notes.v1.Note","value":"","debug":{"title":"one"}},{"type":"notes.v1.Note","value":"CgA"},{"type":"notes.v1.Note","value":"","debug":{"title":2}},{"type":"other.v1.Thing","value":"","debug":{"title":"no"}},{"type":"notes.v1.Note","value":"","debug":{"title":"two"}}]}"""
                    |> Result.mapError (Rpc.Error.details title)
                , ( Rpc.Error.details title (httpError 404 "Not Found"), Rpc.Error.details title (NoAnswer Timeout) )
                )
                    |> Expect.equal ( Err [ "one", "two" ], ( [], [] ) )
        , test "message and details are optional" <|
            \_ ->
                failed 503 "Service Unavailable" """{"code":"unavailable"}"""
                    |> Expect.equal (fromBody Unavailable "")
        , test "an unknown code name reads as unknown" <|
            \_ ->
                failed 400 "Bad Request" """{"code":"teapot","message":"short and stout"}"""
                    |> Expect.equal (fromBody Unknown "short and stout")
        , test "a failed answer claiming ok reads as unknown" <|
            \_ ->
                failed 500 "Internal Server Error" """{"code":"ok","message":"fine"}"""
                    |> Expect.equal (fromBody Unknown "fine")
        , test "a body without a code is an HttpStatus error, its code inferred from the HTTP status" <|
            \_ ->
                [ ( 400, "{}" ), ( 401, "" ), ( 403, "<html>" ), ( 404, "{\"code\":null}" ), ( 429, "" ), ( 502, "" ), ( 503, "" ), ( 504, "" ), ( 500, "" ), ( 409, "" ) ]
                    |> List.map (\( status, body ) -> failed status "" body |> withCode)
                    |> Expect.equal
                        [ Err ( httpError 400 "", Internal, "HTTP 400" )
                        , Err ( httpError 401 "", Unauthenticated, "HTTP 401" )
                        , Err ( httpError 403 "", PermissionDenied, "HTTP 403" )
                        , Err ( httpError 404 "", Unimplemented, "HTTP 404" )
                        , Err ( httpError 429 "", Unavailable, "HTTP 429" )
                        , Err ( httpError 502 "", Unavailable, "HTTP 502" )
                        , Err ( httpError 503 "", Unavailable, "HTTP 503" )
                        , Err ( httpError 504 "", Unavailable, "HTTP 504" )
                        , Err ( httpError 500 "", Unknown, "HTTP 500" )
                        , Err ( httpError 409 "", Unknown, "HTTP 409" )
                        ]
        , test "an HttpStatus error's message is its status text when there is one" <|
            \_ ->
                failed 502 "Bad Gateway" "upstream reset"
                    |> withCode
                    |> Expect.equal (Err ( httpError 502 "Bad Gateway", Unavailable, "Bad Gateway" ))
        , test "no answer is NoAnswer" <|
            \_ ->
                [ Http.Timeout_, Http.NetworkError_, Http.BadUrl_ "::" ]
                    |> List.map (Rpc.response base (getNote { name = "x" }))
                    |> Expect.equal
                        [ Err (NoAnswer Timeout)
                        , Err (NoAnswer NetworkError)
                        , Err (NoAnswer (BadUrl "::"))
                        ]
        , test "an error without a stated status has the code the Connect clients give it" <|
            \_ ->
                [ NoAnswer Timeout, NoAnswer NetworkError, NoAnswer (BadUrl "::"), NoAnswer (RequestTooLarge { limit = 10, size = 11 }), NoAnswer (ResponseTooLarge { limit = 10, size = 11 }), BadResponse "oops" blank ]
                    |> List.map (\error -> ( Rpc.Error.code error, Rpc.Error.message error ))
                    |> Expect.equal
                        [ ( DeadlineExceeded, "timeout" )
                        , ( Unavailable, "network error" )
                        , ( Internal, "bad URL: ::" )
                        , ( ResourceExhausted, "message size 11 is larger than configured writeMaxBytes 10" )
                        , ( ResourceExhausted, "message size 11 is larger than configured readMaxBytes 10" )
                        , ( Internal, "bad response body: oops" )
                        ]
        , test "a bad URL's message leaves out its user, password, query and fragment" <|
            \_ ->
                [ "https://user:secret@api.example.com/base/notes.v1.Notes/GetNote?connect=v1&message=%7B%7D"
                , "https://api.example.com/base#top/notes.v1.Notes/GetNote"
                , "https://me@api.example.com/x@y"
                , "/api/notes.v1.Notes/GetNote"
                ]
                    |> List.map (BadUrl >> NoAnswer >> Rpc.Error.message)
                    |> Expect.equal
                        [ "bad URL: https://api.example.com/base/notes.v1.Notes/GetNote (query omitted)"
                        , "bad URL: https://api.example.com/base (query omitted)"
                        , "bad URL: https://api.example.com/x@y"
                        , "bad URL: /api/notes.v1.Notes/GetNote"
                        ]
        , test "toString is the code and the message" <|
            \_ ->
                [ RpcStatus { code = NotFound, message = "no note", details = [], source = ConnectBody } blank
                , RpcStatus { code = Internal, message = "", details = [], source = StatusBody } blank
                , httpError 404 "Not Found"
                , httpError 400 ""
                , NoAnswer Timeout
                , NoAnswer NetworkError
                , NoAnswer (BadUrl "::")
                , NoAnswer (RequestTooLarge { limit = 10, size = 11 })
                , NoAnswer (ResponseTooLarge { limit = 10, size = 11 })
                , BadResponse "oops" blank
                ]
                    |> List.map Rpc.Error.toString
                    |> Expect.equal
                        [ "not_found: no note"
                        , "internal"
                        , "unimplemented: Not Found"
                        , "internal: HTTP 400"
                        , "deadline_exceeded: timeout"
                        , "unavailable: network error"
                        , "internal: bad URL: ::"
                        , "resource_exhausted: message size 11 is larger than configured writeMaxBytes 10"
                        , "resource_exhausted: message size 11 is larger than configured readMaxBytes 10"
                        , "internal: bad response body: oops"
                        ]
        ]


{-| The answer an error was read from, kept whether it stated a status or not.
-}
keptResponses : Test
keptResponses =
    let
        answer code headers body =
            Rpc.response base
                (getNote { name = "x" })
                (Http.BadStatus_ { url = "https://api.example.com/notes.v1.Notes/GetNote", statusCode = code, statusText = "", headers = Dict.fromList headers } body)
                |> Result.mapError
                    (\error ->
                        let
                            kept got =
                                ( got.statusCode, Dict.get "x-request-id" got.headers, Maybe.withDefault "" (Rpc.Body.toText got.body) )
                        in
                        case error of
                            RpcStatus r got ->
                                Just ( Just r.source, kept got )

                            HttpStatus got ->
                                Just ( Nothing, kept got )

                            _ ->
                                Nothing
                    )

        connect =
            """{"code":"not_found","message":"no note"}"""

        statusBody =
            """{"code":5,"message":"no note"}"""

        legacy =
            """{"error":{"kind":"missing","id":42}}"""
    in
    describe "the answer an error was read from"
        [ test "a Connect body" <|
            \_ ->
                answer 404 [ ( "x-request-id", "r1" ) ] connect
                    |> Expect.equal (Err (Just ( Just ConnectBody, ( 404, Just "r1", connect ) )))
        , test "a google.rpc.Status body" <|
            \_ ->
                answer 404 [ ( "x-request-id", "r2" ) ] statusBody
                    |> Expect.equal (Err (Just ( Just StatusBody, ( 404, Just "r2", statusBody ) )))
        , test "the grpc-status headers" <|
            \_ ->
                answer 503 [ ( "grpc-status", "14" ), ( "x-request-id", "r3" ) ] "upstream reset"
                    |> Expect.equal (Err (Just ( Just GrpcHeaders, ( 503, Just "r3", "upstream reset" ) )))
        , test "an HttpStatus error, the body in a shape the reader does not know" <|
            \_ ->
                answer 404 [ ( "x-request-id", "r4" ) ] legacy
                    |> Expect.equal (Err (Just ( Nothing, ( 404, Just "r4", legacy ) )))
        , test "a 2xx that is not a Connect success keeps its answer too" <|
            \_ ->
                Rpc.response base (getNote { name = "x" }) (Http.GoodStatus_ (metadata 204 "No Content") "")
                    |> Result.mapError
                        (\error ->
                            case error of
                                HttpStatus got ->
                                    Just ( got.statusCode, got.statusText, Maybe.withDefault "" (Rpc.Body.toText got.body) )

                                _ ->
                                    Nothing
                        )
                    |> Expect.equal (Err (Just ( 204, "No Content", "" )))
        , test "the URL the answer came from, after any redirect" <|
            \_ ->
                Rpc.response base
                    (getNote { name = "x" })
                    (Http.BadStatus_ { url = "https://api.example.com/moved", statusCode = 404, statusText = "", headers = Dict.empty } "")
                    |> Result.mapError
                        (\error ->
                            case error of
                                HttpStatus got ->
                                    got.url

                                _ ->
                                    ""
                        )
                    |> Expect.equal (Err "https://api.example.com/moved")
        ]


retries : Test
retries =
    let
        policy =
            Rpc.Retry.on [ Unavailable ]
                |> Rpc.Retry.withBackoff 100
                |> Rpc.Retry.withoutJitter

        delays retry =
            List.map (\tried -> Retry.delay retry Proto.Method.IdempotencyNoSideEffects tried Unavailable)
    in
    describe "retry policy"
        [ test "a listed code waits the backoff, doubled per attempt, until attempts run out" <|
            \_ ->
                delays policy [ 1, 2, 3 ]
                    |> Expect.equal [ Just 100, Just 200, Nothing ]
        , test "the defaults: 3 attempts, 200 ms doubling, idempotent only, jitter" <|
            \_ ->
                let
                    defaults =
                        Rpc.Retry.on [ Unavailable ]
                in
                ( delays defaults [ 1, 2, 3 ]
                , Retry.delay defaults Proto.Method.IdempotencyUnknown 1 Unavailable
                , defaults == (defaults |> Rpc.Retry.withoutJitter)
                )
                    |> Expect.equal ( [ Just 200, Just 400, Nothing ], Nothing, False )
        , test "the defaults cap a wait at 30 seconds" <|
            \_ ->
                delays (Rpc.Retry.on [ Unavailable ] |> Rpc.Retry.withAttempts 20) [ 8, 9, 10 ]
                    |> Expect.equal [ Just 25600, Just 30000, Just 30000 ]
        , test "withMaxBackoff caps the doubling" <|
            \_ ->
                delays (policy |> Rpc.Retry.withAttempts 10 |> Rpc.Retry.withMaxBackoff 350) [ 1, 2, 3, 4 ]
                    |> Expect.equal [ Just 100, Just 200, Just 350, Just 350 ]
        , test "no wait is longer than setTimeout runs, 2^31 - 1 ms" <|
            \_ ->
                delays (policy |> Rpc.Retry.withAttempts 2000 |> Rpc.Retry.withMaxBackoff (1 / 0)) [ 40, 1500 ]
                    |> Expect.equal [ Just 2147483647, Just 2147483647 ]
        , test "a backoff that is not a positive number waits not at all, however many attempts" <|
            \_ ->
                [ 0, -5, 0 / 0 ]
                    |> List.concatMap (\ms -> delays (policy |> Rpc.Retry.withAttempts 2000 |> Rpc.Retry.withBackoff ms) [ 1, 1500 ])
                    |> Expect.equal (List.repeat 6 (Just 0))
        , test "a code not listed stops" <|
            \_ ->
                Retry.delay policy IdempotencyNoSideEffects 1 NotFound
                    |> Expect.equal Nothing
        , test "idempotent-only stops a call that may have side effects; allowNonIdempotent retries it" <|
            \_ ->
                ( Retry.delay policy Proto.Method.IdempotencyUnknown 1 Unavailable
                , Retry.delay (Rpc.Retry.allowNonIdempotent policy) Proto.Method.IdempotencyUnknown 1 Unavailable
                )
                    |> Expect.equal ( Nothing, Just 100 )
        , test "idempotent-only retries both idempotency levels" <|
            \_ ->
                ( Retry.delay policy IdempotencyNoSideEffects 1 Unavailable
                , Retry.delay policy IdempotencyIdempotent 1 Unavailable
                )
                    |> Expect.equal ( Just 100, Just 100 )
        , test "one attempt never retries" <|
            \_ ->
                Retry.delay (Rpc.Retry.withAttempts 1 policy) Proto.Method.IdempotencyNoSideEffects 1 Unavailable
                    |> Expect.equal Nothing
        , test "a timeout retries when DeadlineExceeded is listed, and not otherwise" <|
            \_ ->
                ( Retry.delay (Rpc.Retry.on [ DeadlineExceeded ] |> Rpc.Retry.withBackoff 100) Proto.Method.IdempotencyNoSideEffects 1 (Rpc.Error.code (NoAnswer Timeout))
                , Retry.delay policy Proto.Method.IdempotencyNoSideEffects 1 (Rpc.Error.code (NoAnswer Timeout))
                )
                    |> Expect.equal ( Just 100, Nothing )
        , test "a network failure retries when Unavailable is listed" <|
            \_ ->
                Retry.delay policy IdempotencyNoSideEffects 1 (Rpc.Error.code (NoAnswer NetworkError))
                    |> Expect.equal (Just 100)
        , test "idempotent-only stops a transport failure of a call with side effects" <|
            \_ ->
                ( Retry.delay policy Proto.Method.IdempotencyUnknown 1 (Rpc.Error.code (NoAnswer NetworkError))
                , Retry.delay (Rpc.Retry.on [ DeadlineExceeded ]) Proto.Method.IdempotencyUnknown 1 (Rpc.Error.code (NoAnswer Timeout))
                )
                    |> Expect.equal ( Nothing, Nothing )
        , describe "jitter" (jitters policy)
        , describe "the schedule" (schedules policy)
        , describe "the deadline" (deadlines policy)
        , describe "a call's own policy" (overrides policy)
        ]


{-| The moment after a first failed attempt of a call without side effects,
failing with `Unavailable`, at the start of the epoch.
-}
moment : Retry.Moment
moment =
    { tried = 1
    , code = Unavailable
    , idempotency = IdempotencyNoSideEffects
    , now = Time.millisToPosix 0
    , elapsed = 0
    }


schedules : Rpc.Retry.Retry -> List Test
schedules policy =
    let
        waits retry =
            List.map (\tried -> Retry.wait retry { moment | tried = tried })

        jittered =
            Rpc.Retry.on [ Unavailable ] |> Rpc.Retry.withAttempts 6
    in
    [ test "the attempts limit stops it" <|
        \_ ->
            waits policy [ 1, 2, 3, 4 ]
                |> Expect.equal [ Just 100, Just 200, Nothing, Nothing ]
    , test "a code not listed stops it" <|
        \_ ->
            ( Retry.wait policy { moment | code = NotFound }
            , Retry.wait policy { moment | code = Unavailable }
            )
                |> Expect.equal ( Nothing, Just 100 )
    , test "idempotent-only stops a method that may have side effects" <|
        \_ ->
            [ IdempotencyNoSideEffects, IdempotencyIdempotent, IdempotencyUnknown ]
                |> List.map (\idempotency -> Retry.wait policy { moment | idempotency = idempotency })
                |> Expect.equal [ Just 100, Just 100, Nothing ]
    , test "the wait doubles up to the cap" <|
        \_ ->
            waits (policy |> Rpc.Retry.withAttempts 6 |> Rpc.Retry.withMaxBackoff 500) [ 1, 2, 3, 4, 5 ]
                |> Expect.equal [ Just 100, Just 200, Just 400, Just 500, Just 500 ]
    , test "without jitter the wait is the bound" <|
        \_ ->
            List.range 0 99
                |> List.map (\ms -> Retry.wait policy { moment | now = Time.millisToPosix (1760000000000 + ms) })
                |> List.all ((==) (Just 100))
                |> Expect.equal True
    , test "with jitter the wait is from zero to the bound" <|
        \_ ->
            List.range 0 999
                |> List.concatMap
                    (\ms ->
                        List.map2
                            (\tried bound ->
                                case Retry.wait jittered { moment | tried = tried, now = Time.millisToPosix (1760000000000 + ms) } of
                                    Just wait ->
                                        wait >= 0 && wait <= bound

                                    Nothing ->
                                        False
                            )
                            [ 1, 2, 3 ]
                            [ 200, 400, 800 ]
                    )
                |> List.all identity
                |> Expect.equal True
    , fuzz moments "next is the wait the loop takes" <|
        \( retry, at ) ->
            Retry.step (Just retry) at.idempotency Just { tried = at.tried, now = at.now, elapsed = at.elapsed } (Err at.code)
                |> Expect.equal (Rpc.Retry.next retry at)
    , test "the loop does not wait after a success, without a policy, or for a failure trying again cannot help" <|
        \_ ->
            ( Retry.step (Just policy) IdempotencyNoSideEffects Just { tried = 1, now = moment.now, elapsed = 0 } (Ok ())
            , Retry.step Nothing IdempotencyNoSideEffects Just { tried = 1, now = moment.now, elapsed = 0 } (Err Unavailable)
            , Retry.step (Just policy) IdempotencyNoSideEffects (\_ -> Nothing) { tried = 1, now = moment.now, elapsed = 0 } (Err Unavailable)
            )
                |> Expect.equal ( Nothing, Nothing, Nothing )
    ]


{-| Policies with and without jitter and a deadline, each with a moment after
a failed attempt: any code, idempotency and attempt count, at any time.
-}
moments : Fuzzer ( Rpc.Retry.Retry, Retry.Moment )
moments =
    let
        retry =
            Fuzz.map4
                (\attempts backoff jitter deadline ->
                    Rpc.Retry.on [ Unavailable, ResourceExhausted, DeadlineExceeded ]
                        |> Rpc.Retry.withAttempts attempts
                        |> Rpc.Retry.withBackoff backoff
                        |> (if jitter then
                                identity

                            else
                                Rpc.Retry.withoutJitter
                           )
                        |> (case deadline of
                                Just ms ->
                                    Rpc.Retry.withDeadline ms

                                Nothing ->
                                    identity
                           )
                )
                (Fuzz.intRange 0 8)
                (Fuzz.floatRange 0 5000)
                Fuzz.bool
                (Fuzz.maybe (Fuzz.floatRange -100 60000))

        at =
            Fuzz.map5 Retry.Moment
                (Fuzz.intRange 1 10)
                (Fuzz.oneOfValues [ Unavailable, ResourceExhausted, DeadlineExceeded, NotFound, Internal ])
                (Fuzz.oneOfValues [ IdempotencyNoSideEffects, IdempotencyIdempotent, IdempotencyUnknown ])
                (Fuzz.map Time.millisToPosix (Fuzz.intRange 0 2000000000000))
                (Fuzz.floatRange 0 60000)
    in
    Fuzz.pair retry at


deadlines : Rpc.Retry.Retry -> List Test
deadlines policy =
    let
        bounded =
            policy |> Rpc.Retry.withAttempts 10 |> Rpc.Retry.withDeadline 1000
    in
    [ test "a wait that would reach the deadline stops it" <|
        \_ ->
            [ 0, 899, 900, 2000 ]
                |> List.map (\elapsed -> Retry.wait bounded { moment | elapsed = elapsed })
                |> Expect.equal [ Just 100, Just 100, Nothing, Nothing ]
    , test "a deadline that is not a positive finite number is none" <|
        \_ ->
            [ 0, -5, 0 / 0, 1 / 0 ]
                |> List.map (\ms -> Retry.wait (policy |> Rpc.Retry.withDeadline ms) { moment | elapsed = 1.0e9 })
                |> Expect.equal (List.repeat 4 (Just 100))
    , test "an attempt's budget is what is left of the deadline, at least 1 ms" <|
        \_ ->
            [ 0, 400, 999.5, 5000 ]
                |> List.map (Retry.budget bounded)
                |> Expect.equal [ Just 1000, Just 600, Just 1, Just 1 ]
    , test "without a deadline there is no budget" <|
        \_ ->
            Retry.budget policy 400
                |> Expect.equal Nothing
    , test "an attempt's timeout is the smaller of its own and the budget" <|
        \_ ->
            [ ( Nothing, Nothing ), ( Nothing, Just 500 ), ( Just 300, Nothing ), ( Just 300, Just 500 ), ( Just 300, Just 100 ) ]
                |> List.map (\( left, timeout ) -> Retry.attemptTimeout left timeout)
                |> Expect.equal [ Nothing, Just 500, Just 300, Just 300, Just 100 ]
    , test "a clipped Connect attempt tells the server the clipped timeout" <|
        \_ ->
            let
                c =
                    getNote { name = "notes/42" } |> Rpc.Call.withTimeout 5000

                cfg =
                    { base | timeout = Nothing }
            in
            Rpc.request cfg c
                |> Rpc.Internal.Wire.withBudget cfg c (Just 299.5)
                |> (\sent -> ( sent.timeout, List.filter (\( name, _ ) -> name == "Connect-Timeout-Ms") sent.headers ))
                |> Expect.equal ( Just 299.5, [ ( "Connect-Timeout-Ms", "300" ) ] )
    , test "an attempt without a timeout takes the budget as its timeout" <|
        \_ ->
            let
                c =
                    getNote { name = "notes/42" }
            in
            Rpc.request base c
                |> Rpc.Internal.Wire.withBudget base c (Just 700)
                |> (\sent -> ( sent.timeout, List.member ( "Connect-Timeout-Ms", "700" ) sent.headers ))
                |> Expect.equal ( Just 700, True )
    , test "an attempt within the budget, or without one, is sent as it is" <|
        \_ ->
            let
                c =
                    getNote { name = "notes/42" } |> Rpc.Call.withTimeout 200

                sent =
                    Rpc.request base c
            in
            ( Rpc.Internal.Wire.withBudget base c (Just 700) sent == sent
            , Rpc.Internal.Wire.withBudget base c Nothing sent == sent
            )
                |> Expect.equal ( True, True )
    , test "a transcoded attempt over a binding is clipped without a header" <|
        \_ ->
            let
                c =
                    listNotes { name = "notes/42" }

                cfg =
                    { base | transport = Rpc.Transport.transcode }

                sent =
                    Rpc.request cfg c
            in
            Rpc.Internal.Wire.withBudget cfg c (Just 700) sent
                |> Expect.equal { sent | timeout = Just 700 }
    ]


overrides : Rpc.Retry.Retry -> List Test
overrides policy =
    let
        retrying =
            { base | retry = Just policy }

        own =
            Rpc.Retry.on [ NotFound ]

        inEffect cfg c =
            Rpc.Internal.Call.retryIn cfg.retry c
    in
    [ test "a call without a choice takes the config's" <|
        \_ ->
            ( inEffect retrying (getNote { name = "x" }), inEffect base (getNote { name = "x" }) )
                |> Expect.equal ( Just policy, Nothing )
    , test "withRetry replaces the config's, or gives one where it has none" <|
        \_ ->
            ( inEffect retrying (getNote { name = "x" } |> Rpc.Call.withRetry own)
            , inEffect base (getNote { name = "x" } |> Rpc.Call.withRetry own)
            )
                |> Expect.equal ( Just own, Just own )
    , test "withoutRetry leaves none in effect" <|
        \_ ->
            inEffect retrying (getNote { name = "x" } |> Rpc.Call.withoutRetry)
                |> Expect.equal Nothing
    , test "the last choice made holds" <|
        \_ ->
            ( inEffect retrying (getNote { name = "x" } |> Rpc.Call.withoutRetry |> Rpc.Call.withRetry own)
            , inEffect retrying (getNote { name = "x" } |> Rpc.Call.withRetry own |> Rpc.Call.withoutRetry)
            )
                |> Expect.equal ( Just own, Nothing )
    , test "the choice does not change the request" <|
        \_ ->
            Rpc.request retrying (getNote { name = "x" } |> Rpc.Call.withoutRetry)
                |> Expect.equal (Rpc.request retrying (getNote { name = "x" }))
    ]


jitters : Rpc.Retry.Retry -> List Test
jitters policy =
    let
        jittered =
            Rpc.Retry.on [ Unavailable ]

        -- Times a millisecond apart, as clients that failed together read them.
        seeds =
            List.range 1760000000000 1760000000999

        draws tried =
            List.map (\seed -> Retry.jitter jittered seed tried 1000) seeds

        mean values =
            List.sum values / toFloat (List.length values)
    in
    [ test "without jitter the wait is the bound" <|
        \_ ->
            Retry.jitter policy 1760000000000 1 1000
                |> Expect.equal 1000
    , test "each wait is from zero to the bound" <|
        \_ ->
            draws 1
                |> List.all (\wait -> wait >= 0 && wait < 1000)
                |> Expect.equal True
    , test "the same time and attempt draw the same wait" <|
        \_ ->
            Retry.jitter jittered 1760000000123 2 1000
                |> Expect.within (Expect.Absolute 0) (Retry.jitter jittered 1760000000123 2 1000)
    , test "waits drawn a millisecond apart spread over the range" <|
        \_ ->
            let
                waits =
                    draws 1

                tenths =
                    List.map (\wait -> floor (wait / 100)) waits
            in
            ( mean waits > 450 && mean waits < 550
            , List.all (\tenth -> List.member tenth tenths) (List.range 0 9)
            )
                |> Expect.equal ( True, True )
    , test "consecutive attempts draw differently" <|
        \_ ->
            List.map2 (/=) (draws 1) (draws 2)
                |> List.filter identity
                |> List.length
                |> Expect.atLeast 990
    ]


transports : Test
transports =
    describe "transports"
        [ test "the names" <|
            \_ ->
                List.map Rpc.Transport.name [ Rpc.Transport.connect, Rpc.Transport.connectGet, Rpc.Transport.withMaxGetUrl 10 Rpc.Transport.connectGet, Rpc.Transport.transcode ]
                    |> Expect.equal [ "connect", "connect", "connect", "transcode" ]
        , test "withMaxGetUrl leaves a transport that sends no GET as it was" <|
            \_ ->
                ( Rpc.request { base | transport = Rpc.Transport.withMaxGetUrl 1 Rpc.Transport.connect } (getNote { name = "x" })
                , Rpc.Transport.withMaxGetUrl 1 Rpc.Transport.transcode
                )
                    |> Expect.equal ( Rpc.request base (getNote { name = "x" }), Rpc.Transport.transcode )
        , test "the config's default is Connect, POST only" <|
            \_ ->
                base.transport
                    |> Expect.equal Rpc.Transport.connect
        ]


configs : Test
configs =
    describe "checkConfig"
        [ test "a base URL that is an origin or a path is fine" <|
            \_ ->
                [ "https://api.example.com", "https://api.example.com/v1/", "/api", "" ]
                    |> List.map (Rpc.config >> Rpc.checkConfig)
                    |> Expect.equal [ [], [], [], [] ]
        , test "a base URL holding a query or a fragment is reported" <|
            \_ ->
                [ "https://api.example.com/?key=1", "https://api.example.com/#top" ]
                    |> List.map (Rpc.config >> Rpc.checkConfig >> List.length)
                    |> Expect.equal [ 1, 1 ]
        , test "the report names the base URL" <|
            \_ ->
                Rpc.checkConfig (Rpc.config "https://api.example.com/?key=1")
                    |> List.all (String.contains "https://api.example.com/?key=1")
                    |> Expect.equal True
        , test "a header a request cannot carry is reported by name, its value left out" <|
            \_ ->
                let
                    cfg =
                        Rpc.config "https://api.example.com"
                in
                Rpc.checkConfig { cfg | headers = [ ( "Authorization", "Bearer s3cr3t\n" ), ( "X-Fine", "  ok  " ), ( "Bad Name", "v" ) ] }
                    |> List.map (\problem -> ( String.contains "\"Authorization\"" problem || String.contains "\"Bad Name\"" problem, String.contains "s3cr3t" problem ))
                    |> Expect.equal [ ( True, False ), ( True, False ) ]
        ]


limited : Rpc.Transport.Transport -> Int -> Rpc.Config
limited transport limit =
    { base | transport = Rpc.Transport.withReadMaxBytes limit transport }


{-| A 200 answer with this body to `getNote`, read under a config.
-}
readAs : Rpc.Config -> String -> Result Error String
readAs cfg body =
    Rpc.response cfg (getNote { name = "x" }) (Http.GoodStatus_ (metadata 200 "OK") body)


receiveLimits : Test
receiveLimits =
    let
        -- 13 UTF-16 units, 14 bytes of UTF-8: a limit read as String.length
        -- would let it through at 13.
        note =
            "{\"title\":\"é\"}"
    in
    describe "withReadMaxBytes"
        [ test "UTF-8 lengths: one to four bytes a character" <|
            \_ ->
                [ "", "a", "é", "€", "😀", "a😀é" ]
                    |> List.map Rpc.Internal.Http.utf8Length
                    |> Expect.equal [ 0, 1, 2, 3, 4, 7 ]
        , test "a multi-megabyte body is counted without exhausting the stack" <|
            \_ ->
                Rpc.Internal.Http.utf8Length (String.repeat 1000000 "aé€😀")
                    |> Expect.equal 10000000
        , test "a body at the limit is read, one byte over is refused with both sizes" <|
            \_ ->
                [ Rpc.Transport.connect, Rpc.Transport.connectGet, Rpc.Transport.transcode ]
                    |> List.map (\transport -> List.map (\limit -> readAs (limited transport limit) note |> withCode) [ 14, 13 ])
                    |> List.concat
                    |> Expect.equal
                        (List.concat
                            (List.repeat 3
                                [ Ok "é"
                                , Err ( NoAnswer (ResponseTooLarge { limit = 13, size = 14 }), ResourceExhausted, "message size 14 is larger than configured readMaxBytes 13" )
                                ]
                            )
                        )
        , test "every transport starts with no limit" <|
            \_ ->
                [ Rpc.Transport.connect, Rpc.Transport.connectGet, Rpc.Transport.transcode ]
                    |> List.map (\transport -> readAs { base | transport = transport } ("{\"title\":\"" ++ String.repeat 100000 "x" ++ "\"}") |> Result.map String.length)
                    |> Expect.equal [ Ok 100000, Ok 100000, Ok 100000 ]
        , test "an error answer is read whatever its size" <|
            \_ ->
                Rpc.response (limited Rpc.Transport.connect 1) (getNote { name = "x" }) (Http.BadStatus_ (metadata 404 "Not Found") "{\"code\":\"not_found\",\"message\":\"no note\"}")
                    |> Result.mapError (\error -> ( Rpc.Error.code error, Rpc.Error.message error ))
                    |> Expect.equal (Err ( NotFound, "no note" ))
        , test "a limit below 1 refuses any body but an empty one" <|
            \_ ->
                [ ( -5, "" ), ( 0, "" ), ( 0, "{}" ), ( -5, "{}" ) ]
                    |> List.map (\( limit, body ) -> Rpc.Internal.Http.overLimit limit body)
                    |> Expect.equal [ Nothing, Nothing, Just 2, Just 2 ]
        , test "checkConfig reports a limit below 1, not one of 1 or more" <|
            \_ ->
                [ 0, -1, 1, 1000000 ]
                    |> List.map (limited Rpc.Transport.connect >> Rpc.checkConfig >> List.length)
                    |> Expect.equal [ 1, 1, 0, 0 ]
        , test "the knob keeps the protocol and its other options" <|
            \_ ->
                ( List.map (Rpc.Transport.withReadMaxBytes 10 >> Rpc.Transport.name) [ Rpc.Transport.connect, Rpc.Transport.transcode ]
                , Rpc.request (limited (Rpc.Transport.withMaxGetUrl 30 Rpc.Transport.connectGet) 10) (getNote { name = "x" })
                    == Rpc.request (getting (Just 30)) (getNote { name = "x" })
                )
                    |> Expect.equal ( [ "connect", "transcode" ], True )
        ]


sendLimits : Test
sendLimits =
    let
        -- {"name":"é"}: 12 UTF-16 units, 13 bytes of UTF-8.
        call =
            getNote { name = "é" }

        json =
            Json.Encode.encode 0 (Rpc.Call.requestJson call)

        refused transport limit =
            Rpc.Internal.Http.requestTooLarge (Rpc.Transport.withWriteMaxBytes limit transport) (\() -> json)
                |> Maybe.map (\reason -> ( reason, Rpc.Error.code (NoAnswer reason), Rpc.Error.message (NoAnswer reason) ))
    in
    describe "withWriteMaxBytes"
        [ test "the request measured is the JSON a POST sends" <|
            \_ ->
                ( Rpc.request base call |> .body |> Rpc.Body.toText, String.length json )
                    |> Expect.equal ( Just json, 12 )
        , test "a request at the limit is sent, one byte over is refused with both sizes" <|
            \_ ->
                [ Rpc.Transport.connect, Rpc.Transport.connectGet, Rpc.Transport.transcode ]
                    |> List.concatMap (\transport -> [ refused transport 13, refused transport 12 ])
                    |> Expect.equal
                        (List.concat
                            (List.repeat 3
                                [ Nothing
                                , Just ( RequestTooLarge { limit = 12, size = 13 }, ResourceExhausted, "message size 13 is larger than configured writeMaxBytes 12" )
                                ]
                            )
                        )
        , test "every transport starts with no limit" <|
            \_ ->
                [ Rpc.Transport.connect, Rpc.Transport.connectGet, Rpc.Transport.transcode ]
                    |> List.map (\transport -> Rpc.Internal.Http.requestTooLarge transport (\() -> String.repeat 100000 "x"))
                    |> Expect.equal [ Nothing, Nothing, Nothing ]
        , test "with no limit the message is not encoded to be measured" <|
            \_ ->
                [ Rpc.Transport.connect, Rpc.Transport.connectGet, Rpc.Transport.transcode ]
                    |> List.map (\transport -> Rpc.Internal.Http.requestTooLarge transport (\() -> Debug.todo "the message was encoded"))
                    |> Expect.equal [ Nothing, Nothing, Nothing ]
        , test "checkConfig reports a limit below 1, not one of 1 or more" <|
            \_ ->
                [ 0, -1, 1, 1000000 ]
                    |> List.map (\limit -> Rpc.checkConfig { base | transport = Rpc.Transport.withWriteMaxBytes limit Rpc.Transport.transcode } |> List.length)
                    |> Expect.equal [ 1, 1, 0, 0 ]
        , test "the knob keeps the protocol and its other options" <|
            \_ ->
                ( List.map (Rpc.Transport.withWriteMaxBytes 10 >> Rpc.Transport.name) [ Rpc.Transport.connect, Rpc.Transport.transcode ]
                , Rpc.request { base | transport = Rpc.Transport.withWriteMaxBytes 10 (Rpc.Transport.withMaxGetUrl 30 Rpc.Transport.connectGet) } call
                    == Rpc.request (getting (Just 30)) call
                )
                    |> Expect.equal ( [ "connect", "transcode" ], True )
        ]


headerRules : Test
headerRules =
    describe "header validation"
        [ test "a value is refused for a newline, NUL or a character above U+00FF" <|
            \_ ->
                [ "ab\ncd", "ab\u{000D}cd", "名", "a\u{0000}b", "fine", "café", "", "a\tb" ]
                    |> List.map Rpc.Internal.Http.validHeaderValue
                    |> Expect.equal [ False, False, False, False, True, True, True, True ]
        , test "a value with spaces and tabs at either end is fine, a trailing newline is not" <|
            \_ ->
                [ "  Bearer x  ", "\tx\t", "x\n", "\u{000D}\nx" ]
                    |> List.map Rpc.Internal.Http.validHeaderValue
                    |> Expect.equal [ True, True, False, False ]
        , test "spaces and tabs anywhere are fine, an invalid character between them is not" <|
            \_ ->
                [ " ", "\t\t", " a b ", "a \t b", " \n ", "\t名\t", "  a\u{0000}  " ]
                    |> List.map Rpc.Internal.Http.validHeaderValue
                    |> Expect.equal [ True, True, True, True, False, False, False ]
        , test "control characters but NUL, LF and CR are fine, as is U+00FF, not U+0100" <|
            \_ ->
                [ "\u{0001}", "\u{001F}", "\u{007F}", "\u{0085}", "ÿ", "Ā" ]
                    |> List.map Rpc.Internal.Http.validHeaderValue
                    |> Expect.equal [ True, True, True, True, True, False ]
        , test "a lone surrogate is refused" <|
            \_ ->
                Rpc.Internal.Http.validHeaderValue (String.left 1 "😀")
                    |> Expect.equal False
        , test "a lone low surrogate is refused wherever it is, in a value or a name" <|
            \_ ->
                let
                    texts =
                        [ "\u{DC00}abc", "a\u{DC00}bc", "abc\u{DC00}", "\u{DC00}", String.right 1 "😀" ++ "x" ]
                in
                ( List.map Rpc.Internal.Http.validHeaderValue texts
                , List.map Rpc.Internal.Http.validHeaderName texts
                , Rpc.Internal.Http.invalidHeader [ ( "X-A", "1" ), ( "X-B", "a\u{DC00}" ) ]
                )
                    |> Expect.equal ( List.repeat 5 False, List.repeat 5 False, Just "X-B" )
        , test "a surrogate pair is one character above U+00FF" <|
            \_ ->
                ( Rpc.Internal.Http.validHeaderValue "a😀b", Rpc.Internal.Http.validHeaderName "a😀b" )
                    |> Expect.equal ( False, False )
        , test "a name must be a token" <|
            \_ ->
                [ "X-Request-Id", "x_y.z~!#$%&'*+^`|", "", "Bad Name", "a:b", "a\nb", "Ä", "(x)" ]
                    |> List.map Rpc.Internal.Http.validHeaderName
                    |> Expect.equal [ True, True, False, False, False, False, False, False ]
        , test "the first header a browser would refuse is named" <|
            \_ ->
                [ [ ( "A", "1" ), ( "B", "名" ), ( "C d", "3" ) ], [ ( "A", "1" ) ], [] ]
                    |> List.map Rpc.Internal.Http.invalidHeader
                    |> Expect.equal [ Just "B", Nothing, Nothing ]
        , test "the pure request keeps an invalid header, for sending to refuse" <|
            \_ ->
                (Rpc.request base (getNote { name = "x" } |> Rpc.Call.withHeaders [ ( "X-User", "名" ) ])).headers
                    |> List.member ( "X-User", "名" )
                    |> Expect.equal True
        , test "an invalid header is Internal, named in the message without its value" <|
            \_ ->
                NoAnswer (InvalidHeader "X-User")
                    |> (\error -> ( Rpc.Error.code error, Rpc.Error.message error ))
                    |> Expect.equal ( Internal, "invalid header \"X-User\"" )
        ]


bodies : Test
bodies =
    describe "Rpc.Body"
        [ test "text reads back, none has no text" <|
            \_ ->
                ( Rpc.Body.toText (Rpc.Body.text "{}"), Rpc.Body.toText Rpc.Body.none )
                    |> Expect.equal ( Just "{}", Nothing )
        , test "a GET has no body, a POST the request's JSON" <|
            \_ ->
                ( Rpc.Body.toText (Rpc.request (getting Nothing) (getNote { name = "x" })).body
                , Rpc.Body.toText (Rpc.request base (getNote { name = "x" })).body
                )
                    |> Expect.equal ( Nothing, Just "{\"name\":\"x\"}" )
        ]


traces : Test
traces =
    let
        sent =
            Rpc.request base (getNote { name = "notes/42" })

        trace error status attempts =
            Rpc.Internal.Trace.Trace
                { serviceName = "notes.v1.Notes"
                , methodName = "GetNote"
                , transport = "connect"
                , binding = Nothing
                , request = sent
                , httpStatus = status
                , headers = Dict.fromList [ ( "content-type", "application/json" ) ]
                , trailers = Dict.empty
                , code = error
                , duration = 12.4
                , attempts = attempts
                }

        succeeded =
            trace Nothing (Just 200) 1
    in
    describe "Rpc.Trace"
        [ test "toJson gives every field under its key" <|
            \_ ->
                Json.Encode.encode 0 (Rpc.Trace.toJson succeeded)
                    |> Expect.equal
                        ("""{"service":"notes.v1.Notes","method":"GetNote","transport":"connect","binding":null,"""
                            ++ """"request":{"method":"POST","url":"https://api.example.com/notes.v1.Notes/GetNote","headers":[["Connect-Protocol-Version","1"]],"body":"{\\"name\\":\\"notes/42\\"}","timeout":null,"withCredentials":false},"""
                            ++ """"httpStatus":200,"headers":{"content-type":"application/json"},"trailers":{},"code":"ok","duration":12.4,"attempts":1}"""
                        )
        , test "toJson gives a failure's code as Connect writes it" <|
            \_ ->
                trace (Just DeadlineExceeded) Nothing 2
                    |> Rpc.Trace.toJson
                    |> Json.Decode.decodeValue (Json.Decode.map2 Tuple.pair (Json.Decode.field "code" Json.Decode.string) (Json.Decode.field "httpStatus" (Json.Decode.null ())))
                    |> Expect.equal (Ok ( "deadline_exceeded", () ))
        , test "toString is one line without the request" <|
            \_ ->
                [ Rpc.Trace.toString succeeded
                , Rpc.Trace.toString (trace (Just Unavailable) Nothing 3)
                ]
                    |> Expect.equal
                        [ "notes.v1.Notes/GetNote over connect: ok, HTTP 200, 1 attempt, 12 ms"
                        , "notes.v1.Notes/GetNote over connect: unavailable, no answer, 3 attempts, 12 ms"
                        ]
        , test "the accessors" <|
            \_ ->
                ( ( Rpc.Trace.serviceName succeeded, Rpc.Trace.methodName succeeded, Rpc.Trace.transport succeeded )
                , ( Rpc.Trace.binding succeeded, Rpc.Trace.request succeeded == sent, Rpc.Trace.httpStatus succeeded )
                , ( Rpc.Trace.code succeeded, Rpc.Trace.duration succeeded, Rpc.Trace.attempts succeeded )
                )
                    |> Expect.equal
                        ( ( "notes.v1.Notes", "GetNote", "connect" )
                        , ( Nothing, True, Just 200 )
                        , ( Nothing, 12.4, 1 )
                        )
        ]


trailers : Test
trailers =
    let
        split pairs =
            Rpc.splitTrailers (Dict.fromList pairs)

        answered headers =
            { url = "https://api.example.com/notes.v1.Notes/GetNote"
            , statusCode = 200
            , statusText = "OK"
            , headers = Dict.fromList headers
            }

        -- How taskTraced fills a Trace's headers and trailers from an answer.
        traceMetadata answer =
            Rpc.Internal.Http.metadataOf answer
                |> Maybe.map (.headers >> Rpc.splitTrailers)
    in
    describe "headers and trailers"
        [ test "a trailer- header of any case is a trailer, its name without the prefix" <|
            \_ ->
                split [ ( "Trailer-X-Custom-Trailer", "a" ), ( "TRAILER-x-other", "b" ), ( "trailer-lower", "c" ) ]
                    |> Expect.equal
                        { headers = Dict.empty
                        , trailers = Dict.fromList [ ( "x-custom-trailer", "a" ), ( "x-other", "b" ), ( "lower", "c" ) ]
                        }
        , test "header names are lowercased" <|
            \_ ->
                split [ ( "Content-Type", "application/json" ), ( "X-Custom-Header", "v" ) ]
                    |> Expect.equal
                        { headers = Dict.fromList [ ( "content-type", "application/json" ), ( "x-custom-header", "v" ) ]
                        , trailers = Dict.empty
                        }
        , test "no trailer- headers leave the trailers empty" <|
            \_ ->
                (split [ ( "trailer", "x-custom-trailer" ), ( "grpc-trailer-x", "v" ) ]).trailers
                    |> Expect.equal Dict.empty
        , test "a header named trailer- alone stays a header" <|
            \_ ->
                split [ ( "Trailer-", "v" ) ]
                    |> Expect.equal { headers = Dict.fromList [ ( "trailer-", "v" ) ], trailers = Dict.empty }
        , test "names differing only in case are joined with a comma" <|
            \_ ->
                split [ ( "X-Dup", "a" ), ( "x-dup", "b" ), ( "Trailer-T", "c" ), ( "trailer-t", "d" ) ]
                    |> Expect.equal
                        { headers = Dict.fromList [ ( "x-dup", "a, b" ) ]
                        , trailers = Dict.fromList [ ( "t", "c, d" ) ]
                        }
        , test "an answer's headers reach the trace split" <|
            \_ ->
                Http.GoodStatus_ (answered [ ( "content-type", "application/json" ), ( "x-custom-header", "foo, bar" ), ( "trailer-x-custom-trailer", "baz" ) ]) "{}"
                    |> traceMetadata
                    |> Expect.equal
                        (Just
                            { headers = Dict.fromList [ ( "content-type", "application/json" ), ( "x-custom-header", "foo, bar" ) ]
                            , trailers = Dict.fromList [ ( "x-custom-trailer", "baz" ) ]
                            }
                        )
        , test "an error answer's headers reach the trace split" <|
            \_ ->
                Http.BadStatus_ (answered [ ( "trailer-x-custom-trailer", "baz" ) ]) "{}"
                    |> traceMetadata
                    |> Maybe.map .trailers
                    |> Expect.equal (Just (Dict.fromList [ ( "x-custom-trailer", "baz" ) ]))
        , test "no answer, no metadata" <|
            \_ ->
                [ Http.Timeout_, Http.NetworkError_, Http.BadUrl_ "x" ]
                    |> List.map traceMetadata
                    |> Expect.equal [ Nothing, Nothing, Nothing ]
        ]
