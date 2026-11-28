module Rpc.CodecTest exposing (suite)

import Answers exposing (heldAnswer, metadata)
import Bytes exposing (Bytes)
import Bytes.Encode
import Dict
import Expect
import Http
import Json.Decode
import Json.Encode
import Notes exposing (base, binaryOnly, both, encodeGetNoteBytes, jsonOnly, over, titleHi)
import Octets exposing (bytesOf)
import Proto.Bytes
import Proto.Error
import Proto.Registry
import Requests exposing (requestOf)
import Rpc
import Rpc.Body
import Rpc.Call
import Rpc.Client
import Rpc.Code exposing (Code(..))
import Rpc.Error exposing (Cause(..), Error, Source(..))
import Rpc.Internal.Plan
import Rpc.Internal.Trace
import Rpc.Protocol
import Rpc.Trace
import Test exposing (Test, describe, test)


binary : Rpc.Client Rpc.Binary
binary =
    over Rpc.Protocol.connectProto


binaryGet : Rpc.Client Rpc.Binary
binaryGet =
    over (Rpc.Protocol.withConnectGet Rpc.Protocol.connectProto)


utf8 : String -> Bytes
utf8 =
    Bytes.Encode.string >> Bytes.Encode.encode


codeAndMessage : Result Error a -> Result ( Code, String ) a
codeAndMessage =
    Result.mapError (\error -> ( Rpc.Error.code error, Rpc.Error.message error ))


statusOf : Result Error a -> Maybe ( Code, String, Maybe Source )
statusOf result =
    case result of
        Err error ->
            Just ( Rpc.Error.code error, Rpc.Error.message error, Rpc.Error.source error )

        Ok _ ->
            Nothing


{-| A server failure's code, HTTP status and body text, when it states no
status.
-}
httpStatusOf : Result Error a -> Maybe ( Code, Maybe Int, Maybe String )
httpStatusOf result =
    case result of
        Err error ->
            case ( Rpc.Error.cause error, Rpc.Error.source error ) of
                ( BadStatus answer, Nothing ) ->
                    Just ( Rpc.Error.code error, Just answer.statusCode, Rpc.Body.toText answer.body )

                ( BadResponse answer, Nothing ) ->
                    Just ( Rpc.Error.code error, Just answer.statusCode, Rpc.Body.toText answer.body )

                _ ->
                    Nothing

        Ok _ ->
            Nothing


{-| The width of the body of the answer an error holds.
-}
bodyWidth : Error -> Maybe Int
bodyWidth error =
    heldAnswer error |> Maybe.andThen (.body >> Rpc.Body.toBytes) |> Maybe.map Bytes.width


suite : Test
suite =
    describe "codecs"
        [ requests
        , methods
        , answers
        , limits
        , bodies
        , traces
        ]


requests : Test
requests =
    describe "requests"
        [ test "Binary POSTs the request's binary, no text" <|
            \_ ->
                requestOf binary (both { name = "x" })
                    |> (\r -> ( ( r.method, r.url, r.headers ), Rpc.Body.toText r.body, Maybe.map Proto.Bytes.toBase64 (Rpc.Body.toBytes r.body) ))
                    |> Expect.equal
                        ( ( "POST", "https://api.example.com/notes.v1.Notes/GetNote", [ ( "Connect-Protocol-Version", "1" ) ] )
                        , Nothing
                        , Just "CgF4"
                        )
        , test "a bytes body reads back as bytes, not text" <|
            \_ ->
                ( Rpc.Body.toText (Rpc.Body.bytes titleHi), Maybe.map Proto.Bytes.toBase64 (Rpc.Body.toBytes (Rpc.Body.bytes titleHi)), Rpc.Body.toBytes (Rpc.Body.text "x") == Nothing )
                    |> Expect.equal ( Nothing, Just "CgJoaQ==", True )
        , test "Binary's GET carries the binary as unpadded URL-safe base64" <|
            \_ ->
                [ "x", "?>" ]
                    |> List.map (\name -> requestOf binaryGet (both { name = name }) |> (\r -> ( r.method, r.url, Rpc.Body.toBytes r.body == Nothing )))
                    |> Expect.equal
                        [ ( "GET", "https://api.example.com/notes.v1.Notes/GetNote?connect=v1&base64=1&encoding=proto&message=CgF4", True )
                        , ( "GET", "https://api.example.com/notes.v1.Notes/GetNote?connect=v1&base64=1&encoding=proto&message=CgI_Pg", True )
                        ]
        , test "each protocol names its codec" <|
            \_ ->
                ( List.map Rpc.Protocol.codec [ Rpc.Protocol.connect, Rpc.Protocol.withConnectGet Rpc.Protocol.connect, Rpc.Protocol.transcode ]
                , List.map Rpc.Protocol.codec [ Rpc.Protocol.connectProto, Rpc.Protocol.withConnectGet Rpc.Protocol.connectProto ]
                , List.map Rpc.Protocol.name [ Rpc.Protocol.connectProto, Rpc.Protocol.withConnectGet Rpc.Protocol.connectProto ]
                )
                    |> Expect.equal ( [ "json", "json", "json" ], [ "proto", "proto" ], [ "connect", "connect" ] )
        , test "a JSON call under a JSON protocol is unchanged by the binary codecs" <|
            \_ ->
                ( requestOf base (both { name = "x" })
                , requestOf (over Rpc.Protocol.transcode) (both { name = "x" })
                )
                    |> Expect.equal
                        ( requestOf base (jsonOnly { name = "x" })
                        , requestOf (over Rpc.Protocol.transcode) (jsonOnly { name = "x" })
                        )
        , test "a Binary call is unchanged by the JSON codecs" <|
            \_ ->
                ( requestOf binary (both { name = "x" }), requestOf binaryGet (both { name = "x" }) )
                    |> Expect.equal ( requestOf binary (binaryOnly { name = "x" }), requestOf binaryGet (binaryOnly { name = "x" }) )
        ]


methods : Test
methods =
    describe "a method's codecs"
        [ test "a call free in the codec reads as a JSON call" <|
            \_ ->
                -- Which halves are real is the codec: `requestJson`, `toJson`
                -- and `viaBinding` take a `Call Rpc.Json`, so a `wire=both`
                -- call is pinned to JSON by them, and a binary-only call
                -- does not compile with them.
                ( Rpc.Call.requestJson Proto.Registry.empty (both { name = "x" })
                    |> Result.map (Json.Encode.encode 0)
                , Rpc.Call.toJson Proto.Registry.empty (both { name = "x" })
                    |> Result.map (Json.Encode.encode 0)
                )
                    |> Expect.equal
                        ( Ok "{\"name\":\"x\"}"
                        , Ok "{\"service\":\"notes.v1.Notes\",\"method\":\"GetNote\",\"procedure\":\"/notes.v1.Notes/GetNote\",\"request\":{\"name\":\"x\"}}"
                        )
        , test "a binary-only call over Connect binary sends the method's binary and reads the answer by responseBytes" <|
            \_ ->
                ( requestOf binary (binaryOnly { name = "x" })
                    |> (\r -> ( r.method, Rpc.Body.contentType r.body, Maybe.map Proto.Bytes.toBase64 (Rpc.Body.toBytes r.body) ))
                , Rpc.responseBytes binary (binaryOnly { name = "x" }) (Http.GoodStatus_ (metadata 200 [ ( "content-type", "application/proto" ) ]) titleHi)
                )
                    |> Expect.equal
                        ( ( "POST", Just "application/proto", Just (Proto.Bytes.toBase64 (Bytes.Encode.encode (encodeGetNoteBytes { name = "x" }))) )
                        , Ok "hi"
                        )
        , test "a binary-only method without side effects is a GET under withConnectGet" <|
            \_ ->
                requestOf binaryGet (binaryOnly { name = "x" })
                    |> (\r -> ( r.method, r.url ))
                    |> Expect.equal ( "GET", "https://api.example.com/notes.v1.Notes/GetNote?connect=v1&base64=1&encoding=proto&message=CgF4" )
        ]


answers : Test
answers =
    let
        readBytes client answer =
            Rpc.responseBytes client (both { name = "x" }) answer

        readText answer =
            Rpc.response base (both { name = "x" }) answer
    in
    describe "answers"
        [ test "a 200 of application/proto, or of no content type, decodes as binary" <|
            \_ ->
                [ readBytes binary (Http.GoodStatus_ (metadata 200 [ ( "Content-Type", "application/proto" ) ]) titleHi)
                , readBytes binary (Http.GoodStatus_ (metadata 200 [ ( "content-type", "Application/Proto; charset=x" ) ]) titleHi)
                , readBytes binary (Http.GoodStatus_ (metadata 200 []) titleHi)
                ]
                    |> Expect.equal [ Ok "hi", Ok "hi", Ok "hi" ]
        , test "a 200 of another Connect codec's content type is a BadResponse keeping the bytes" <|
            \_ ->
                readBytes binary (Http.GoodStatus_ (metadata 200 [ ( "content-type", "application/json" ) ]) (utf8 "{\"title\":\"hi\"}"))
                    -- Elm's == does not look into Bytes, so the body's width is read too.
                    |> Result.mapError (\error -> ( error, Rpc.Error.httpStatus error, bodyWidth error ))
                    |> Expect.equal
                        (Err
                            ( Rpc.Error.badResponse Internal
                                "bad response: content-type application/json, not application/proto"
                                { url = "https://api.example.com/notes.v1.Notes/GetNote"
                                , statusCode = 200
                                , statusText = ""
                                , headers = Dict.fromList [ ( "content-type", "application/json" ) ]
                                , body = Rpc.Body.bytes (utf8 "{\"title\":\"hi\"}")
                                }
                            , Just 200
                            , Just 14
                            )
                        )
        , test "a 200 of another Connect content type is a BadResponse naming both, under either codec" <|
            \_ ->
                [ readText (Http.GoodStatus_ (metadata 200 [ ( "content-type", "application/proto" ) ]) "{\"title\":\"hi\"}")
                , readText (Http.GoodStatus_ (metadata 200 [ ( "content-type", "Application/Connect+JSON; charset=utf-8" ) ]) "{\"title\":\"hi\"}")
                , readBytes binary (Http.GoodStatus_ (metadata 200 [ ( "content-type", "application/connect+proto" ) ]) titleHi)
                ]
                    |> List.map codeAndMessage
                    |> Expect.equal
                        [ Err ( Internal, "bad response: content-type application/proto, not application/json" )
                        , Err ( Internal, "bad response: content-type application/connect+json, not application/json" )
                        , Err ( Internal, "bad response: content-type application/connect+proto, not application/proto" )
                        ]
        , test "a 200 under the JSON codec as application/json, or of no content type, is the answer" <|
            \_ ->
                [ readText (Http.GoodStatus_ (metadata 200 [ ( "Content-Type", "application/json; charset=utf-8" ) ]) "{\"title\":\"hi\"}")
                , readText (Http.GoodStatus_ (metadata 200 []) "{\"title\":\"hi\"}")
                ]
                    |> Expect.equal [ Ok "hi", Ok "hi" ]
        , test "a 200 that is not Connect's holding a Connect error body is that error, under either codec" <|
            \_ ->
                let
                    jpeg =
                        metadata 200 [ ( "content-type", "image/jpeg" ) ]

                    errorBody =
                        "{\"code\":\"unavailable\",\"message\":\"down\"}"
                in
                [ readText (Http.GoodStatus_ jpeg errorBody)
                , readBytes binary (Http.GoodStatus_ jpeg (utf8 errorBody))
                ]
                    |> List.map statusOf
                    |> Expect.equal [ Just ( Unavailable, "down", Just ConnectBody ), Just ( Unavailable, "down", Just ConnectBody ) ]
        , test "a 200 that is not Connect's holding no status states none, code Unknown" <|
            \_ ->
                let
                    html =
                        "<html><body>Sign in</body></html>"
                in
                [ readText (Http.GoodStatus_ (metadata 200 [ ( "content-type", "image/jpeg" ) ]) "")
                , readText (Http.GoodStatus_ (metadata 200 [ ( "content-type", "text/html; charset=utf-8" ) ]) html)
                , readBytes binary (Http.GoodStatus_ (metadata 200 [ ( "content-type", "image/jpeg" ) ]) (utf8 ""))
                , readBytes binary (Http.GoodStatus_ (metadata 200 [ ( "content-type", "text/html" ) ]) (utf8 html))
                ]
                    |> List.map httpStatusOf
                    |> Expect.equal
                        [ Just ( Unknown, Just 200, Just "" )
                        , Just ( Unknown, Just 200, Just html )
                        , Just ( Unknown, Just 200, Just "" )
                        , Just ( Unknown, Just 200, Just html )
                        ]
        , test "bytes that are not the message are a BadResponse" <|
            \_ ->
                readBytes binary (Http.GoodStatus_ (metadata 200 []) (bytesOf [ 0x0A, 0x05, 0x68 ]))
                    |> Result.mapError (\error -> ( Rpc.Error.code error, Rpc.Error.message error, Rpc.Error.protoError error ))
                    |> Expect.equal (Err ( Internal, "bad response body", Just (Proto.Error.BadBinary { typeName = "notes.v1.Title", reason = Proto.Error.Truncated, path = [ ( "notes.v1.Title", 1 ) ], offset = 1 }) ))
        , test "an error answer is JSON whatever the codec, its body kept as text" <|
            \_ ->
                readBytes binary (Http.BadStatus_ (metadata 404 [ ( "content-type", "application/json" ) ]) (utf8 "{\"code\":\"not_found\",\"message\":\"no note\"}"))
                    |> Result.mapError
                        (\error ->
                            ( statusOf (Err error), heldAnswer error |> Maybe.andThen (.body >> Rpc.Body.toText) )
                        )
                    |> Expect.equal (Err ( Just ( NotFound, "no note", Just ConnectBody ), Just "{\"code\":\"not_found\",\"message\":\"no note\"}" ))
        ]


limits : Test
limits =
    describe "size limits count the binary's bytes"
        [ test "read: a body at the limit is read, one byte over is refused" <|
            \_ ->
                [ 4, 3 ]
                    |> List.map
                        (\limit ->
                            Rpc.responseBytes (over (Rpc.Protocol.withReadMaxBytes limit Rpc.Protocol.connectProto)) (both { name = "x" }) (Http.GoodStatus_ (metadata 200 []) titleHi)
                        )
                    |> Expect.equal
                        [ Ok "hi"
                        , Err
                            (Rpc.Error.badResponse ResourceExhausted
                                "message size 4 is larger than configured readMaxBytes 3"
                                { url = "https://api.example.com/notes.v1.Notes/GetNote", statusCode = 200, statusText = "", headers = Dict.empty, body = Rpc.Body.none }
                            )
                        ]
        , test "write: the binary is measured, not the JSON" <|
            \_ ->
                [ 3, 2 ]
                    |> List.map (\limit -> (Rpc.Internal.Plan.plan (over (Rpc.Protocol.withWriteMaxBytes limit Rpc.Protocol.connectProto)) (both { name = "x" })).tooLarge ())
                    |> Expect.equal [ Nothing, Just { limit = 2, size = 3 } ]
        , test "write: a JSON protocol measures the JSON of the same call" <|
            \_ ->
                [ 12, 11 ]
                    |> List.map (\limit -> (Rpc.Internal.Plan.plan (over (Rpc.Protocol.withWriteMaxBytes limit Rpc.Protocol.connect)) (both { name = "x" })).tooLarge ())
                    |> Expect.equal [ Nothing, Just { limit = 11, size = 12 } ]
        ]


bodies : Test
bodies =
    describe "a body's content type"
        [ test "text is JSON, bytes are application/proto unless bytesAs gives another, none is none" <|
            \_ ->
                [ Rpc.Body.text "{}", Rpc.Body.bytes titleHi, Rpc.Body.bytesAs "application/octet-stream" titleHi, Rpc.Body.none ]
                    |> List.map Rpc.Body.contentType
                    |> Expect.equal [ Just "application/json", Just "application/proto", Just "application/octet-stream", Nothing ]
        , test "a body of bytes of another type is still bytes, never text" <|
            \_ ->
                Rpc.Body.bytesAs "application/octet-stream" titleHi
                    |> (\b -> ( Rpc.Body.toText b, Maybe.map Proto.Bytes.toBase64 (Rpc.Body.toBytes b) ))
                    |> Expect.equal ( Nothing, Just "CgJoaQ==" )
        , test "a Binary request's body is application/proto, a JSON one's application/json" <|
            \_ ->
                [ requestOf binary (both { name = "x" }), requestOf base (both { name = "x" }) ]
                    |> List.map (.body >> Rpc.Body.contentType)
                    |> Expect.equal [ Just "application/proto", Just "application/json" ]
        , test "binary protocols built alike compare equal, and differ by their options" <|
            \_ ->
                ( Rpc.Protocol.withConnectGet Rpc.Protocol.connectProto == Rpc.Protocol.withConnectGet Rpc.Protocol.connectProto
                , Rpc.Protocol.withConnectGet Rpc.Protocol.connectProto == Rpc.Protocol.connectProto
                )
                    |> Expect.equal ( True, False )
        ]


traces : Test
traces =
    let
        traced : Rpc.Client codec -> Result Json.Decode.Error ( Maybe String, Maybe String )
        traced client =
            let
                plan =
                    Rpc.Internal.Plan.plan client (both { name = "x" })
            in
            Rpc.Internal.Trace.init (Rpc.Client.protocol client) (both { name = "x" }) plan (Result.withDefault (plan.unwritten ()) (plan.request ())) { attempts = 1, metadata = Nothing, result = Ok "hi" } 1
                |> Rpc.Trace.toJson
                |> Json.Decode.decodeValue
                    (Json.Decode.field "request"
                        (Json.Decode.map2 Tuple.pair
                            (Json.Decode.field "body" (Json.Decode.nullable Json.Decode.string))
                            (Json.Decode.maybe (Json.Decode.field "bodyBase64" Json.Decode.string))
                        )
                    )
    in
    describe "a trace of a call"
        [ test "a binary request body is null as body and base64 as bodyBase64" <|
            \_ ->
                traced binary
                    |> Expect.equal (Ok ( Nothing, Just "CgF4" ))
        , test "a JSON request body has no bodyBase64" <|
            \_ ->
                traced base
                    |> Expect.equal (Ok ( Just "{\"name\":\"x\"}", Nothing ))
        ]
