module Rpc.TranscodeTest exposing (suite)

import Dict
import Expect
import Http
import Json.Decode
import Json.Encode exposing (Value)
import Proto.Enum
import Proto.EnumValue
import Proto.Field exposing (Cardinality(..), Kind(..), Scalar(..))
import Proto.Http
import Proto.Json
import Proto.Method exposing (Idempotency(..), Method)
import Rpc
import Rpc.Body
import Rpc.Call
import Rpc.Code exposing (Code(..))
import Rpc.Error exposing (Error(..), Reason(..), Source(..))
import Rpc.Transport
import Test exposing (Test, describe, test)


type alias Rule =
    { method : String
    , path : List Proto.Http.Segment
    , customVerb : Maybe String
    , body : Proto.Http.Body
    , responseBody : Maybe Proto.Field.Descriptor
    , query : List Proto.Http.Param
    }


rule : Rule
rule =
    { method = "GET"
    , path = [ Proto.Http.literal "v1" ]
    , customVerb = Nothing
    , body = Proto.Http.noBody
    , responseBody = Nothing
    , query = []
    }


{-| A field of a request, as a generated descriptor module declares one: its
proto name, its JSON name, how many values it holds and their kind.
-}
field : String -> String -> Cardinality -> Kind -> Proto.Field.Descriptor
field protoName jsonName =
    Proto.Field.descriptor protoName jsonName 1


string : String -> String -> Proto.Field.Descriptor
string protoName jsonName =
    field protoName jsonName CardinalitySingular (KindScalar ScalarString)


sub : String -> String -> Proto.Field.Descriptor
sub protoName jsonName =
    field protoName jsonName CardinalitySingular (KindMessage "t.v1.Sub")


{-| A `google.protobuf.Timestamp` field `at`.
-}
timestamp : Proto.Field.Descriptor
timestamp =
    field "at" "at" CardinalitySingular (KindMessage "google.protobuf.Timestamp")


kind : Proto.Enum.Descriptor
kind =
    Proto.Enum.descriptor "t.v1.Kind" [ Proto.EnumValue.descriptor "KIND_UNSPECIFIED" 0, Proto.EnumValue.descriptor "KIND_TEXT" 1 ]


{-| A path variable of this field path, without a template.
-}
var : List Proto.Field.Descriptor -> Proto.Http.Segment
var fieldPath =
    Proto.Http.variable { fieldPath = fieldPath, template = [] }


{-| A method whose request is its JSON, and whose response is its `title`,
bound by `bindings`.
-}
raw : List Rule -> Method Value String
raw bindings =
    Proto.Method.method identity
        (Json.Decode.field "title" Json.Decode.string)
        (Proto.Method.descriptor "t.v1.T" "M" IdempotencyUnknown "t.v1.Request" "t.v1.Response" (List.map Proto.Http.binding bindings))


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
    { base | transport = Rpc.Transport.transcode }


json : String -> Value
json text =
    Json.Decode.decodeString Json.Decode.value text
        |> Result.withDefault Json.Encode.null


url : Rule -> String -> String
url r request =
    (Rpc.request config (bound r request)).url


body : Rule -> String -> Maybe String
body r request =
    Rpc.Body.toText (Rpc.request config (bound r request)).body


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
                url { rule | path = [ Proto.Http.literal "v1", Proto.Http.literal "messages", var [ string "message_id" "messageId" ] ] }
                    """{"messageId":"a/b c?d#e!*'()é~._-"}"""
                    |> Expect.equal "https://api.example.com/v1/messages/a%2Fb%20c%3Fd%23e%21%2A%27%28%29%C3%A9~._-"
        , test "a multi-segment variable keeps its slashes" <|
            \_ ->
                url { rule | path = [ Proto.Http.literal "v1", Proto.Http.variable { fieldPath = [ string "name" "name" ], template = [ Proto.Http.literal "messages", Proto.Http.wildcard ] } ] }
                    """{"name":"messages/1 2"}"""
                    |> Expect.equal "https://api.example.com/v1/messages/1%202"
        , test "** keeps its slashes" <|
            \_ ->
                url { rule | path = [ Proto.Http.literal "v1", Proto.Http.variable { fieldPath = [ string "path" "path" ], template = [ Proto.Http.literal "files", Proto.Http.doubleWildcard ] } ] }
                    """{"path":"files/a/b/c.txt"}"""
                    |> Expect.equal "https://api.example.com/v1/files/a/b/c.txt"
        , test "{name=*} is one segment" <|
            \_ ->
                url { rule | path = [ Proto.Http.variable { fieldPath = [ string "name" "name" ], template = [ Proto.Http.wildcard ] } ] } """{"name":"a/b"}"""
                    |> Expect.equal "https://api.example.com/a%2Fb"
        , test "a hand-built literal or verb is percent-encoded where a path segment cannot hold it" <|
            \_ ->
                url
                    { rule
                        | path =
                            [ Proto.Http.literal "x#y"
                            , Proto.Http.literal "a b/c"
                            , Proto.Http.literal "é"
                            , Proto.Http.literal "50%"
                            , Proto.Http.literal "%zz"
                            ]
                        , customVerb = Just "run?x"
                    }
                    "{}"
                    |> Expect.equal "https://api.example.com/x%23y/a%20b%2Fc/%C3%A9/50%25/%25zz:run%3Fx"
        , test "a literal's escapes and the characters a path segment holds are kept" <|
            \_ ->
                url { rule | path = [ Proto.Http.literal "%2e%2E", Proto.Http.literal "!$&'()*+,;=:@-._~" ], customVerb = Just "do:it" } "{}"
                    |> Expect.equal "https://api.example.com/%2e%2E/!$&'()*+,;=:@-._~:do:it"
        , test "a nested field, numbers, booleans and a custom verb" <|
            \_ ->
                url
                    { rule
                        | path =
                            [ Proto.Http.literal "v1"
                            , var [ sub "sub" "sub", string "subfield" "subfield" ]
                            , var [ field "n" "n" CardinalitySingular (KindScalar ScalarInt32) ]
                            , var [ field "f" "f" CardinalitySingular (KindScalar ScalarDouble) ]
                            , var [ field "b" "b" CardinalitySingular (KindScalar ScalarBool) ]
                            ]
                        , customVerb = Just "cancel"
                    }
                    """{"sub":{"subfield":"x"},"n":42,"f":1.5,"b":true}"""
                    |> Expect.equal "https://api.example.com/v1/x/42/1.5/true:cancel"
        , test "an absent string is empty, and a trailing slash on the base URL is dropped" <|
            \_ ->
                (Rpc.request { config | baseUrl = "/api/" }
                    (bound { rule | path = [ Proto.Http.literal "v1", var [ sub "sub" "sub", string "subfield" "subfield" ] ] } """{"sub":null}""")
                ).url
                    |> Expect.equal "/api/v1/"
        , test "a well-known path variable is its JSON text, and the query holds the other fields" <|
            \_ ->
                url
                    { rule
                        | path = [ Proto.Http.literal "v1", Proto.Http.literal "at", var [ timestamp ] ]
                        , query = [ Proto.Http.param [ string "note" "note" ] ]
                    }
                    """{"at":"2026-10-20T12:34:56.500Z","note":"x"}"""
                    |> Expect.equal "https://api.example.com/v1/at/2026-10-20T12%3A34%3A56.500Z?note=x"
        , test "an unset well-known path variable is empty, as an unset string is" <|
            \_ ->
                url { rule | path = [ Proto.Http.literal "v1", Proto.Http.literal "at", var [ timestamp ], var [ field "count" "count" CardinalitySingular (KindMessage "google.protobuf.Int32Value") ] ] }
                    "{}"
                    |> Expect.equal "https://api.example.com/v1/at//"
        , test "a value under an unset message is the field's default" <|
            \_ ->
                url { rule | path = [ Proto.Http.literal "v1", var [ sub "inner" "inner", sub "deep" "deep", field "b" "b" CardinalitySingular (KindScalar ScalarUint64) ], var [ sub "inner" "inner", field "kind" "kind" CardinalitySingular (KindEnum kind) ] ] }
                    """{"inner":null}"""
                    |> Expect.equal "https://api.example.com/v1/0/KIND_UNSPECIFIED"
        , test "a value missing from the JSON is the field's default" <|
            \_ ->
                url { rule | path = [ Proto.Http.literal "v1", var [ field "n" "n" CardinalitySingular (KindScalar ScalarSint64) ], var [ field "b" "b" CardinalitySingular (KindScalar ScalarBool) ] ] } "{}"
                    |> Expect.equal "https://api.example.com/v1/0/false"
        , test "a value at its default in a set message is written as it is" <|
            \_ ->
                url { rule | path = [ Proto.Http.literal "v1", var [ sub "inner" "inner", sub "deep" "deep", field "b" "b" CardinalitySingular (KindScalar ScalarInt32) ] ] }
                    """{"inner":{"deep":{"b":0}}}"""
                    |> Expect.equal "https://api.example.com/v1/0"
        ]


queries : Test
queries =
    let
        r =
            { rule
                | query =
                    [ Proto.Http.param [ field "revision" "revision" CardinalitySingular (KindScalar ScalarInt64) ]
                    , Proto.Http.param [ sub "sub" "sub", string "subfield" "subfield" ]
                    , Proto.Http.param [ field "kind" "kind" CardinalitySingular (KindEnum kind) ]
                    , Proto.Http.param [ field "tags" "tags" CardinalityRepeated (KindScalar ScalarString) ]
                    , Proto.Http.param [ field "pinned" "pinned" CardinalityOptional (KindScalar ScalarBool) ]
                    , Proto.Http.param [ field "page_size" "pageSize" CardinalitySingular (KindScalar ScalarInt32) ]
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
        , test "a oneof member and a message are left out only when unset" <|
            \_ ->
                url
                    { rule
                        | query =
                            [ Proto.Http.param [ string "author" "author" |> Proto.Field.inOneof "filter" ]
                            , Proto.Http.param [ field "only" "only" CardinalitySingular (KindEnum kind) |> Proto.Field.inOneof "filter" ]
                            , Proto.Http.param [ field "since" "since" CardinalitySingular (KindMessage "google.protobuf.Timestamp") ]
                            , Proto.Http.param [ field "limit" "limit" CardinalitySingular (KindMessage "google.protobuf.Int32Value") ]
                            , Proto.Http.param [ field "data" "data" CardinalitySingular (KindScalar ScalarBytes) ]
                            ]
                    }
                    """{"author":"","only":"KIND_UNSPECIFIED","since":"1970-01-01T00:00:00Z","limit":0,"data":""}"""
                    |> Expect.equal "https://api.example.com/v1?author=&only=KIND_UNSPECIFIED&since=1970-01-01T00%3A00%3A00Z&limit=0"
        , test "the parameter's name is the dotted proto names, its value read by JSON names" <|
            \_ ->
                url { rule | query = [ Proto.Http.param [ sub "sub_message" "subMessage", string "page_token" "pageToken" ] ] }
                    """{"subMessage":{"pageToken":"t"}}"""
                    |> Expect.equal "https://api.example.com/v1?sub_message.page_token=t"
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
                        | body = Proto.Http.wholeBody
                        , path = [ var [ string "id" "id" ], var [ sub "sub" "sub", string "subfield" "subfield" ] ]
                    }
                    """{"id":"1","text":"hi","sub":{"subfield":"x","other":2}}"""
                    |> Expect.equal (Just """{"text":"hi","sub":{"other":2}}""")
        , test "a body field is sent whole" <|
            \_ ->
                body
                    { rule
                        | body = Proto.Http.bodyField (sub "message" "message")
                        , path = [ var [ sub "message" "message", string "message_id" "messageId" ] ]
                    }
                    """{"messageId":"1","message":{"messageId":"1","text":"hi"}}"""
                    |> Expect.equal (Just """{"messageId":"1","text":"hi"}""")
        , test "an unset body field is an empty object" <|
            \_ ->
                body { rule | body = Proto.Http.bodyField (sub "message" "message") } """{"message":null}"""
                    |> Expect.equal (Just "{}")
        , test "a body field is read by its JSON name" <|
            \_ ->
                body { rule | body = Proto.Http.bodyField (sub "the_message" "theMessage") } """{"the_message":{"a":1},"theMessage":{"b":2}}"""
                    |> Expect.equal (Just """{"b":2}""")
        , test "the method, headers, timeout and credentials come through, the call's headers last" <|
            \_ ->
                bound { rule | method = "PATCH" } "{}"
                    |> Rpc.Call.withHeaders [ ( "X-Call", "1" ) ]
                    |> Rpc.Call.withTimeout 10
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
                    [ { rule | path = [ Proto.Http.literal "v1", Proto.Http.literal "first" ] }
                    , { rule | method = "POST", path = [ Proto.Http.literal "v1", Proto.Http.literal "second" ], body = Proto.Http.wholeBody }
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
                Rpc.Call.viaBinding 1 twice
                    |> Maybe.map (Rpc.request config >> (\r -> ( r.method, r.url, Rpc.Body.toText r.body )))
                    |> Expect.equal (Just ( "POST", "https://api.example.com/v1/second", Just """{"a":1}""" ))
        , test "viaBinding 0 is the rule's own" <|
            \_ ->
                Rpc.Call.viaBinding 0 twice
                    |> Maybe.map (Rpc.request config >> .url)
                    |> Expect.equal (Just "https://api.example.com/v1/first")
        , test "a method without a rule is the Connect POST, verbatim" <|
            \_ ->
                Rpc.request { config | timeout = Just 20 } unbound
                    |> Expect.equal
                        (Rpc.request
                            { config | transport = Rpc.Transport.connect, timeout = Just 20 }
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
                [ Rpc.Call.viaBinding 2 twice, Rpc.Call.viaBinding -1 twice, Rpc.Call.viaBinding 0 unbound, Rpc.Call.viaBinding 1 unbound ]
                    |> List.map (Maybe.map Rpc.Call.methodName)
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
                        (Proto.Method.method identity
                            (Json.Decode.succeed ())
                            (Proto.Method.descriptor "t" "m" IdempotencyUnknown "t.Request" "t.Response" [ Proto.Http.binding rule ])
                        )
                        Json.Encode.null
                    )
                    (Http.GoodStatus_ (metadata 204 "No Content" []) "")
                    |> Expect.equal (Ok ())
        , test "a response body field is the named field" <|
            \_ ->
                respond { rule | responseBody = Just (string "title" "title") } (Http.GoodStatus_ (metadata 200 "OK" []) "\"hi\"")
                    |> Expect.equal (Ok "hi")
        , test "an undecodable body is a bad response, the answer kept" <|
            \_ ->
                case respond rule (Http.GoodStatus_ (metadata 201 "Created" []) "[]") of
                    Err (BadResponse _ answer) ->
                        ( answer.statusCode, Maybe.withDefault "" (Rpc.Body.toText answer.body) )
                            |> Expect.equal ( 201, "[]" )

                    other ->
                        Expect.fail (Debug.toString other)
        , test "no answer is NoAnswer" <|
            \_ ->
                [ Http.Timeout_, Http.NetworkError_ ]
                    |> List.map (respond rule)
                    |> Expect.equal [ Err (NoAnswer Timeout), Err (NoAnswer NetworkError) ]
        ]


failed : Int -> String -> List ( String, String ) -> String -> Result Error String
failed status text headers raw_ =
    respond rule (Http.BadStatus_ (metadata status text headers) raw_)
        |> withoutResponse


{-| An error with its answer blanked, for tests about what was read from it;
an `HttpStatus` error keeps its status and status text, which are what it says.
`RpcTest` checks the answer itself.
-}
withoutResponse : Result Error a -> Result Error a
withoutResponse =
    Result.mapError
        (\error ->
            case error of
                RpcStatus r _ ->
                    RpcStatus r blank

                HttpStatus answer ->
                    HttpStatus { blank | statusCode = answer.statusCode, statusText = answer.statusText }

                _ ->
                    error
        )


blank : Rpc.Response
blank =
    { url = "", statusCode = 0, statusText = "", headers = Dict.empty, body = Rpc.Body.text "" }


stated : Code -> String -> Source -> Result Error a
stated code message source =
    Err (RpcStatus { code = code, message = message, details = [], source = source } blank)


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
                                RpcStatus r _ ->
                                    Just ( ( r.code, r.source ), r.message, List.map (Proto.Json.encodeAny >> Json.Encode.encode 0) r.details )

                                _ ->
                                    Nothing
                        )
                    |> Expect.equal
                        (Err (Just ( ( NotFound, StatusBody ), "no such note", [ """{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"GONE"}""" ] )))
        , test "a code outside 1 to 16 is Unknown" <|
            \_ ->
                [ failed 500 "" [] """{"code":42}""", failed 500 "" [] """{"code":0,"message":"ok?"}""" ]
                    |> Expect.equal [ stated Unknown "" StatusBody, stated Unknown "ok?" StatusBody ]
        , test "grpc-status 0 on a failed answer is Unknown" <|
            \_ ->
                failed 500 "" [ ( "grpc-status", "0" ) ] ""
                    |> Expect.equal (stated Unknown "HTTP 500" GrpcHeaders)
        , test "grpc-status and grpc-message headers, when the body has no status" <|
            \_ ->
                failed 503 "Service Unavailable" [ ( "Grpc-Status", "14" ), ( "grpc-message", "back%20off %C3%A9" ) ] ""
                    |> Expect.equal (stated Unavailable "back off é" GrpcHeaders)
        , test "grpc-status without grpc-message takes the status text" <|
            \_ ->
                failed 503 "Service Unavailable" [ ( "grpc-status", "8" ) ] ""
                    |> Expect.equal (stated ResourceExhausted "Service Unavailable" GrpcHeaders)
        , test "otherwise an HttpStatus error, its code inferred by Connect's table" <|
            \_ ->
                [ failed 404 "Not Found" [] "<html>", failed 400 "" [] "{\"error\":\"x\"}", failed 500 "" [ ( "grpc-status", "x" ) ] "" ]
                    |> List.map (Result.mapError (\error -> ( Rpc.Error.code error, Rpc.Error.message error, error )))
                    |> Expect.equal
                        [ Err ( Unimplemented, "Not Found", HttpStatus { blank | statusCode = 404, statusText = "Not Found" } )
                        , Err ( Internal, "HTTP 400", HttpStatus { blank | statusCode = 400 } )
                        , Err ( Unknown, "HTTP 500", HttpStatus { blank | statusCode = 500 } )
                        ]
        , test "a Connect body comes before a status body and the headers" <|
            \_ ->
                failed 404 "" [ ( "grpc-status", "14" ) ] """{"code":"not_found","message":"connect"}"""
                    |> Expect.equal (stated NotFound "connect" ConnectBody)
        , test "a status body comes before the headers" <|
            \_ ->
                failed 404 "" [ ( "grpc-status", "14" ) ] """{"code":5,"message":"status"}"""
                    |> Expect.equal (stated NotFound "status" StatusBody)
        , test "the headers come before an HttpStatus error" <|
            \_ ->
                failed 404 "Not Found" [ ( "grpc-status", "14" ) ] "<html>"
                    |> Expect.equal (stated Unavailable "Not Found" GrpcHeaders)
        , test "Connect reads a status body and the headers too" <|
            \_ ->
                [ """{"code":5}""", "" ]
                    |> List.map
                        (\answer ->
                            Rpc.response (Rpc.config "https://api.example.com")
                                (Rpc.call (raw []) Json.Encode.null)
                                (Http.BadStatus_ (metadata 503 "" [ ( "grpc-status", "14" ) ]) answer)
                                |> withoutResponse
                        )
                    |> Expect.equal [ stated NotFound "" StatusBody, stated Unavailable "HTTP 503" GrpcHeaders ]
        ]
