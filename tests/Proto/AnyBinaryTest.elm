module Proto.AnyBinaryTest exposing (suite)

import Bytes.Decode
import Bytes.Encode
import Expect
import Json.Decode
import Json.Encode
import Proto.Any as Any exposing (Any, Problem(..))
import Proto.Binary
import Proto.Bytes
import Proto.Json
import Proto.Message as Message exposing (Message)
import Proto.Registry as Registry exposing (Registry)
import Test exposing (Test, describe, test)


descriptor : Message.Descriptor
descriptor =
    Message.descriptor "notes.v1.Title" []


jsonOnly : Message String
jsonOnly =
    Message.message (\t -> Json.Encode.object [ ( "title", Json.Encode.string t ) ])
        (Json.Decode.field "title" Json.Decode.string)
        ""
        descriptor


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


withBinary : Message String
withBinary =
    jsonOnly
        |> Message.withBinary (\t -> Bytes.Encode.sequence [ Proto.Binary.implicit Proto.Binary.string 1 t ]) decodeTitleBytes


{-| An `Any` written as binary and read back.
-}
throughBinary : Any -> Maybe Any
throughBinary any =
    Proto.Binary.decode (Proto.Binary.messageDecoder Proto.Binary.any) (Proto.Binary.encode (Proto.Binary.messageEncoder Proto.Binary.any) any)


base64 : Any -> String
base64 any =
    Proto.Bytes.toBase64 (Proto.Binary.encode (Proto.Binary.messageEncoder Proto.Binary.any) any)


{-| An `Any` written as binary with the registry's conversions.
-}
base64With : Registry -> Any -> String
base64With reg any =
    Proto.Bytes.toBase64 (Proto.Binary.encode (Proto.Binary.messageEncoder (Proto.Binary.anyWith reg)) any)


{-| The binary registry generated code under `codec=both` gives a package
of `notes.v1.Title` whose messages hold these well-known types.
-}
registry : Registry
registry =
    Registry.empty
        |> Registry.withBinary "notes.v1.Title" (Message.decoder jsonOnly) (\t -> Bytes.Encode.sequence [ Proto.Binary.implicit Proto.Binary.string 1 t ])
        |> Registry.withBinary "google.protobuf.Timestamp" Proto.Json.timestamp (Proto.Binary.messageEncoder Proto.Binary.timestamp)
        |> Registry.withBinary "google.protobuf.StringValue" Json.Decode.string (Proto.Binary.messageEncoder Proto.Binary.stringValue)
        |> Registry.withBinary "google.protobuf.BoolValue" Json.Decode.bool (Proto.Binary.messageEncoder Proto.Binary.boolValue)
        |> Registry.withBinary "google.protobuf.Any" Proto.Json.any (\any -> Proto.Binary.messageEncoder (Proto.Binary.anyWith registry) any)


word : Maybe (Result Problem a) -> Maybe (Result String a)
word =
    Maybe.map
        (Result.mapError
            (\problem ->
                case problem of
                    Json _ ->
                        "json"

                    BinaryOnly ->
                        "binary only"

                    Binary ->
                        "binary"
            )
        )


suite : Test
suite =
    describe "Proto.Any with binary codecs"
        [ test "a packed message with binary codecs survives a binary round trip" <|
            \_ ->
                Any.pack withBinary "hi"
                    |> throughBinary
                    |> Maybe.andThen (Any.unpack withBinary)
                    |> word
                    |> Expect.equal (Just (Ok "hi"))
        , test "its JSON is as without binary codecs" <|
            \_ ->
                ( Json.Encode.encode 0 (Proto.Json.encodeAny (Any.pack withBinary "hi"))
                , Any.unpack withBinary (Any.pack withBinary "hi") |> word
                )
                    |> Expect.equal ( Json.Encode.encode 0 (Proto.Json.encodeAny (Any.pack jsonOnly "hi")), Just (Ok "hi") )
        , test "binary alone: BinaryOnly without binary codecs, Binary when it does not decode" <|
            \_ ->
                [ Any.pack withBinary "hi" |> throughBinary |> Maybe.andThen (Any.unpack jsonOnly) |> word
                , Proto.Bytes.fromBase64 "CiJ0eXBlLmdvb2dsZWFwaXMuY29tL25vdGVzLnYxLlRpdGxlEgIKBQ=="
                    |> Maybe.andThen (Proto.Binary.decode (Proto.Binary.messageDecoder Proto.Binary.any))
                    |> Maybe.andThen (Any.unpack withBinary)
                    |> word
                ]
                    |> Expect.equal [ Just (Err "binary only"), Just (Err "binary") ]
        , test "a message held as JSON alone is written with its type URL alone" <|
            \_ ->
                Any.pack jsonOnly "hi"
                    |> throughBinary
                    |> Maybe.andThen (Any.unpack withBinary)
                    |> word
                    |> Expect.equal (Just (Ok ""))
        , test "anyWith writes a message held as JSON alone as its binary when the registry has its codecs" <|
            \_ ->
                [ base64With registry (Any.pack jsonOnly "hi")
                , base64With Registry.empty (Any.pack jsonOnly "hi")
                ]
                    |> Expect.equal [ base64 (Any.pack withBinary "hi"), base64 (Any.pack jsonOnly "hi") ]
        , test "a well-known type read from proto3 JSON alone is written with its type URL alone by any" <|
            \_ ->
                """{"@type":"type.googleapis.com/google.protobuf.StringValue","value":"hi"}"""
                    |> Json.Decode.decodeString Proto.Json.any
                    |> Result.toMaybe
                    |> Maybe.map base64
                    |> Expect.equal (Just "Ci90eXBlLmdvb2dsZWFwaXMuY29tL2dvb2dsZS5wcm90b2J1Zi5TdHJpbmdWYWx1ZQ==")
        , test "a well-known type read from proto3 JSON is written as its binary by anyWith its registry" <|
            \_ ->
                [ """{"@type":"type.googleapis.com/google.protobuf.Timestamp","value":"2026-01-02T03:04:05Z"}"""
                , """{"@type":"type.googleapis.com/google.protobuf.StringValue","value":"hi"}"""
                , """{"@type":"type.googleapis.com/google.protobuf.Any","value":{"@type":"type.googleapis.com/google.protobuf.BoolValue","value":true}}"""
                ]
                    |> List.map (Json.Decode.decodeString Proto.Json.any >> Result.toMaybe >> Maybe.map (base64With registry))
                    |> Expect.equal
                        [ Just "Ci10eXBlLmdvb2dsZWFwaXMuY29tL2dvb2dsZS5wcm90b2J1Zi5UaW1lc3RhbXASBgil69zKBg=="
                        , Just "Ci90eXBlLmdvb2dsZWFwaXMuY29tL2dvb2dsZS5wcm90b2J1Zi5TdHJpbmdWYWx1ZRIECgJoaQ=="
                        , Just "Cid0eXBlLmdvb2dsZWFwaXMuY29tL2dvb2dsZS5wcm90b2J1Zi5BbnkSMwotdHlwZS5nb29nbGVhcGlzLmNvbS9nb29nbGUucHJvdG9idWYuQm9vbFZhbHVlEgIIAQ=="
                        ]
        ]
