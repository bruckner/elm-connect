module Rpc.CodecTest exposing (suite)

import Bytes exposing (Bytes)
import Bytes.Decode
import Bytes.Encode
import Dict
import Expect
import Http
import Json.Decode
import Json.Encode
import Proto.Binary
import Proto.Bytes
import Proto.Method exposing (Idempotency(..))
import Proto.Registry
import Rpc
import Rpc.Body
import Rpc.Call
import Rpc.Client
import Rpc.Code exposing (Code(..))
import Rpc.Error exposing (Error(..), Reason(..), Source(..))
import Rpc.Internal.Plan
import Rpc.Internal.Trace
import Rpc.Protocol
import Rpc.Trace
import Test exposing (Test, describe, test)


type alias GetNote =
    { name : String }


encodeGetNote : GetNote -> Json.Encode.Value
encodeGetNote r =
    Json.Encode.object [ ( "name", Json.Encode.string r.name ) ]


encodeGetNoteBytes : GetNote -> Bytes.Encode.Encoder
encodeGetNoteBytes r =
    Bytes.Encode.sequence [ Proto.Binary.implicit Proto.Binary.string 1 r.name ]


decodeTitle : Json.Decode.Decoder String
decodeTitle =
    Json.Decode.field "title" Json.Decode.string


decodeTitleBytes : Proto.Binary.Decoder String
decodeTitleBytes =
    Proto.Binary.merge
        (\number wire value ->
            case number of
                1 ->
                    Proto.Binary.field Proto.Binary.string identity wire value

                _ ->
                    Proto.Binary.skip wire value
        )
        identity
        ""


getNoteIn : Proto.Method.Method codec GetNote String -> Proto.Method.Method codec GetNote String
getNoteIn =
    Proto.Method.withIdempotency IdempotencyNoSideEffects


{-| A method with JSON codecs, and one with binary codecs.
-}
jsonOnly : GetNote -> Rpc.Call Rpc.Json GetNote String
jsonOnly =
    Rpc.call (getNoteIn (Proto.Method.initJson "notes.v1.Notes" "GetNote" (\_ -> encodeGetNote >> Ok) (\_ -> decodeTitle)))


binaryOnly : GetNote -> Rpc.Call Rpc.Proto GetNote String
binaryOnly =
    Rpc.call (getNoteIn (Proto.Method.initProto "notes.v1.Notes" "GetNote" encodeGetNoteBytes decodeTitleBytes))


base : Rpc.Client Rpc.Json
base =
    over Rpc.Protocol.connect


over : Rpc.Protocol.Protocol codec -> Rpc.Client codec
over protocol =
    Rpc.client protocol "https://api.example.com"


proto : Rpc.Client Rpc.Proto
proto =
    over Rpc.Protocol.connectProto


protoGet : Rpc.Client Rpc.Proto
protoGet =
    over (Rpc.Protocol.withConnectGet Rpc.Protocol.connectProto)


bytesOf : List Int -> Bytes
bytesOf =
    List.map Bytes.Encode.unsignedInt8 >> Bytes.Encode.sequence >> Bytes.Encode.encode


{-| A note whose title is "hi", in protobuf binary.
-}
titleHi : Bytes
titleHi =
    bytesOf [ 0x0A, 0x02, 0x68, 0x69 ]


metadata : Int -> List ( String, String ) -> Http.Metadata
metadata status headers =
    { url = "https://api.example.com/notes.v1.Notes/GetNote"
    , statusCode = status
    , statusText = ""
    , headers = Dict.fromList headers
    }


utf8 : String -> Bytes
utf8 =
    Bytes.Encode.string >> Bytes.Encode.encode


codeAndMessage : Result Error a -> Result ( Code, String ) a
codeAndMessage =
    Result.mapError (\error -> ( Rpc.Error.code error, Rpc.Error.message error ))


statusOf : Result Error a -> Maybe ( Code, String, Source )
statusOf result =
    case result of
        Err (RpcStatus status _) ->
            Just ( status.code, status.message, status.source )

        _ ->
            Nothing


{-| An `HttpStatus` error's code, HTTP status and body text.
-}
httpStatusOf : Result Error a -> Maybe ( Code, Int, Maybe String )
httpStatusOf result =
    case result of
        Err ((HttpStatus response) as error) ->
            Just ( Rpc.Error.code error, response.statusCode, Rpc.Body.toText response.body )

        _ ->
            Nothing


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
        [ test "Proto POSTs the request's binary, no text" <|
            \_ ->
                Rpc.request proto (binaryOnly { name = "x" })
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
        , test "Proto's GET carries the binary as unpadded URL-safe base64" <|
            \_ ->
                [ "x", "?>" ]
                    |> List.map (\name -> Rpc.request protoGet (binaryOnly { name = name }) |> (\r -> ( r.method, r.url, Rpc.Body.toBytes r.body == Nothing )))
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
        ]


methods : Test
methods =
    describe "a method's codecs"
        [ test "a binary-only call over Connect proto sends the method's binary and reads the answer by responseBytes" <|
            \_ ->
                ( Rpc.request proto (binaryOnly { name = "x" })
                    |> (\r -> ( r.method, Rpc.Body.contentType r.body, Maybe.map Proto.Bytes.toBase64 (Rpc.Body.toBytes r.body) ))
                , Rpc.responseBytes proto (binaryOnly { name = "x" }) (Http.GoodStatus_ (metadata 200 [ ( "content-type", "application/proto" ) ]) titleHi)
                )
                    |> Expect.equal
                        ( ( "POST", Just "application/proto", Just (Proto.Bytes.toBase64 (Bytes.Encode.encode (encodeGetNoteBytes { name = "x" }))) )
                        , Ok "hi"
                        )
        , test "a binary-only method without side effects is a GET under withConnectGet" <|
            \_ ->
                Rpc.request protoGet (binaryOnly { name = "x" })
                    |> (\r -> ( r.method, r.url ))
                    |> Expect.equal ( "GET", "https://api.example.com/notes.v1.Notes/GetNote?connect=v1&base64=1&encoding=proto&message=CgF4" )
        ]


answers : Test
answers =
    let
        readBytes client answer =
            Rpc.responseBytes client (binaryOnly { name = "x" }) answer

        readText answer =
            Rpc.response base (jsonOnly { name = "x" }) answer
    in
    describe "answers"
        [ test "a 200 of application/proto, or of no content type, decodes as binary" <|
            \_ ->
                [ readBytes proto (Http.GoodStatus_ (metadata 200 [ ( "Content-Type", "application/proto" ) ]) titleHi)
                , readBytes proto (Http.GoodStatus_ (metadata 200 [ ( "content-type", "Application/Proto; charset=x" ) ]) titleHi)
                , readBytes proto (Http.GoodStatus_ (metadata 200 []) titleHi)
                ]
                    |> Expect.equal [ Ok "hi", Ok "hi", Ok "hi" ]
        , test "a 200 of another Connect codec's content type is a BadResponse keeping the bytes" <|
            \_ ->
                readBytes proto (Http.GoodStatus_ (metadata 200 [ ( "content-type", "application/json" ) ]) (utf8 "{\"title\":\"hi\"}"))
                    |> Result.mapError
                        (\error ->
                            case error of
                                BadResponse _ problem answer ->
                                    ( problem, Maybe.map Bytes.width (Rpc.Body.toBytes answer.body) )

                                _ ->
                                    ( "other", Nothing )
                        )
                    |> Expect.equal (Err ( "content-type application/json, not application/proto", Just 14 ))
        , test "a 200 of another Connect content type is a BadResponse naming both, under either codec" <|
            \_ ->
                [ readText (Http.GoodStatus_ (metadata 200 [ ( "content-type", "application/proto" ) ]) "{\"title\":\"hi\"}")
                , readText (Http.GoodStatus_ (metadata 200 [ ( "content-type", "Application/Connect+JSON; charset=utf-8" ) ]) "{\"title\":\"hi\"}")
                , readBytes proto (Http.GoodStatus_ (metadata 200 [ ( "content-type", "application/connect+proto" ) ]) titleHi)
                ]
                    |> List.map codeAndMessage
                    |> Expect.equal
                        [ Err ( Internal, "bad response body: content-type application/proto, not application/json" )
                        , Err ( Internal, "bad response body: content-type application/connect+json, not application/json" )
                        , Err ( Internal, "bad response body: content-type application/connect+proto, not application/proto" )
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
                , readBytes proto (Http.GoodStatus_ jpeg (utf8 errorBody))
                ]
                    |> List.map statusOf
                    |> Expect.equal [ Just ( Unavailable, "down", ConnectBody ), Just ( Unavailable, "down", ConnectBody ) ]
        , test "a 200 that is not Connect's holding no status is an HttpStatus error, code Unknown" <|
            \_ ->
                let
                    html =
                        "<html><body>Sign in</body></html>"
                in
                [ readText (Http.GoodStatus_ (metadata 200 [ ( "content-type", "image/jpeg" ) ]) "")
                , readText (Http.GoodStatus_ (metadata 200 [ ( "content-type", "text/html; charset=utf-8" ) ]) html)
                , readBytes proto (Http.GoodStatus_ (metadata 200 [ ( "content-type", "image/jpeg" ) ]) (utf8 ""))
                , readBytes proto (Http.GoodStatus_ (metadata 200 [ ( "content-type", "text/html" ) ]) (utf8 html))
                ]
                    |> List.map httpStatusOf
                    |> Expect.equal
                        [ Just ( Unknown, 200, Just "" )
                        , Just ( Unknown, 200, Just html )
                        , Just ( Unknown, 200, Just "" )
                        , Just ( Unknown, 200, Just html )
                        ]
        , test "bytes that are not the message are a BadResponse" <|
            \_ ->
                readBytes proto (Http.GoodStatus_ (metadata 200 []) (bytesOf [ 0x0A, 0x05, 0x68 ]))
                    |> codeAndMessage
                    |> Expect.equal (Err ( Internal, "bad response body: the body is not the response of notes.v1.Notes/GetNote in protobuf binary" ))
        , test "an error answer is JSON whatever the codec, its body kept as text" <|
            \_ ->
                readBytes proto (Http.BadStatus_ (metadata 404 [ ( "content-type", "application/json" ) ]) (utf8 "{\"code\":\"not_found\",\"message\":\"no note\"}"))
                    |> Result.mapError
                        (\error ->
                            case error of
                                RpcStatus status answer ->
                                    ( ( status.code, status.message, status.source ), Rpc.Body.toText answer.body )

                                _ ->
                                    ( ( Unknown, "other", ConnectBody ), Nothing )
                        )
                    |> Expect.equal (Err ( ( NotFound, "no note", ConnectBody ), Just "{\"code\":\"not_found\",\"message\":\"no note\"}" ))
        ]


limits : Test
limits =
    describe "size limits count the binary's bytes"
        [ test "read: a body at the limit is read, one byte over is refused" <|
            \_ ->
                [ 4, 3 ]
                    |> List.map
                        (\limit ->
                            Rpc.responseBytes (over (Rpc.Protocol.withReadMaxBytes limit Rpc.Protocol.connectProto)) (binaryOnly { name = "x" }) (Http.GoodStatus_ (metadata 200 []) titleHi)
                        )
                    |> Expect.equal [ Ok "hi", Err (NoAnswer (ResponseTooLarge { limit = 3, size = 4 })) ]
        , test "write: the binary is measured, not the JSON" <|
            \_ ->
                [ 3, 2 ]
                    |> List.map (\limit -> (Rpc.Internal.Plan.plan (over (Rpc.Protocol.withWriteMaxBytes limit Rpc.Protocol.connectProto)) (binaryOnly { name = "x" })).tooLarge ())
                    |> Expect.equal [ Nothing, Just (RequestTooLarge { limit = 2, size = 3 }) ]
        , test "write: a JSON protocol measures the JSON of the same call" <|
            \_ ->
                [ 12, 11 ]
                    |> List.map (\limit -> (Rpc.Internal.Plan.plan (over (Rpc.Protocol.withWriteMaxBytes limit Rpc.Protocol.connect)) (jsonOnly { name = "x" })).tooLarge ())
                    |> Expect.equal [ Nothing, Just (RequestTooLarge { limit = 11, size = 12 }) ]
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
        , test "a Proto request's body is application/proto, a JSON one's application/json" <|
            \_ ->
                [ Rpc.request proto (binaryOnly { name = "x" }), Rpc.request base (jsonOnly { name = "x" }) ]
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
        traced : Rpc.Client codec -> Rpc.Call codec GetNote String -> Result Json.Decode.Error ( Maybe String, Maybe String )
        traced client call =
            let
                plan =
                    Rpc.Internal.Plan.plan client call
            in
            Rpc.Internal.Trace.init (Rpc.Client.protocol client) call plan (plan.request ()) { attempts = 1, metadata = Nothing, result = Ok "hi" } 1
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
                traced proto (binaryOnly { name = "x" })
                    |> Expect.equal (Ok ( Nothing, Just "CgF4" ))
        , test "a JSON request body has no bodyBase64" <|
            \_ ->
                traced base (jsonOnly { name = "x" })
                    |> Expect.equal (Ok ( Just "{\"name\":\"x\"}", Nothing ))
        ]
