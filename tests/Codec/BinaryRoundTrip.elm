module Codec.BinaryRoundTrip exposing (Codec, binaryOnly, both, suite, suiteKeeping)

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
    read from binary is written as its packed message's canonical JSON);
  - and the value read from the canonical JSON encodes as the same bytes.

An `Any` is read from and written as JSON through the package's registry,
which has the codecs of every message and well-known type a sample packs.

-}

import Bytes exposing (Bytes)
import Bytes.Encode
import Codec.RoundTrip exposing (Sample)
import Dict
import Expect exposing (Expectation)
import Json.Decode
import Json.Encode
import Octets exposing (fromHex, toHex)
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
                |> Result.toMaybe
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
                |> Result.toMaybe
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


{-| [`unknownFields`](#unknownFields) as a message keeping them writes them:
by field number.
-}
unknownFieldsByNumber : String
unknownFieldsByNumber =
    "c23e03616263" ++ "c93e0102030405060708" ++ "d53e01020304" ++ "f8ffffff0f01"


suite : String -> List ( String, Codec ) -> List Sample -> Test
suite =
    suiteWith False


{-| [`suite`](#suite) for codecs generated under `unknown_fields=keep`: the
unknown fields appended are written back, after the known ones and by field
number.
-}
suiteKeeping : String -> List ( String, Codec ) -> List Sample -> Test
suiteKeeping =
    suiteWith True


suiteWith : Bool -> String -> List ( String, Codec ) -> List Sample -> Test
suiteWith keeps name codecs samples =
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
                        describe sample.name (sampleTests keeps codec sample)
            )
            samples
        )


sampleTests : Bool -> Codec -> Sample -> List Test
sampleTests keeps codec sample =
    [ test "binary re-encodes as itself" <|
        \_ -> reencodes codec sample.binary sample.binary
    , if keeps then
        test "binary with unknown fields re-encodes with them, by number" <|
            \_ -> reencodes codec (sample.binary ++ unknownFields) (sample.binary ++ unknownFieldsByNumber)

      else
        test "binary with unknown fields re-encodes without them" <|
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
