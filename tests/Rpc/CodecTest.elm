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
import Rpc
import Rpc.Body
import Rpc.Call
import Rpc.Client
import Rpc.Code exposing (Code(..))
import Rpc.Error exposing (Error(..), Reason(..), Source(..))
import Rpc.Internal.Send
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


{-| A method with both codecs, with JSON alone, and with binary alone.
-}
both : GetNote -> Rpc.Call codec GetNote String
both =
    Rpc.call (getNoteIn (Proto.Method.both "notes.v1.Notes" "GetNote" encodeGetNote decodeTitle encodeGetNoteBytes decodeTitleBytes))


jsonOnly : GetNote -> Rpc.Call Rpc.Json GetNote String
jsonOnly =
    Rpc.call (getNoteIn (Proto.Method.json "notes.v1.Notes" "GetNote" encodeGetNote decodeTitle))


binaryOnly : GetNote -> Rpc.Call Rpc.Proto GetNote String
binaryOnly =
    Rpc.call (getNoteIn (Proto.Method.proto "notes.v1.Notes" "GetNote" encodeGetNoteBytes decodeTitleBytes))


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
                Rpc.request proto (both { name = "x" })
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
                    |> List.map (\name -> Rpc.request protoGet (both { name = name }) |> (\r -> ( r.method, r.url, Rpc.Body.toBytes r.body == Nothing )))
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
                ( Rpc.request base (both { name = "x" })
                , Rpc.request (over Rpc.Protocol.transcode) (both { name = "x" })
                )
                    |> Expect.equal
                        ( Rpc.request base (jsonOnly { name = "x" })
                        , Rpc.request (over Rpc.Protocol.transcode) (jsonOnly { name = "x" })
                        )
        , test "a Proto call is unchanged by the JSON codecs" <|
            \_ ->
                ( Rpc.request proto (both { name = "x" }), Rpc.request protoGet (both { name = "x" }) )
                    |> Expect.equal ( Rpc.request proto (binaryOnly { name = "x" }), Rpc.request protoGet (binaryOnly { name = "x" }) )
        ]


methods : Test
methods =
    describe "a method's codecs"
        [ test "hasJson is whether the method was built with JSON codecs" <|
            \_ ->
                [ Proto.Method.hasJson (Rpc.Call.method (jsonOnly { name = "x" }))
                , Proto.Method.hasJson (Rpc.Call.method (binaryOnly { name = "x" }))
                , Proto.Method.hasJson (Rpc.Call.method (both { name = "x" }))
                ]
                    |> Expect.equal [ True, False, True ]
        , test "requestJson is null for a method with binary codecs alone" <|
            \_ ->
                [ Rpc.Call.requestJson (binaryOnly { name = "x" })
                , Rpc.Call.requestJson (both { name = "x" })
                , Rpc.Call.requestJson (jsonOnly { name = "x" })
                ]
                    |> List.map (Json.Encode.encode 0)
                    |> Expect.equal [ "null", "{\"name\":\"x\"}", "{\"name\":\"x\"}" ]
        , test "toJson of a binary-only call holds a null request and still names the method" <|
            \_ ->
                Json.Encode.encode 0 (Rpc.Call.toJson (binaryOnly { name = "x" }))
                    |> Expect.equal "{\"service\":\"notes.v1.Notes\",\"method\":\"GetNote\",\"procedure\":\"/notes.v1.Notes/GetNote\",\"request\":null}"
        , test "a binary-only call over Connect proto sends the method's binary and reads the answer by responseBytes" <|
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
            Rpc.responseBytes client (both { name = "x" }) answer
    in
    describe "answers"
        [ test "a 200 of application/proto, or of no content type, decodes as binary" <|
            \_ ->
                [ readBytes proto (Http.GoodStatus_ (metadata 200 [ ( "Content-Type", "application/proto" ) ]) titleHi)
                , readBytes proto (Http.GoodStatus_ (metadata 200 [ ( "content-type", "Application/Proto; charset=x" ) ]) titleHi)
                , readBytes proto (Http.GoodStatus_ (metadata 200 []) titleHi)
                ]
                    |> Expect.equal [ Ok "hi", Ok "hi", Ok "hi" ]
        , test "a 200 of another content type is a BadResponse keeping the bytes" <|
            \_ ->
                readBytes proto (Http.GoodStatus_ (metadata 200 [ ( "content-type", "application/json" ) ]) (utf8 "{\"title\":\"hi\"}"))
                    |> Result.mapError
                        (\error ->
                            case error of
                                BadResponse problem answer ->
                                    ( problem, Maybe.map Bytes.width (Rpc.Body.toBytes answer.body) )

                                _ ->
                                    ( "other", Nothing )
                        )
                    |> Expect.equal (Err ( "content-type application/json, not application/proto", Just 14 ))
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
                            Rpc.responseBytes (over (Rpc.Protocol.withReadMaxBytes limit Rpc.Protocol.connectProto)) (both { name = "x" }) (Http.GoodStatus_ (metadata 200 []) titleHi)
                        )
                    |> Expect.equal [ Ok "hi", Err (NoAnswer (ResponseTooLarge { limit = 3, size = 4 })) ]
        , test "write: the binary is measured, not the JSON" <|
            \_ ->
                [ 3, 2 ]
                    |> List.map (\limit -> (Rpc.Internal.Send.plan (over (Rpc.Protocol.withWriteMaxBytes limit Rpc.Protocol.connectProto)) (both { name = "x" })).tooLarge ())
                    |> Expect.equal [ Nothing, Just (RequestTooLarge { limit = 2, size = 3 }) ]
        , test "write: a JSON protocol measures the JSON of the same call" <|
            \_ ->
                [ 12, 11 ]
                    |> List.map (\limit -> (Rpc.Internal.Send.plan (over (Rpc.Protocol.withWriteMaxBytes limit Rpc.Protocol.connect)) (both { name = "x" })).tooLarge ())
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
                [ Rpc.request proto (both { name = "x" }), Rpc.request base (both { name = "x" }) ]
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
                    Rpc.Internal.Send.plan client (both { name = "x" })
            in
            Rpc.Internal.Trace.init (Rpc.Client.protocol client) (both { name = "x" }) plan (plan.request ()) { attempts = 1, metadata = Nothing, result = Ok "hi" } 1
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
                traced proto
                    |> Expect.equal (Ok ( Nothing, Just "CgF4" ))
        , test "a JSON request body has no bodyBase64" <|
            \_ ->
                traced base
                    |> Expect.equal (Ok ( Just "{\"name\":\"x\"}", Nothing ))
        ]
