module RpcTest exposing (suite)

import Dict
import Expect
import Http
import Json.Decode
import Json.Encode
import Proto.Http
import Proto.Message exposing (Message)
import Rpc exposing (Error(..), Source(..))
import Rpc.ErrorCode exposing (ErrorCode(..))
import Rpc.Internal.Retry as Retry
import Test exposing (Test, describe, test)


type alias GetNote =
    { name : String }


getNoteRequest : Message GetNote
getNoteRequest =
    { encodeJson = \r -> Json.Encode.object [ ( "name", Json.Encode.string r.name ) ]
    , jsonDecoder = Json.Decode.map GetNote (Json.Decode.field "name" Json.Decode.string)
    , default = { name = "" }
    , descriptor = { typeName = "notes.v1.GetNoteRequest", fields = [], oneofs = [] }
    }


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
        { request = getNoteRequest
        , response = title
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


fromStatus : ErrorCode -> Int -> String -> Result Error String
fromStatus code status message =
    Err (Rpc { code = code, message = message, details = [], source = HttpStatus status })


fromBody : ErrorCode -> String -> Result Error String
fromBody code message =
    Err (Rpc { code = code, message = message, details = [], source = ConnectBody })


suite : Test
suite =
    describe "Rpc"
        [ calls
        , requests
        , responses
        , retries
        ]


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
                ( (Rpc.method c).request.descriptor.typeName, (Rpc.descriptor c).name, (Rpc.descriptor c).output )
                    |> Expect.equal ( "notes.v1.GetNoteRequest", "GetNote", "notes.v1.Note" )
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
                    |> Expect.equal (fromStatus Unknown 204 "No Content")
        , test "a Connect error body gives code, message and details" <|
            \_ ->
                failed 404
                    "Not Found"
                    """{"code":"not_found","message":"no note","details":[{"type":"google.rpc.RetryInfo","value":"CgIIPA"}]}"""
                    |> Result.mapError
                        (\error ->
                            case error of
                                Rpc r ->
                                    ( r.code, r.message, List.map (Json.Encode.encode 0) r.details )

                                Transport _ ->
                                    ( Internal, "transport", [] )
                        )
                    |> Expect.equal
                        (Err ( NotFound, "no note", [ "{\"type\":\"google.rpc.RetryInfo\",\"value\":\"CgIIPA\"}" ] ))
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
        , test "a body without a code maps from the HTTP status" <|
            \_ ->
                [ ( 400, "{}" ), ( 401, "" ), ( 403, "<html>" ), ( 404, "{\"code\":null}" ), ( 429, "" ), ( 502, "" ), ( 503, "" ), ( 504, "" ), ( 500, "" ), ( 409, "" ) ]
                    |> List.map (\( status, body ) -> failed status "" body)
                    |> Expect.equal
                        [ fromStatus Internal 400 "HTTP 400"
                        , fromStatus Unauthenticated 401 "HTTP 401"
                        , fromStatus PermissionDenied 403 "HTTP 403"
                        , fromStatus Unimplemented 404 "HTTP 404"
                        , fromStatus Unavailable 429 "HTTP 429"
                        , fromStatus Unavailable 502 "HTTP 502"
                        , fromStatus Unavailable 503 "HTTP 503"
                        , fromStatus Unavailable 504 "HTTP 504"
                        , fromStatus Unknown 500 "HTTP 500"
                        , fromStatus Unknown 409 "HTTP 409"
                        ]
        , test "the status text is the message when there is one" <|
            \_ ->
                failed 502 "Bad Gateway" "upstream reset"
                    |> Expect.equal (fromStatus Unavailable 502 "Bad Gateway")
        , test "no answer is a transport error" <|
            \_ ->
                [ Http.Timeout_, Http.NetworkError_, Http.BadUrl_ "::" ]
                    |> List.map (Rpc.response base (getNote { name = "x" }))
                    |> Expect.equal
                        [ Err (Transport Http.Timeout)
                        , Err (Transport Http.NetworkError)
                        , Err (Transport (Http.BadUrl "::"))
                        ]
        , test "errorToString" <|
            \_ ->
                [ Rpc { code = NotFound, message = "no note", details = [], source = ConnectBody }
                , Rpc { code = Internal, message = "", details = [], source = HttpStatus 400 }
                , Transport Http.Timeout
                , Transport (Http.BadBody "oops")
                ]
                    |> List.map Rpc.errorToString
                    |> Expect.equal [ "not_found: no note", "internal", "timeout", "bad response body: oops" ]
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
        ]
