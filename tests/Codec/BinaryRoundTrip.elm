module Codec.BinaryRoundTrip exposing (Codec, binaryOnly, both, suite)

{-| Running the generated binary codecs of `conformance/codec/codec.proto` on
the protobuf binary of each sample, written by
`crates/elm-connect-gen/tests/codec.rs`, which checks that prost-reflect
reads those bytes back as the sample. `Codec.BinaryRoundTripTest` runs them.

For each sample:

  - the binary decodes, and re-encodes as the same bytes, so prost-reflect
    reads what the encoder writes;
  - with unknown fields of every wire type appended, it decodes and
    re-encodes as the same bytes, the unknown fields dropped;
  - where the set has JSON codecs too, the value read from binary writes the
    JSON the value read from the canonical JSON writes (an `Any` aside: one
    read from binary holds its packed message's binary);
  - and the value read from the canonical JSON encodes as the same bytes,
    but where it holds an `Any`, whose JSON the binary encoder cannot write
    as binary.

-}

import Bytes exposing (Bytes)
import Bytes.Decode
import Bytes.Encode
import Codec.RoundTrip exposing (Sample)
import Dict
import Expect exposing (Expectation)
import Json.Decode
import Json.Encode
import Proto.Binary
import Test exposing (Test, describe, test)


{-| A message's generated binary codecs, and its JSON codecs when the set
has them.
-}
type alias Codec =
    { fromBinary : Bytes -> Maybe { reencoded : Bytes, json : Maybe Json.Encode.Value }
    , fromJson : Maybe (String -> Result String Bytes)
    }


both : Proto.Binary.Decoder a -> (a -> Bytes.Encode.Encoder) -> Json.Decode.Decoder a -> (a -> Json.Encode.Value) -> Codec
both decodeBytes encodeBytes decodeJson encodeJson =
    { fromBinary =
        \input ->
            Proto.Binary.decode decodeBytes input
                |> Maybe.map (\v -> { reencoded = Proto.Binary.encode encodeBytes v, json = Just (encodeJson v) })
    , fromJson =
        Just
            (\text ->
                Json.Decode.decodeString decodeJson text
                    |> Result.mapError Json.Decode.errorToString
                    |> Result.map (Proto.Binary.encode encodeBytes)
            )
    }


binaryOnly : Proto.Binary.Decoder a -> (a -> Bytes.Encode.Encoder) -> Codec
binaryOnly decodeBytes encodeBytes =
    { fromBinary =
        \input ->
            Proto.Binary.decode decodeBytes input
                |> Maybe.map (\v -> { reencoded = Proto.Binary.encode encodeBytes v, json = Nothing })
    , fromJson = Nothing
    }


{-| Fields no message of `codec.proto` declares, one of each wire type: a
varint at the largest field number, then a length-delimited, a fixed64 and
a fixed32 field.
-}
unknownFields : String
unknownFields =
    "f8ffffff0f01" ++ "c23e03616263" ++ "c93e0102030405060708" ++ "d53e01020304"


suite : String -> List ( String, Codec ) -> List Sample -> Test
suite name codecs samples =
    let
        table =
            Dict.fromList codecs
    in
    describe name
        (List.map
            (\sample ->
                case Dict.get sample.message table of
                    Nothing ->
                        test sample.name (\_ -> Expect.fail ("no codec for " ++ sample.message))

                    Just codec ->
                        describe sample.name (sampleTests codec sample)
            )
            samples
        )


sampleTests : Codec -> Sample -> List Test
sampleTests codec sample =
    [ test "binary re-encodes as itself" <|
        \_ -> reencodes codec sample.binary sample.binary
    , test "binary with unknown fields re-encodes without them" <|
        \_ -> reencodes codec (sample.binary ++ unknownFields) sample.binary
    ]
        ++ (case codec.fromJson of
                Nothing ->
                    []

                Just fromJson ->
                    [ test "binary reads as the canonical JSON does" <|
                        \_ ->
                            case codec.fromBinary (fromHex sample.binary) |> Maybe.andThen .json of
                                Nothing ->
                                    Expect.fail "does not decode"

                                Just json ->
                                    Codec.RoundTrip.roundTrip (\_ -> Ok json)
                                        ""
                                        (sample.binaryJson
                                            |> orElse sample.expected
                                            |> Maybe.withDefault sample.canonical
                                        )
                    , test "the canonical JSON encodes as the binary" <|
                        \_ ->
                            case sample.binaryJson of
                                Just _ ->
                                    -- It holds an Any, which the binary
                                    -- encoder writes with its type URL alone.
                                    Expect.pass

                                Nothing ->
                                    fromJson sample.canonical
                                        |> Result.map toHex
                                        |> Expect.equal (Ok sample.binary)
                    ]
           )


reencodes : Codec -> String -> String -> Expectation
reencodes codec input expected =
    case codec.fromBinary (fromHex input) of
        Nothing ->
            Expect.fail ("does not decode: " ++ input)

        Just result ->
            toHex result.reencoded |> Expect.equal expected


orElse : Maybe a -> Maybe a -> Maybe a
orElse fallback maybe =
    case maybe of
        Just _ ->
            maybe

        Nothing ->
            fallback



-- HEX


toHex : Bytes -> String
toHex input =
    Bytes.Decode.decode
        (Bytes.Decode.loop ( Bytes.width input, [] )
            (\( n, acc ) ->
                if n == 0 then
                    Bytes.Decode.succeed (Bytes.Decode.Done (String.concat (List.reverse acc)))

                else
                    Bytes.Decode.map (\b -> Bytes.Decode.Loop ( n - 1, hexByte b :: acc )) Bytes.Decode.unsignedInt8
            )
        )
        input
        |> Maybe.withDefault "?"


hexByte : Int -> String
hexByte b =
    String.fromList [ hexDigit (b // 16), hexDigit (modBy 16 b) ]


hexDigit : Int -> Char
hexDigit n =
    if n < 10 then
        Char.fromCode (48 + n)

    else
        Char.fromCode (87 + n)


fromHex : String -> Bytes
fromHex text =
    let
        value c =
            let
                code =
                    Char.toCode c
            in
            if code >= 97 then
                code - 87

            else
                code - 48

        go chars acc =
            case chars of
                hi :: lo :: rest ->
                    go rest (Bytes.Encode.unsignedInt8 (value hi * 16 + value lo) :: acc)

                _ ->
                    List.reverse acc
    in
    Bytes.Encode.encode (Bytes.Encode.sequence (go (String.toList text) []))
