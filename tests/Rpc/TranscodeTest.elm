module Rpc.TranscodeTest exposing (suite)

import Dict
import Expect
import Http
import Json.Decode
import Json.Encode exposing (Value)
import Proto.Descriptor
import Proto.Message exposing (Message)
import Proto.Method exposing (Method)
import Rpc exposing (Error(..), Source(..))
import Rpc.ErrorCode exposing (ErrorCode(..))
import Test exposing (Test, describe, test)


type alias Rule =
    { method : String
    , path : List Proto.Descriptor.Segment
    , customVerb : Maybe String
    , body : Proto.Descriptor.Body
    , responseBody : Maybe String
    , query : List Proto.Descriptor.Param
    }


rule : Rule
rule =
    { method = "GET"
    , path = [ Proto.Descriptor.literal "v1" ]
    , customVerb = Nothing
    , body = Proto.Descriptor.noBody
    , responseBody = Nothing
    , query = []
    }


{-| A method whose request is its JSON, and whose response is its `title`,
bound by `bindings`.
-}
raw : List Rule -> Method Value String
raw bindings =
    { request = messageOf identity Json.Decode.value Json.Encode.null
    , response = messageOf (\t -> Json.Encode.object [ ( "title", Json.Encode.string t ) ]) (Json.Decode.field "title" Json.Decode.string) ""
    , descriptor =
        { service = "t.v1.T"
        , name = "M"
        , idempotent = False
        , input = "t.v1.Request"
        , output = "t.v1.Response"
        , bindings = List.map Proto.Descriptor.binding bindings
        }
    }


messageOf : (a -> Value) -> Json.Decode.Decoder a -> a -> Message a
messageOf encodeJson jsonDecoder default =
    { encodeJson = encodeJson
    , jsonDecoder = jsonDecoder
    , default = default
    , descriptor = { typeName = "t.v1.Message", fields = [], oneofs = [] }
    }


{-| A call of the method bound by `r` alone.
-}
bound : Rule -> String -> Rpc.Call Value String
bound r request =
    Rpc.call (raw [ r ]) (json request)


config : Rpc.Config
config =
    let
        base =
            Rpc.config "https://api.example.com"
    in
    { base | transport = Rpc.Transcode }


json : String -> Value
json text =
    Json.Decode.decodeString Json.Decode.value text
        |> Result.withDefault Json.Encode.null


url : Rule -> String -> String
url r request =
    (Rpc.request config (bound r request)).url


body : Rule -> String -> Maybe String
body r request =
    (Rpc.request config (bound r request)).body


suite : Test
suite =
    describe "Transcode"
        [ paths
        , queries
        , bodies
        , routes
        , responses
        , errors
        ]


paths : Test
paths =
    describe "paths"
        [ test "a single-segment variable escapes everything but unreserved characters" <|
            \_ ->
                url { rule | path = [ Proto.Descriptor.literal "v1", Proto.Descriptor.literal "messages", Proto.Descriptor.variable [ "messageId" ] [] ] }
                    """{"messageId":"a/b c?d#e!*'()é~._-"}"""
                    |> Expect.equal "https://api.example.com/v1/messages/a%2Fb%20c%3Fd%23e%21%2A%27%28%29%C3%A9~._-"
        , test "a multi-segment variable keeps its slashes" <|
            \_ ->
                url { rule | path = [ Proto.Descriptor.literal "v1", Proto.Descriptor.variable [ "name" ] [ Proto.Descriptor.literal "messages", Proto.Descriptor.wildcard ] ] }
                    """{"name":"messages/1 2"}"""
                    |> Expect.equal "https://api.example.com/v1/messages/1%202"
        , test "** keeps its slashes" <|
            \_ ->
                url { rule | path = [ Proto.Descriptor.literal "v1", Proto.Descriptor.variable [ "path" ] [ Proto.Descriptor.literal "files", Proto.Descriptor.doubleWildcard ] ] }
                    """{"path":"files/a/b/c.txt"}"""
                    |> Expect.equal "https://api.example.com/v1/files/a/b/c.txt"
        , test "{name=*} is one segment" <|
            \_ ->
                url { rule | path = [ Proto.Descriptor.variable [ "name" ] [ Proto.Descriptor.wildcard ] ] } """{"name":"a/b"}"""
                    |> Expect.equal "https://api.example.com/a%2Fb"
        , test "a nested field, numbers, booleans and a custom verb" <|
            \_ ->
                url
                    { rule
                        | path =
                            [ Proto.Descriptor.literal "v1"
                            , Proto.Descriptor.variable [ "sub", "subfield" ] []
                            , Proto.Descriptor.variable [ "n" ] []
                            , Proto.Descriptor.variable [ "f" ] []
                            , Proto.Descriptor.variable [ "b" ] []
                            ]
                        , customVerb = Just "cancel"
                    }
                    """{"sub":{"subfield":"x"},"n":42,"f":1.5,"b":true}"""
                    |> Expect.equal "https://api.example.com/v1/x/42/1.5/true:cancel"
        , test "an absent value is empty, and a trailing slash on the base URL is dropped" <|
            \_ ->
                (Rpc.request { config | baseUrl = "/api/" }
                    (bound { rule | path = [ Proto.Descriptor.literal "v1", Proto.Descriptor.variable [ "sub", "subfield" ] [] ] } """{"sub":null}""")
                ).url
                    |> Expect.equal "/api/v1/"
        ]


queries : Test
queries =
    let
        r =
            { rule
                | query =
                    [ Proto.Descriptor.param "revision" [ "revision" ] (Just "0")
                    , Proto.Descriptor.param "sub.subfield" [ "sub", "subfield" ] (Just "")
                    , Proto.Descriptor.param "kind" [ "kind" ] (Just "KIND_UNSPECIFIED")
                    , Proto.Descriptor.param "tags" [ "tags" ] Nothing
                    , Proto.Descriptor.param "pinned" [ "pinned" ] Nothing
                    , Proto.Descriptor.param "page_size" [ "pageSize" ] (Just "0")
                    ]
            }
    in
    describe "queries"
        [ test "zero values are left out" <|
            \_ ->
                url r """{"revision":"0","sub":{"subfield":""},"kind":"KIND_UNSPECIFIED","tags":[],"pinned":null,"pageSize":0}"""
                    |> Expect.equal "https://api.example.com/v1"
        , test "set values are sent by proto name, repeated ones repeated" <|
            \_ ->
                url r """{"revision":"2","sub":{"subfield":"foo bar"},"kind":"KIND_TEXT","tags":["a","b&c"],"pinned":false,"pageSize":10}"""
                    |> Expect.equal "https://api.example.com/v1?revision=2&sub.subfield=foo%20bar&kind=KIND_TEXT&tags=a&tags=b%26c&pinned=false&page_size=10"
        , test "a field with presence is sent at its default" <|
            \_ ->
                url r """{"pinned":false}"""
                    |> Expect.equal "https://api.example.com/v1?pinned=false"
        , test "an unset message leaves out its fields" <|
            \_ ->
                url r """{"sub":null}"""
                    |> Expect.equal "https://api.example.com/v1"
        ]


bodies : Test
bodies =
    describe "bodies"
        [ test "no body" <|
            \_ ->
                body rule """{"a":1}"""
                    |> Expect.equal Nothing
        , test "* sends every field outside the path" <|
            \_ ->
                body
                    { rule
                        | body = Proto.Descriptor.wholeBody
                        , path = [ Proto.Descriptor.variable [ "id" ] [], Proto.Descriptor.variable [ "sub", "subfield" ] [] ]
                    }
                    """{"id":"1","text":"hi","sub":{"subfield":"x","other":2}}"""
                    |> Expect.equal (Just """{"text":"hi","sub":{"other":2}}""")
        , test "a body field is sent whole" <|
            \_ ->
                body
                    { rule
                        | body = Proto.Descriptor.bodyField "message"
                        , path = [ Proto.Descriptor.variable [ "message", "messageId" ] [] ]
                    }
                    """{"messageId":"1","message":{"messageId":"1","text":"hi"}}"""
                    |> Expect.equal (Just """{"messageId":"1","text":"hi"}""")
        , test "an unset body field is an empty object" <|
            \_ ->
                body { rule | body = Proto.Descriptor.bodyField "message" } """{"message":null}"""
                    |> Expect.equal (Just "{}")
        , test "the method, headers, timeout and credentials come through, the call's headers last" <|
            \_ ->
                bound { rule | method = "PATCH" } "{}"
                    |> Rpc.withHeaders [ ( "X-Call", "1" ) ]
                    |> Rpc.withTimeout 10
                    |> Rpc.request { config | headers = [ ( "Authorization", "Bearer t" ) ], timeout = Just 30, withCredentials = True }
                    |> (\r -> ( ( r.method, r.headers ), ( r.timeout, r.withCredentials ) ))
                    |> Expect.equal ( ( "PATCH", [ ( "Authorization", "Bearer t" ), ( "X-Call", "1" ) ] ), ( Just 10, True ) )
        ]


routes : Test
routes =
    let
        twice =
            Rpc.call
                (raw
                    [ { rule | path = [ Proto.Descriptor.literal "v1", Proto.Descriptor.literal "first" ] }
                    , { rule | method = "POST", path = [ Proto.Descriptor.literal "v1", Proto.Descriptor.literal "second" ], body = Proto.Descriptor.wholeBody }
                    ]
                )
                (json """{"a":1}""")

        unbound =
            Rpc.call (raw []) (json """{"a":1}""")
    in
    describe "routes"
        [ test "the rule's own binding by default" <|
            \_ ->
                (Rpc.request config twice).url
                    |> Expect.equal "https://api.example.com/v1/first"
        , test "viaBinding picks an additional binding" <|
            \_ ->
                Rpc.viaBinding 1 twice
                    |> Maybe.map (Rpc.request config >> (\r -> ( r.method, r.url, r.body )))
                    |> Expect.equal (Just ( "POST", "https://api.example.com/v1/second", Just """{"a":1}""" ))
        , test "viaBinding 0 is the rule's own" <|
            \_ ->
                Rpc.viaBinding 0 twice
                    |> Maybe.map (Rpc.request config >> .url)
                    |> Expect.equal (Just "https://api.example.com/v1/first")
        , test "a method without a rule is the Connect POST, verbatim" <|
            \_ ->
                Rpc.request { config | timeout = Just 20 } unbound
                    |> Expect.equal
                        (Rpc.request
                            { config | transport = Rpc.connect, timeout = Just 20 }
                            unbound
                        )
        , test "the implicit route is a POST to the service and method" <|
            \_ ->
                Rpc.request config unbound
                    |> (\r -> ( r.method, r.url, r.headers ))
                    |> Expect.equal ( "POST", "https://api.example.com/t.v1.T/M", [ ( "Connect-Protocol-Version", "1" ) ] )
        , test "the implicit route reads any 2xx, an empty body as {}" <|
            \_ ->
                Rpc.response config unbound (Http.GoodStatus_ (metadata 201 "Created" []) """{"title":"hi"}""")
                    |> Expect.equal (Ok "hi")
        , test "there is no binding past the end, and none for a method without a rule" <|
            \_ ->
                [ Rpc.viaBinding 2 twice, Rpc.viaBinding -1 twice, Rpc.viaBinding 0 unbound, Rpc.viaBinding 1 unbound ]
                    |> List.map (Maybe.map Rpc.methodName)
                    |> Expect.equal [ Nothing, Nothing, Nothing, Nothing ]
        ]


metadata : Int -> String -> List ( String, String ) -> Http.Metadata
metadata status text headers =
    { url = "https://api.example.com/v1"
    , statusCode = status
    , statusText = text
    , headers = Dict.fromList headers
    }


respond : Rule -> Http.Response String -> Result Error String
respond r =
    Rpc.response config (bound r "{}")


responses : Test
responses =
    describe "responses"
        [ test "any 2xx decodes the response" <|
            \_ ->
                respond rule (Http.GoodStatus_ (metadata 201 "Created" []) """{"title":"hi"}""")
                    |> Expect.equal (Ok "hi")
        , test "an empty body reads as {}" <|
            \_ ->
                Rpc.response config
                    (Rpc.call
                        { request = messageOf identity Json.Decode.value Json.Encode.null
                        , response = messageOf (\_ -> Json.Encode.object []) (Json.Decode.succeed ()) ()
                        , descriptor =
                            { service = "t"
                            , name = "m"
                            , idempotent = False
                            , input = "t.Request"
                            , output = "t.Response"
                            , bindings = [ Proto.Descriptor.binding rule ]
                            }
                        }
                        Json.Encode.null
                    )
                    (Http.GoodStatus_ (metadata 204 "No Content" []) "")
                    |> Expect.equal (Ok ())
        , test "a response body field is the named field" <|
            \_ ->
                respond { rule | responseBody = Just "title" } (Http.GoodStatus_ (metadata 200 "OK" []) "\"hi\"")
                    |> Expect.equal (Ok "hi")
        , test "an undecodable body is a transport error" <|
            \_ ->
                case respond rule (Http.GoodStatus_ (metadata 200 "OK" []) "[]") of
                    Err (Transport (Http.BadBody _)) ->
                        Expect.pass

                    other ->
                        Expect.fail (Debug.toString other)
        , test "no answer is a transport error" <|
            \_ ->
                [ Http.Timeout_, Http.NetworkError_ ]
                    |> List.map (respond rule)
                    |> Expect.equal [ Err (Transport Http.Timeout), Err (Transport Http.NetworkError) ]
        ]


failed : Int -> String -> List ( String, String ) -> String -> Result Error String
failed status text headers raw_ =
    respond rule (Http.BadStatus_ (metadata status text headers) raw_)


rpc : ErrorCode -> String -> Source -> Result Error String
rpc code message source =
    Err (Rpc { code = code, message = message, details = [], source = source })


{-| The shared reader of failed answers, which both transports use.
-}
errors : Test
errors =
    describe "failed answers"
        [ test "a google.rpc.Status body" <|
            \_ ->
                failed 404 "Not Found" [] """{"code":5,"message":"no such note","details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"GONE"}]}"""
                    |> Result.mapError
                        (\error ->
                            case error of
                                Rpc r ->
                                    ( ( r.code, r.source ), r.message, List.map (Json.Encode.encode 0) r.details )

                                Transport _ ->
                                    ( ( Internal, ConnectBody ), "", [] )
                        )
                    |> Expect.equal
                        (Err ( ( NotFound, StatusBody 5 ), "no such note", [ """{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"GONE"}""" ] ))
        , test "a code outside 1 to 16 is Unknown, the number kept" <|
            \_ ->
                [ failed 500 "" [] """{"code":42}""", failed 500 "" [] """{"code":0,"message":"ok?"}""" ]
                    |> Expect.equal [ rpc Unknown "" (StatusBody 42), rpc Unknown "ok?" (StatusBody 0) ]
        , test "grpc-status 0 on a failed answer is Unknown" <|
            \_ ->
                failed 500 "" [ ( "grpc-status", "0" ) ] ""
                    |> Expect.equal (rpc Unknown "HTTP 500" GrpcHeaders)
        , test "grpc-status and grpc-message headers, when the body has no status" <|
            \_ ->
                failed 503 "Service Unavailable" [ ( "Grpc-Status", "14" ), ( "grpc-message", "back%20off %C3%A9" ) ] ""
                    |> Expect.equal (rpc Unavailable "back off é" GrpcHeaders)
        , test "grpc-status without grpc-message takes the status text" <|
            \_ ->
                failed 503 "Service Unavailable" [ ( "grpc-status", "8" ) ] ""
                    |> Expect.equal (rpc ResourceExhausted "Service Unavailable" GrpcHeaders)
        , test "otherwise the HTTP status, by Connect's table" <|
            \_ ->
                [ failed 404 "Not Found" [] "<html>", failed 400 "" [] "{\"error\":\"x\"}", failed 500 "" [ ( "grpc-status", "x" ) ] "" ]
                    |> Expect.equal
                        [ rpc Unimplemented "Not Found" (HttpStatus 404)
                        , rpc Internal "HTTP 400" (HttpStatus 400)
                        , rpc Unknown "HTTP 500" (HttpStatus 500)
                        ]
        , test "a Connect body comes before a status body and the headers" <|
            \_ ->
                failed 404 "" [ ( "grpc-status", "14" ) ] """{"code":"not_found","message":"connect"}"""
                    |> Expect.equal (rpc NotFound "connect" ConnectBody)
        , test "a status body comes before the headers" <|
            \_ ->
                failed 404 "" [ ( "grpc-status", "14" ) ] """{"code":5,"message":"status"}"""
                    |> Expect.equal (rpc NotFound "status" (StatusBody 5))
        , test "the headers come before the HTTP status" <|
            \_ ->
                failed 404 "Not Found" [ ( "grpc-status", "14" ) ] "<html>"
                    |> Expect.equal (rpc Unavailable "Not Found" GrpcHeaders)
        , test "Connect reads a status body and the headers too" <|
            \_ ->
                [ """{"code":5}""", "" ]
                    |> List.map
                        (\answer ->
                            Rpc.response (Rpc.config "https://api.example.com")
                                (Rpc.call (raw []) Json.Encode.null)
                                (Http.BadStatus_ (metadata 503 "" [ ( "grpc-status", "14" ) ]) answer)
                        )
                    |> Expect.equal [ rpc NotFound "" (StatusBody 5), rpc Unavailable "HTTP 503" GrpcHeaders ]
        ]
