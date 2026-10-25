module OursCodecs exposing (binaryEchoes, jsonEchoes, table)

{-| elm-connect's codecs (`Proto.Binary`, `Proto.Json`) of the reduced codec
corpus, generated with `codec=both,bytes=bytes` into spike/compare/ours.
-}

import Bytes exposing (Bytes)
import Bytes.Encode
import Codec.V1 as V1
import Dict exposing (Dict)
import Entry exposing (Entry)
import Json.Decode
import Json.Encode
import Proto.Binary


entry : Json.Decode.Decoder a -> (a -> Json.Encode.Value) -> Proto.Binary.Decoder a -> (a -> Bytes.Encode.Encoder) -> Entry
entry decoder encode decoderBytes encodeBytes =
    { decodeJson = \input -> Json.Decode.decodeString decoder input |> Result.toMaybe |> isJust
    , decodeBinary = \input -> Proto.Binary.decode decoderBytes input |> isJust
    , prepareJson =
        \input ->
            Json.Decode.decodeString decoder input
                |> Result.toMaybe
                |> Maybe.map (\value () -> Json.Encode.encode 0 (encode value))
    , prepareBinary =
        \input ->
            Proto.Binary.decode decoderBytes input
                |> Maybe.map (\value () -> Proto.Binary.encode encodeBytes value)
    , toBinary =
        \input ->
            Json.Decode.decodeString decoder input
                |> Result.toMaybe
                |> Maybe.map (Proto.Binary.encode encodeBytes)
    , binaryEcho = \input -> Proto.Binary.decode decoderBytes input |> Maybe.map (Proto.Binary.encode encodeBytes)
    , jsonError =
        \input ->
            case Json.Decode.decodeString decoder input of
                Ok _ ->
                    Nothing

                Err problem ->
                    Just (String.replace "\n" " " (String.right 160 (Json.Decode.errorToString problem)))
    , jsonEcho = \input -> Json.Decode.decodeString decoder input |> Result.toMaybe |> Maybe.map (encode >> Json.Encode.encode 0)
    }


isJust : Maybe a -> Bool
isJust m =
    case m of
        Just _ ->
            True

        Nothing ->
            False


table : Dict String Entry
table =
    Dict.fromList
        [ ( "codec.v1.Scalars", entry V1.decodeScalars V1.encodeScalars V1.decodeScalarsBytes V1.encodeScalarsBytes )
        , ( "codec.v1.Optionals", entry V1.decodeOptionals V1.encodeOptionals V1.decodeOptionalsBytes V1.encodeOptionalsBytes )
        , ( "codec.v1.Repeated", entry V1.decodeRepeated V1.encodeRepeated V1.decodeRepeatedBytes V1.encodeRepeatedBytes )
        , ( "codec.v1.Maps", entry V1.decodeMaps V1.encodeMaps V1.decodeMapsBytes V1.encodeMapsBytes )
        , ( "codec.v1.Choice", entry V1.decodeChoice V1.encodeChoice V1.decodeChoiceBytes V1.encodeChoiceBytes )
        , ( "codec.v1.Names", entry V1.decodeNames V1.encodeNames V1.decodeNamesBytes V1.encodeNamesBytes )
        , ( "codec.v1.Outer", entry V1.decodeOuter V1.encodeOuter V1.decodeOuterBytes V1.encodeOuterBytes )
        , ( "codec.v1.Tree", entry V1.decodeTree V1.encodeTree V1.decodeTreeBytes V1.encodeTreeBytes )
        , ( "codec.v1.WellKnown", entry V1.decodeWellKnown V1.encodeWellKnown V1.decodeWellKnownBytes V1.encodeWellKnownBytes )
        , ( "codec.v1.Wrappers", entry V1.decodeWrappers V1.encodeWrappers V1.decodeWrappersBytes V1.encodeWrappersBytes )
        , ( "codec.v1.Across", entry V1.decodeAcross V1.encodeAcross V1.decodeAcrossBytes V1.encodeAcrossBytes )
        , ( "codec.v1.Leaf", entry V1.decodeLeaf V1.encodeLeaf V1.decodeLeafBytes V1.encodeLeafBytes )
        , ( "codec.v1.Everything", entry V1.decodeEverything V1.encodeEverything V1.decodeEverythingBytes V1.encodeEverythingBytes )
        ]


{-| The binary codecs alone, for the size programs: what DCE keeps of a
record is the whole record, so `table` would keep both formats.
-}
binaryEchoes : Dict String (Bytes -> Maybe Bytes)
binaryEchoes =
    Dict.fromList
        [ ( "codec.v1.Scalars", \input -> Proto.Binary.decode V1.decodeScalarsBytes input |> Maybe.map (Proto.Binary.encode V1.encodeScalarsBytes) )
        , ( "codec.v1.Optionals", \input -> Proto.Binary.decode V1.decodeOptionalsBytes input |> Maybe.map (Proto.Binary.encode V1.encodeOptionalsBytes) )
        , ( "codec.v1.Repeated", \input -> Proto.Binary.decode V1.decodeRepeatedBytes input |> Maybe.map (Proto.Binary.encode V1.encodeRepeatedBytes) )
        , ( "codec.v1.Maps", \input -> Proto.Binary.decode V1.decodeMapsBytes input |> Maybe.map (Proto.Binary.encode V1.encodeMapsBytes) )
        , ( "codec.v1.Choice", \input -> Proto.Binary.decode V1.decodeChoiceBytes input |> Maybe.map (Proto.Binary.encode V1.encodeChoiceBytes) )
        , ( "codec.v1.Names", \input -> Proto.Binary.decode V1.decodeNamesBytes input |> Maybe.map (Proto.Binary.encode V1.encodeNamesBytes) )
        , ( "codec.v1.Outer", \input -> Proto.Binary.decode V1.decodeOuterBytes input |> Maybe.map (Proto.Binary.encode V1.encodeOuterBytes) )
        , ( "codec.v1.Tree", \input -> Proto.Binary.decode V1.decodeTreeBytes input |> Maybe.map (Proto.Binary.encode V1.encodeTreeBytes) )
        , ( "codec.v1.WellKnown", \input -> Proto.Binary.decode V1.decodeWellKnownBytes input |> Maybe.map (Proto.Binary.encode V1.encodeWellKnownBytes) )
        , ( "codec.v1.Wrappers", \input -> Proto.Binary.decode V1.decodeWrappersBytes input |> Maybe.map (Proto.Binary.encode V1.encodeWrappersBytes) )
        , ( "codec.v1.Across", \input -> Proto.Binary.decode V1.decodeAcrossBytes input |> Maybe.map (Proto.Binary.encode V1.encodeAcrossBytes) )
        , ( "codec.v1.Leaf", \input -> Proto.Binary.decode V1.decodeLeafBytes input |> Maybe.map (Proto.Binary.encode V1.encodeLeafBytes) )
        , ( "codec.v1.Everything", \input -> Proto.Binary.decode V1.decodeEverythingBytes input |> Maybe.map (Proto.Binary.encode V1.encodeEverythingBytes) )
        ]


{-| The JSON codecs alone, for the size programs.
-}
jsonEchoes : Dict String (String -> Maybe String)
jsonEchoes =
    Dict.fromList
        [ ( "codec.v1.Scalars", \input -> Json.Decode.decodeString V1.decodeScalars input |> Result.toMaybe |> Maybe.map (V1.encodeScalars >> Json.Encode.encode 0) )
        , ( "codec.v1.Optionals", \input -> Json.Decode.decodeString V1.decodeOptionals input |> Result.toMaybe |> Maybe.map (V1.encodeOptionals >> Json.Encode.encode 0) )
        , ( "codec.v1.Repeated", \input -> Json.Decode.decodeString V1.decodeRepeated input |> Result.toMaybe |> Maybe.map (V1.encodeRepeated >> Json.Encode.encode 0) )
        , ( "codec.v1.Maps", \input -> Json.Decode.decodeString V1.decodeMaps input |> Result.toMaybe |> Maybe.map (V1.encodeMaps >> Json.Encode.encode 0) )
        , ( "codec.v1.Choice", \input -> Json.Decode.decodeString V1.decodeChoice input |> Result.toMaybe |> Maybe.map (V1.encodeChoice >> Json.Encode.encode 0) )
        , ( "codec.v1.Names", \input -> Json.Decode.decodeString V1.decodeNames input |> Result.toMaybe |> Maybe.map (V1.encodeNames >> Json.Encode.encode 0) )
        , ( "codec.v1.Outer", \input -> Json.Decode.decodeString V1.decodeOuter input |> Result.toMaybe |> Maybe.map (V1.encodeOuter >> Json.Encode.encode 0) )
        , ( "codec.v1.Tree", \input -> Json.Decode.decodeString V1.decodeTree input |> Result.toMaybe |> Maybe.map (V1.encodeTree >> Json.Encode.encode 0) )
        , ( "codec.v1.WellKnown", \input -> Json.Decode.decodeString V1.decodeWellKnown input |> Result.toMaybe |> Maybe.map (V1.encodeWellKnown >> Json.Encode.encode 0) )
        , ( "codec.v1.Wrappers", \input -> Json.Decode.decodeString V1.decodeWrappers input |> Result.toMaybe |> Maybe.map (V1.encodeWrappers >> Json.Encode.encode 0) )
        , ( "codec.v1.Across", \input -> Json.Decode.decodeString V1.decodeAcross input |> Result.toMaybe |> Maybe.map (V1.encodeAcross >> Json.Encode.encode 0) )
        , ( "codec.v1.Leaf", \input -> Json.Decode.decodeString V1.decodeLeaf input |> Result.toMaybe |> Maybe.map (V1.encodeLeaf >> Json.Encode.encode 0) )
        , ( "codec.v1.Everything", \input -> Json.Decode.decodeString V1.decodeEverything input |> Result.toMaybe |> Maybe.map (V1.encodeEverything >> Json.Encode.encode 0) )
        ]
