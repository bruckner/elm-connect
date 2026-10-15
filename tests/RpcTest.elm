module RpcTest exposing (suite)

import Dict
import Expect
import Http
import Json.Decode
import Json.Encode
import Proto.Any
import Proto.Duration
import Proto.Http
import Proto.Message exposing (Message)
import Proto.WellKnown
import Rpc exposing (Error(..), Source(..))
import Rpc.ErrorCode exposing (ErrorCode(..))
import Rpc.Internal.Http
import Rpc.Internal.Retry as Retry
import Test exposing (Test, describe, test)


type alias GetNote =
    { name : String }


encodeGetNote : GetNote -> Json.Encode.Value
encodeGetNote r =
    Json.Encode.object [ ( "name", Json.Encode.string r.name ) ]


title : Message String
title =
    { encodeJson = \t -> Json.Encode.object [ ( "title", Json.Encode.string t ) ]
    , jsonDecoder = Json.Decode.field "title" Json.Decode.string
    , default = ""
    , descriptor = { typeName = "notes.v1.Note", fields = [], oneofs = [] }
    }


notes : String -> Bool -> List Proto.Http.Binding -> GetNote -> Rpc.Call GetNote String
notes name idempotent bindings =
    Rpc.call
        { encodeRequest = encodeGetNote
        , responseDecoder = title.jsonDecoder
        , descriptor =
            { service = "notes.v1.Notes"
            , name = name
            , idempotent = idempotent
            , input = "notes.v1.GetNoteRequest"
            , output = "notes.v1.Note"
            , bindings = bindings
            }
        }


getNote : GetNote -> Rpc.Call GetNote String
getNote =
    notes "GetNote" True []


createNote : GetNote -> Rpc.Call GetNote String
createNote =
    notes "CreateNote" False []


{-| A method with a rule and one additional binding.
-}
listNotes : GetNote -> Rpc.Call GetNote String
listNotes =
    notes "ListNotes"
        True
        [ Proto.Http.binding { method = "GET", path = [ Proto.Http.literal "v1", Proto.Http.literal "notes" ], customVerb = Nothing, body = Proto.Http.noBody, responseBody = Nothing, query = [] }
        , Proto.Http.binding { method = "GET", path = [ Proto.Http.literal "v2", Proto.Http.literal "notes" ], customVerb = Nothing, body = Proto.Http.noBody, responseBody = Nothing, query = [] }
        ]


base : Rpc.Config
base =
    Rpc.config "https://api.example.com"


getting : Maybe Int -> Rpc.Config
getting maxGetUrl =
    { base | transport = Rpc.Connect { useGet = True, maxGetUrl = maxGetUrl } }


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
an `Http` error keeps its status and status text, which are what it says.
`keptResponses` checks the answer itself.
-}
withoutResponse : Result Error a -> Result Error a
withoutResponse =
    Result.mapError
        (\error ->
            case error of
                Status r _ ->
                    Status r blank

                Http answer ->
                    httpError answer.statusCode answer.statusText

                _ ->
                    error
        )


blank : Rpc.Response
blank =
    { statusCode = 0, statusText = "", headers = Dict.empty, body = "" }


httpError : Int -> String -> Error
httpError status text =
    Http { blank | statusCode = status, statusText = text }


{-| An error with the code and message `Rpc.code` and `Rpc.message` read from
it.
-}
withCode : Result Error a -> Result ( Error, ErrorCode, String ) a
withCode =
    Result.mapError (\error -> ( error, Rpc.code error, Rpc.message error ))


fromBody : ErrorCode -> String -> Result Error String
fromBody code message =
    Err (Status { code = code, message = message, details = [], source = ConnectBody } blank)


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
        ]


type Msg
    = GotNote (Result Error String)


{-| `cancel` is a command, which elm-test cannot run; this checks that it
reports to the `toMsg` a call is sent with.
-}
cancelGotNote : Cmd Msg
cancelGotNote =
    Rpc.cancel "note-42" GotNote


calls : Test
calls =
    let
        c =
            getNote { name = "notes/42" }
    in
    describe "calls"
        [ test "read back" <|
            \_ ->
                ( ( Rpc.serviceName c, Rpc.methodName c ), ( Rpc.idempotent c, Rpc.requestMessage c ) )
                    |> Expect.equal ( ( "notes.v1.Notes", "GetNote" ), ( True, { name = "notes/42" } ) )
        , test "the method and its descriptor are the ones the call was made from" <|
            \_ ->
                ( ( (Rpc.method c).descriptor.input, Json.Encode.encode 0 ((Rpc.method c).encodeRequest { name = "x" }) ), (Rpc.descriptor c).name, (Rpc.descriptor c).output )
                    |> Expect.equal ( ( "notes.v1.GetNoteRequest", "{\"name\":\"x\"}" ), "GetNote", "notes.v1.Note" )
        , test "requestJson is the request's JSON" <|
            \_ ->
                Json.Encode.encode 0 (Rpc.requestJson c)
                    |> Expect.equal "{\"name\":\"notes/42\"}"
        , test "viaBinding gives a call for each binding the method has, and only those" <|
            \_ ->
                [ -1, 0, 1, 2 ]
                    |> List.map (\index -> Rpc.viaBinding index (listNotes { name = "x" }) |> Maybe.map Rpc.methodName)
                    |> Expect.equal [ Nothing, Just "ListNotes", Just "ListNotes", Nothing ]
        , test "a method without bindings has none to choose" <|
            \_ ->
                [ -1, 0, 1 ]
                    |> List.map (\index -> Rpc.viaBinding index c |> Maybe.map Rpc.methodName)
                    |> Expect.equal [ Nothing, Nothing, Nothing ]
        , test "toJson names the method and holds the request" <|
            \_ ->
                Json.Encode.encode 0 (Rpc.toJson (Rpc.withTimeout 5 c))
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
                        , body = Just "{\"name\":\"notes/42\"}"
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
                    |> Rpc.withHeaders [ ( "X-A", "1" ) ]
                    |> Rpc.withHeaders [ ( "X-B", "2" ) ]
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
                    |> Rpc.withTimeout 20
                    |> Rpc.request { base | timeout = Just 1000 }
                    |> (\r -> ( r.headers, r.timeout ))
                    |> Expect.equal
                        ( [ ( "Connect-Protocol-Version", "1" ), ( "Connect-Timeout-Ms", "20" ) ]
                        , Just 20
                        )
        , test "a timeout is at least one millisecond and at most ten digits" <|
            \_ ->
                [ 0, 0.4, 1.0e12 ]
                    |> List.map (\t -> (Rpc.request { base | timeout = Just t } (getNote { name = "x" })).headers)
                    |> Expect.equal
                        [ [ ( "Connect-Protocol-Version", "1" ), ( "Connect-Timeout-Ms", "1" ) ]
                        , [ ( "Connect-Protocol-Version", "1" ), ( "Connect-Timeout-Ms", "1" ) ]
                        , [ ( "Connect-Protocol-Version", "1" ), ( "Connect-Timeout-Ms", "9999999999" ) ]
                        ]
        , test "withCredentials is carried to the request" <|
            \_ ->
                (Rpc.request { base | withCredentials = True } (getNote { name = "x" })).withCredentials
                    |> Expect.equal True
        , test "useGet sends an idempotent call as a GET with the message in the query" <|
            \_ ->
                Rpc.request { base | transport = Rpc.Connect { useGet = True, maxGetUrl = Nothing }, timeout = Just 20 }
                    (getNote { name = "notes/42 é" })
                    |> Expect.equal
                        { method = "GET"
                        , url =
                            "https://api.example.com/notes.v1.Notes/GetNote"
                                ++ "?connect=v1&encoding=json&message="
                                ++ "%7B%22name%22%3A%22notes%2F42%20%C3%A9%22%7D"
                        , headers = [ ( "Connect-Timeout-Ms", "20" ) ]
                        , body = Nothing
                        , timeout = Just 20
                        , withCredentials = False
                        }
        , test "useGet still POSTs a call with side effects" <|
            \_ ->
                (Rpc.request (getting Nothing) (createNote { name = "x" })).method
                    |> Expect.equal "POST"
        , test "GET is off by default" <|
            \_ ->
                (Rpc.request base (getNote { name = "x" })).method
                    |> Expect.equal "POST"
        , test "maxGetUrl POSTs a call whose GET URL would be longer" <|
            \_ ->
                let
                    length =
                        String.length (Rpc.request (getting Nothing) (getNote { name = "x" })).url
                in
                [ length - 1, length, length + 1 ]
                    |> List.map (\limit -> (Rpc.request (getting (Just limit)) (getNote { name = "x" })).method)
                    |> Expect.equal [ "POST", "GET", "GET" ]
        , test "Connect ignores the binding chosen" <|
            \_ ->
                listNotes { name = "x" }
                    |> Rpc.viaBinding 1
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
        , test "200 with a body that does not decode is a transport error" <|
            \_ ->
                case Rpc.response base (getNote { name = "x" }) (Http.GoodStatus_ (metadata 200 "OK") "{}") of
                    Err (Transport (Http.BadBody _)) ->
                        Expect.pass

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
                                Status r _ ->
                                    ( r.code, r.message, List.map (\detail -> ( Proto.Any.typeUrl detail, Json.Encode.encode 0 (Proto.Any.encodeJson detail) )) r.details )

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
                                Status r _ ->
                                    List.map
                                        (\detail ->
                                            ( Proto.Any.typeName detail
                                            , Proto.Any.unpack title detail |> Maybe.map (Result.mapError problemWord)
                                            , Json.Encode.encode 0 (Proto.Any.encodeJson detail)
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
                            ( Rpc.details title error
                            , Rpc.details Proto.WellKnown.duration error |> List.map Proto.Duration.milliseconds
                            , case error of
                                Status r _ ->
                                    Just ( r.code, r.source, List.length r.details )

                                _ ->
                                    Nothing
                            )
                        )
                    |> Expect.equal (Err ( [ "hi" ], [ 2000 ], Just ( NotFound, StatusBody, 2 ) ))
        , test "details gives those of a type that decode, and an Http or transport error has none" <|
            \_ ->
                ( failed 400
                    "Bad Request"
                    """{"code":"invalid_argument","details":[{"type":"notes.v1.Note","value":"","debug":{"title":"one"}},{"type":"notes.v1.Note","value":"CgA"},{"type":"notes.v1.Note","value":"","debug":{"title":2}},{"type":"other.v1.Thing","value":"","debug":{"title":"no"}},{"type":"notes.v1.Note","value":"","debug":{"title":"two"}}]}"""
                    |> Result.mapError (Rpc.details title)
                , ( Rpc.details title (httpError 404 "Not Found"), Rpc.details title (Transport Http.Timeout) )
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
        , test "a body without a code is an Http error, its code inferred from the HTTP status" <|
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
        , test "an Http error's message is its status text when there is one" <|
            \_ ->
                failed 502 "Bad Gateway" "upstream reset"
                    |> withCode
                    |> Expect.equal (Err ( httpError 502 "Bad Gateway", Unavailable, "Bad Gateway" ))
        , test "no answer is a transport error" <|
            \_ ->
                [ Http.Timeout_, Http.NetworkError_, Http.BadUrl_ "::" ]
                    |> List.map (Rpc.response base (getNote { name = "x" }))
                    |> Expect.equal
                        [ Err (Transport Http.Timeout)
                        , Err (Transport Http.NetworkError)
                        , Err (Transport (Http.BadUrl "::"))
                        ]
        , test "a transport error has the code the Connect clients give it" <|
            \_ ->
                [ Http.Timeout, Http.NetworkError, Http.BadUrl "::", Http.BadBody "oops", Http.BadStatus 503 ]
                    |> List.map (Transport >> (\error -> ( Rpc.code error, Rpc.message error )))
                    |> Expect.equal
                        [ ( DeadlineExceeded, "timeout" )
                        , ( Unavailable, "network error" )
                        , ( Internal, "bad URL: ::" )
                        , ( Internal, "bad response body: oops" )
                        , ( Unavailable, "HTTP 503" )
                        ]
        , test "errorToString is the code and the message" <|
            \_ ->
                [ Status { code = NotFound, message = "no note", details = [], source = ConnectBody } blank
                , Status { code = Internal, message = "", details = [], source = StatusBody } blank
                , httpError 404 "Not Found"
                , httpError 400 ""
                , Transport Http.Timeout
                , Transport Http.NetworkError
                , Transport (Http.BadUrl "::")
                , Transport (Http.BadBody "oops")
                , Rpc.Canceled
                ]
                    |> List.map Rpc.errorToString
                    |> Expect.equal
                        [ "not_found: no note"
                        , "internal"
                        , "unimplemented: Not Found"
                        , "internal: HTTP 400"
                        , "deadline_exceeded: timeout"
                        , "unavailable: network error"
                        , "internal: bad URL: ::"
                        , "internal: bad response body: oops"
                        , "canceled"
                        ]
        , test "a canceled call has the code Canceled, no message and no details" <|
            \_ ->
                ( Rpc.code Rpc.Canceled, Rpc.message Rpc.Canceled, Rpc.details title Rpc.Canceled )
                    |> Expect.equal ( Rpc.ErrorCode.Canceled, "", [] )
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
                                ( got.statusCode, Dict.get "x-request-id" got.headers, got.body )
                        in
                        case error of
                            Status r got ->
                                Just ( Just r.source, kept got )

                            Http got ->
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
        , test "an Http error, the body in a shape the reader does not know" <|
            \_ ->
                answer 404 [ ( "x-request-id", "r4" ) ] legacy
                    |> Expect.equal (Err (Just ( Nothing, ( 404, Just "r4", legacy ) )))
        , test "a 2xx that is not a Connect success keeps its answer too" <|
            \_ ->
                Rpc.response base (getNote { name = "x" }) (Http.GoodStatus_ (metadata 204 "No Content") "")
                    |> Result.mapError
                        (\error ->
                            case error of
                                Http got ->
                                    Just ( got.statusCode, got.statusText, got.body )

                                _ ->
                                    Nothing
                        )
                    |> Expect.equal (Err (Just ( 204, "No Content", "" )))
        ]


retries : Test
retries =
    let
        policy =
            { attempts = 3, backoff = 100, codes = [ Unavailable ], idempotentOnly = True }
    in
    describe "retry policy"
        [ test "a listed code waits the backoff, doubled per attempt, until attempts run out" <|
            \_ ->
                [ 1, 2, 3 ]
                    |> List.map (\tried -> Retry.delay policy True tried (Just Unavailable))
                    |> Expect.equal [ Just 100, Just 200, Nothing ]
        , test "a code not listed stops" <|
            \_ ->
                Retry.delay policy True 1 (Just NotFound)
                    |> Expect.equal Nothing
        , test "a failure without a code stops" <|
            \_ ->
                Retry.delay policy True 1 Nothing
                    |> Expect.equal Nothing
        , test "idempotentOnly stops a call with side effects" <|
            \_ ->
                ( Retry.delay policy False 1 (Just Unavailable)
                , Retry.delay { policy | idempotentOnly = False } False 1 (Just Unavailable)
                )
                    |> Expect.equal ( Nothing, Just 100 )
        , test "one attempt never retries" <|
            \_ ->
                Retry.delay { policy | attempts = 1 } True 1 (Just Unavailable)
                    |> Expect.equal Nothing
        , test "a timeout retries when DeadlineExceeded is listed, and not otherwise" <|
            \_ ->
                ( Retry.delay { policy | codes = [ DeadlineExceeded ] } True 1 (Just (Rpc.code (Transport Http.Timeout)))
                , Retry.delay policy True 1 (Just (Rpc.code (Transport Http.Timeout)))
                )
                    |> Expect.equal ( Just 100, Nothing )
        , test "a network failure retries when Unavailable is listed" <|
            \_ ->
                Retry.delay policy True 1 (Just (Rpc.code (Transport Http.NetworkError)))
                    |> Expect.equal (Just 100)
        , test "idempotentOnly stops a transport failure of a call with side effects" <|
            \_ ->
                ( Retry.delay policy False 1 (Just (Rpc.code (Transport Http.NetworkError)))
                , Retry.delay { policy | codes = [ DeadlineExceeded ] } False 1 (Just (Rpc.code (Transport Http.Timeout)))
                )
                    |> Expect.equal ( Nothing, Nothing )
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
