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
import Rpc.Code exposing (Code(..))
import Rpc.Error exposing (Error(..), Reason(..), Source(..))
import Rpc.Internal.Wire
import Rpc.Transport exposing (Codec(..))
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


decodeTitleBytes : Int -> Bytes.Decode.Decoder String
decodeTitleBytes =
    Proto.Binary.message ""
        (\number wire value ->
            case number of
                1 ->
                    Proto.Binary.field Proto.Binary.string identity wire

                _ ->
                    Proto.Binary.skip wire value
        )
        identity


descriptor : String -> Idempotency -> Proto.Method.Descriptor
descriptor name idempotency =
    Proto.Method.descriptor "notes.v1.Notes" name idempotency "notes.v1.GetNoteRequest" "notes.v1.Note" []


{-| A method with both codecs, with JSON alone, and with binary alone.
-}
both : GetNote -> Rpc.Call GetNote String
both =
    Rpc.call
        (Proto.Method.method encodeGetNote decodeTitle (descriptor "GetNote" IdempotencyNoSideEffects)
            |> Proto.Method.withBinary encodeGetNoteBytes decodeTitleBytes
        )


jsonOnly : GetNote -> Rpc.Call GetNote String
jsonOnly =
    Rpc.call (Proto.Method.method encodeGetNote decodeTitle (descriptor "GetNote" IdempotencyNoSideEffects))


binaryOnly : GetNote -> Rpc.Call GetNote String
binaryOnly =
    Rpc.call (Proto.Method.methodBinary encodeGetNoteBytes decodeTitleBytes (descriptor "GetNote" IdempotencyNoSideEffects))


base : Rpc.Config
base =
    Rpc.config "https://api.example.com"


over : Rpc.Transport.Transport -> Rpc.Config
over transport =
    { base | transport = transport }


proto : Rpc.Config
proto =
    over (Rpc.Transport.withCodec Proto Rpc.Transport.connect)


protoGet : Rpc.Config
protoGet =
    over (Rpc.Transport.withCodec Proto Rpc.Transport.connectGet)


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
    describe "Rpc.Transport.withCodec"
        [ requests
        , refusals
        , answers
        , limits
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
        , test "Json is the default and undoes Proto" <|
            \_ ->
                ( List.map Rpc.Transport.codec [ Rpc.Transport.connect, Rpc.Transport.connectGet, Rpc.Transport.transcode ]
                , Rpc.Transport.withCodec Json (Rpc.Transport.withCodec Proto Rpc.Transport.connect) == Rpc.Transport.connect
                , Rpc.Transport.codec proto.transport
                )
                    |> Expect.equal ( [ Json, Json, Json ], True, Proto )
        , test "transcoding ignores the codec and stays JSON" <|
            \_ ->
                ( Rpc.Transport.withCodec Proto Rpc.Transport.transcode == Rpc.Transport.transcode
                , Rpc.request (over (Rpc.Transport.withCodec Proto Rpc.Transport.transcode)) (both { name = "x" }) |> .body |> Rpc.Body.toText
                )
                    |> Expect.equal ( True, Just "{\"name\":\"x\"}" )
        , test "a JSON call under a JSON transport is unchanged by the binary codecs" <|
            \_ ->
                Rpc.request base (both { name = "x" })
                    |> .body
                    |> Rpc.Body.toText
                    |> Expect.equal (Just "{\"name\":\"x\"}")
        ]


refusals : Test
refusals =
    let
        missing cfg call =
            Rpc.Internal.Wire.missingCodec cfg (call { name = "x" })
    in
    describe "a method without the codec is refused unsent"
        [ test "a JSON-only method under Proto" <|
            \_ ->
                ( missing proto jsonOnly, missing protoGet jsonOnly )
                    |> Expect.equal
                        ( Just (MissingCodec { method = "notes.v1.Notes/GetNote", codec = "proto" })
                        , Just (MissingCodec { method = "notes.v1.Notes/GetNote", codec = "proto" })
                        )
        , test "a binary-only method under JSON, over Connect or transcoding" <|
            \_ ->
                [ missing base binaryOnly, missing (over Rpc.Transport.transcode) binaryOnly, missing proto binaryOnly ]
                    |> Expect.equal
                        [ Just (MissingCodec { method = "notes.v1.Notes/GetNote", codec = "json" })
                        , Just (MissingCodec { method = "notes.v1.Notes/GetNote", codec = "json" })
                        , Nothing
                        ]
        , test "a method with both codecs goes either way" <|
            \_ ->
                [ missing base both, missing proto both, missing (over Rpc.Transport.transcode) both ]
                    |> Expect.equal [ Nothing, Nothing, Nothing ]
        , test "the error is Internal and names the method and codec" <|
            \_ ->
                Err (NoAnswer (MissingCodec { method = "notes.v1.Notes/GetNote", codec = "proto" }))
                    |> codeAndMessage
                    |> Expect.equal (Err ( Internal, "notes.v1.Notes/GetNote has no proto codec" ))
        ]


answers : Test
answers =
    let
        readBytes cfg answer =
            Rpc.responseBytes cfg (both { name = "x" }) answer
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
                    |> Expect.equal (Err ( Internal, "bad response body: the body is not a notes.v1.Note in protobuf binary" ))
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
        , test "under JSON, bytes are read as the answer's text" <|
            \_ ->
                readBytes base (Http.GoodStatus_ (metadata 200 []) (utf8 "{\"title\":\"é\"}"))
                    |> Expect.equal (Ok "é")
        , test "a binary answer read as text is a BadResponse; an error still reads" <|
            \_ ->
                [ Rpc.response proto (both { name = "x" }) (Http.GoodStatus_ (metadata 200 []) "\nhi") |> codeAndMessage
                , Rpc.response proto (both { name = "x" }) (Http.BadStatus_ (metadata 404 []) "{\"code\":\"not_found\"}") |> codeAndMessage
                ]
                    |> Expect.equal
                        [ Err ( Internal, "bad response body: a protobuf binary answer is read as bytes (Rpc.responseBytes)" )
                        , Err ( NotFound, "" )
                        ]
        ]


limits : Test
limits =
    describe "size limits count the binary's bytes"
        [ test "read: a body at the limit is read, one byte over is refused" <|
            \_ ->
                [ 4, 3 ]
                    |> List.map
                        (\limit ->
                            Rpc.responseBytes (over (Rpc.Transport.withReadMaxBytes limit proto.transport)) (both { name = "x" }) (Http.GoodStatus_ (metadata 200 []) titleHi)
                        )
                    |> Expect.equal [ Ok "hi", Err (NoAnswer (ResponseTooLarge { limit = 3, size = 4 })) ]
        , test "write: the binary is measured, not the JSON" <|
            \_ ->
                [ 3, 2 ]
                    |> List.map (\limit -> Rpc.Internal.Wire.requestTooLarge (over (Rpc.Transport.withWriteMaxBytes limit proto.transport)) (both { name = "x" }))
                    |> Expect.equal [ Nothing, Just (RequestTooLarge { limit = 2, size = 3 }) ]
        ]
