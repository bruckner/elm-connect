module Rpc.GrpcWebTest exposing (suite)

import Bytes exposing (Bytes, Endianness(..))
import Bytes.Decode
import Bytes.Encode as E
import Dict
import Expect
import Http
import Json.Decode
import Json.Encode
import Proto.Any
import Proto.Binary
import Proto.Bytes
import Proto.Method exposing (Idempotency(..))
import Rpc
import Rpc.Body
import Rpc.Code exposing (Code(..))
import Rpc.Error exposing (Error(..), Reason(..), Source(..))
import Rpc.Internal.Wire
import Rpc.Transport
import Test exposing (Test, describe, test)


type alias GetNote =
    { name : String }


encodeGetNoteBytes : GetNote -> E.Encoder
encodeGetNoteBytes r =
    E.sequence [ Proto.Binary.implicit Proto.Binary.string 1 r.name ]


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


descriptor : Proto.Method.Descriptor
descriptor =
    Proto.Method.descriptor "notes.v1.Notes" "GetNote" IdempotencyNoSideEffects "notes.v1.GetNoteRequest" "notes.v1.Note" []


both : GetNote -> Rpc.Call GetNote String
both =
    Rpc.call
        (Proto.Method.method (\r -> Json.Encode.object [ ( "name", Json.Encode.string r.name ) ]) (Json.Decode.field "title" Json.Decode.string) descriptor
            |> Proto.Method.withBinary encodeGetNoteBytes decodeTitleBytes
        )


jsonOnly : GetNote -> Rpc.Call GetNote String
jsonOnly =
    Rpc.call (Proto.Method.method (\r -> Json.Encode.object [ ( "name", Json.Encode.string r.name ) ]) (Json.Decode.field "title" Json.Decode.string) descriptor)


grpcWeb : Rpc.Config
grpcWeb =
    let
        base =
            Rpc.config "https://api.example.com"
    in
    { base | transport = Rpc.Transport.grpcWeb }


bytesOf : List Int -> Bytes
bytesOf =
    List.map E.unsignedInt8 >> E.sequence >> E.encode


decodeAll : Bytes -> List Int
decodeAll b =
    let
        step ( left, acc ) =
            if left == 0 then
                Bytes.Decode.succeed (Bytes.Decode.Done (List.reverse acc))

            else
                Bytes.Decode.map (\x -> Bytes.Decode.Loop ( left - 1, x :: acc )) Bytes.Decode.unsignedInt8
    in
    Bytes.Decode.decode (Bytes.Decode.loop ( Bytes.width b, [] ) step) b
        |> Maybe.withDefault []


frame : Int -> Bytes -> E.Encoder
frame flag payload =
    E.sequence [ E.unsignedInt8 flag, E.unsignedInt32 BE (Bytes.width payload), E.bytes payload ]


trailers : String -> E.Encoder
trailers text =
    frame 0x80 (E.encode (E.string text))


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


answer : Int -> List ( String, String ) -> List E.Encoder -> Result Error String
answer status headers body =
    Rpc.responseBytes grpcWeb (both { name = "hi" }) (Http.GoodStatus_ (metadata status headers) (E.encode (E.sequence body)))


statusOf : Result Error String -> Maybe ( Code, String, Source )
statusOf result =
    case result of
        Err (RpcStatus status _) ->
            Just ( status.code, status.message, status.source )

        _ ->
            Nothing


{-| A `google.rpc.Status` with code 5, message "gone" and one detail, an
`Any` of type `type.googleapis.com/google.rpc.ErrorInfo` holding `0a 01 78`.
-}
statusWithDetail : Bytes
statusWithDetail =
    let
        url =
            "type.googleapis.com/google.rpc.ErrorInfo"

        any =
            E.encode
                (E.sequence
                    [ E.unsignedInt8 0x0A
                    , E.unsignedInt8 (String.length url)
                    , E.string url
                    , E.unsignedInt8 0x12
                    , E.unsignedInt8 3
                    , E.bytes (bytesOf [ 0x0A, 0x01, 0x78 ])
                    ]
                )
    in
    E.encode
        (E.sequence
            [ E.bytes (bytesOf [ 0x08, 0x05, 0x12, 0x04 ])
            , E.string "gone"
            , E.unsignedInt8 0x1A
            , E.unsignedInt8 (Bytes.width any)
            , E.bytes any
            ]
        )


suite : Test
suite =
    describe "gRPC-Web"
        [ describe "requests"
            [ test "a POST of one framed message, with gRPC-Web's headers" <|
                \_ ->
                    let
                        sent =
                            Rpc.request grpcWeb (both { name = "hi" })
                    in
                    Expect.all
                        [ \r -> r.method |> Expect.equal "POST"
                        , \r -> r.url |> Expect.equal "https://api.example.com/notes.v1.Notes/GetNote"
                        , \r -> r.headers |> Expect.equal [ ( "X-Grpc-Web", "1" ) ]
                        , \r -> Rpc.Body.contentType r.body |> Expect.equal (Just "application/grpc-web+proto")
                        , \r -> Rpc.Body.toBytes r.body |> Maybe.map decodeAll |> Expect.equal (Just [ 0, 0, 0, 0, 4, 0x0A, 0x02, 0x68, 0x69 ])
                        ]
                        sent
            , test "a timeout is grpc-timeout, milliseconds rounded up" <|
                \_ ->
                    Rpc.request { grpcWeb | timeout = Just 1500.2 } (both { name = "" })
                        |> .headers
                        |> List.filter (\( name, _ ) -> name == "grpc-timeout")
                        |> Expect.equal [ ( "grpc-timeout", "1501m" ) ]
            , test "a timeout past eight digits of milliseconds is in seconds" <|
                \_ ->
                    Rpc.request { grpcWeb | timeout = Just 100000000 } (both { name = "" })
                        |> .headers
                        |> List.filter (\( name, _ ) -> name == "grpc-timeout")
                        |> Expect.equal [ ( "grpc-timeout", "100000S" ) ]
            , test "a method without binary codecs is refused unsent" <|
                \_ ->
                    Rpc.Internal.Wire.missingCodec grpcWeb (jsonOnly { name = "" })
                        |> Expect.equal (Just (MissingCodec { method = "notes.v1.Notes/GetNote", codec = "proto" }))
            , test "its codec is Proto, whatever withCodec says" <|
                \_ ->
                    Rpc.Transport.codec (Rpc.Transport.withCodec Rpc.Transport.Json Rpc.Transport.grpcWeb)
                        |> Expect.equal Rpc.Transport.Proto
            , test "its name" <|
                \_ -> Rpc.Transport.name Rpc.Transport.grpcWeb |> Expect.equal "grpc-web"
            ]
        , describe "answers"
            [ test "a message and status 0 in the trailers" <|
                \_ -> answer 200 [ ( "content-type", "application/grpc-web+proto" ) ] [ frame 0 titleHi, trailers "grpc-status: 0\u{000D}\ngrpc-message: \u{000D}\n" ] |> Expect.equal (Ok "hi")
            , test "an error in the trailers, its message percent-decoded" <|
                \_ ->
                    answer 200 [] [ trailers "Grpc-Status: 5\u{000D}\ngrpc-message: no%20such%20note\u{000D}\n" ]
                        |> statusOf
                        |> Expect.equal (Just ( NotFound, "no such note", GrpcTrailers ))
            , test "a trailers-only answer: the status in the headers" <|
                \_ ->
                    answer 200 [ ( "grpc-status", "7" ), ( "grpc-message", "denied" ) ] []
                        |> statusOf
                        |> Expect.equal (Just ( PermissionDenied, "denied", GrpcHeaders ))
            , test "grpc-status-details-bin gives the error's details" <|
                \_ ->
                    case answer 200 [] [ trailers ("grpc-status: 5\u{000D}\ngrpc-message: gone\u{000D}\ngrpc-status-details-bin: " ++ Proto.Bytes.toBase64 statusWithDetail ++ "\u{000D}\n") ] of
                        Err (RpcStatus status _) ->
                            List.map Proto.Any.typeUrl status.details |> Expect.equal [ "type.googleapis.com/google.rpc.ErrorInfo" ]

                        other ->
                            Expect.fail (Debug.toString other)
            , test "status 0 without a message is a BadResponse" <|
                \_ ->
                    case answer 200 [] [ trailers "grpc-status: 0\u{000D}\n" ] of
                        Err (BadResponse _ _) ->
                            Expect.pass

                        other ->
                            Expect.fail (Debug.toString other)
            , test "no grpc-status anywhere is a BadResponse" <|
                \_ ->
                    case answer 200 [] [ frame 0 titleHi ] of
                        Err (BadResponse _ _) ->
                            Expect.pass

                        other ->
                            Expect.fail (Debug.toString other)
            , test "a compressed message is a BadResponse" <|
                \_ ->
                    case answer 200 [] [ frame 1 titleHi, trailers "grpc-status: 0\u{000D}\n" ] of
                        Err (BadResponse _ _) ->
                            Expect.pass

                        other ->
                            Expect.fail (Debug.toString other)
            , test "a message over the read limit is refused" <|
                \_ ->
                    Rpc.responseBytes { grpcWeb | transport = Rpc.Transport.withReadMaxBytes 3 Rpc.Transport.grpcWeb }
                        (both { name = "" })
                        (Http.GoodStatus_ (metadata 200 []) (E.encode (E.sequence [ frame 0 titleHi, trailers "grpc-status: 0\u{000D}\n" ])))
                        |> Expect.equal (Err (NoAnswer (ResponseTooLarge { limit = 3, size = 4 })))
            , test "another HTTP status with grpc-status headers is read from them" <|
                \_ ->
                    Rpc.responseBytes grpcWeb (both { name = "" }) (Http.BadStatus_ (metadata 503 [ ( "grpc-status", "14" ) ]) (E.encode (E.sequence [])))
                        |> statusOf
                        |> Maybe.map (\( code, _, source ) -> ( code, source ))
                        |> Expect.equal (Just ( Unavailable, GrpcHeaders ))
            ]
        ]
