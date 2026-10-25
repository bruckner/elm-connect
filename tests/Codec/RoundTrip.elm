module Codec.RoundTrip exposing (Codec, Form, Sample, codec, roundTrip, suite)

{-| Running the generated codecs of `conformance/codec/codec.proto` on JSON
prost-reflect wrote. `Generated.Codec.Data` and `Generated.Codec.DataInt64Int`
hold the samples and `Generated.Codec.Codecs` each option set's codecs, all
written under `tests/Generated/` by `crates/elm-connect-gen/tests/codec.rs`
(`just codec-gen`); `Codec.RoundTripTest` runs them.
-}

import Dict exposing (Dict)
import Expect exposing (Expectation)
import Json.Decode exposing (Decoder)
import Json.Encode
import Test exposing (Test, describe, test)


{-| A sampled message: the full name of its type, its canonical proto3 JSON,
what the generated encoder writes after decoding that when it is not the
same, and the other forms prost-reflect wrote it in; then its protobuf
binary as hex (`Codec.BinaryRoundTrip`), and what the JSON encoder writes
after the binary decoder reads it when that is not what it writes after
decoding the canonical JSON.
-}
type alias Sample =
    { name : String
    , message : String
    , canonical : String
    , expected : Maybe String
    , forms : List Form
    , binary : String
    , binaryJson : Maybe String
    }


{-| Another form of a sample, and what the encoder writes after decoding it
when that is not what it writes after decoding the canonical form.
-}
type alias Form =
    { form : String
    , input : String
    , expected : Maybe String
    }


{-| A message's generated decoder and encoder, run one after the other.
-}
type alias Codec =
    String -> Result String Json.Encode.Value


codec : Decoder a -> (a -> Json.Encode.Value) -> Codec
codec decoder encode input =
    Json.Decode.decodeString decoder input
        |> Result.map encode
        |> Result.mapError Json.Decode.errorToString


{-| A test per form of every sample, each run through the codec of its
message in `codecs`.
-}
suite : String -> List ( String, Codec ) -> List Sample -> Test
suite name codecs samples =
    let
        table =
            Dict.fromList codecs
    in
    describe name
        (List.map
            (\sample ->
                describe sample.name
                    (List.map (formTest (Dict.get sample.message table) sample)
                        ({ form = "canonical", input = sample.canonical, expected = Nothing } :: sample.forms)
                    )
            )
            samples
        )


formTest : Maybe Codec -> Sample -> Form -> Test
formTest maybeCodec sample form =
    test form.form <|
        \_ ->
            case maybeCodec of
                Nothing ->
                    Expect.fail ("no codec for " ++ sample.message)

                Just run ->
                    roundTrip run
                        form.input
                        (form.expected
                            |> orElse sample.expected
                            |> Maybe.withDefault sample.canonical
                        )


orElse : Maybe a -> Maybe a -> Maybe a
orElse fallback maybe =
    case maybe of
        Just _ ->
            maybe

        Nothing ->
            fallback


{-| `input` decodes and re-encodes as `expected`, compared as JSON: objects
by their keys whatever the order, numbers by value.
-}
roundTrip : Codec -> String -> String -> Expectation
roundTrip run input expected =
    case run input of
        Err problem ->
            Expect.fail ("does not decode: " ++ problem ++ "\n\ninput: " ++ input)

        Ok value ->
            let
                actual =
                    Json.Encode.encode 0 value
            in
            if parse actual == parse expected then
                Expect.pass

            else
                Expect.fail
                    ("re-encodes as\n\n    "
                        ++ actual
                        ++ "\n\nnot\n\n    "
                        ++ expected
                        ++ "\n\ninput: "
                        ++ input
                    )


{-| JSON as data Elm's `==` compares structurally.
-}
type Json
    = Null
    | Bool Bool
    | Number Float
    | Text String
    | Array (List Json)
    | Object (Dict String Json)


parse : String -> Result String Json
parse text =
    Json.Decode.decodeString json text
        |> Result.mapError Json.Decode.errorToString


json : Decoder Json
json =
    Json.Decode.oneOf
        [ Json.Decode.null Null
        , Json.Decode.map Bool Json.Decode.bool
        , Json.Decode.map Number Json.Decode.float
        , Json.Decode.map Text Json.Decode.string
        , Json.Decode.map Array (Json.Decode.list (Json.Decode.lazy (\_ -> json)))
        , Json.Decode.map Object (Json.Decode.dict (Json.Decode.lazy (\_ -> json)))
        ]
