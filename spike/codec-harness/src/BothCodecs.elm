module BothCodecs exposing (Entry, table)

{-| The proto3 JSON and protobuf binary codecs of every top-level message of
conformance/codec/codec.proto under `codec=both`, by full name, in the shape
Bench2 runs them.
-}

import Bytes exposing (Bytes)
import Bytes.Decode
import Bytes.Encode
import Dict exposing (Dict)
import Generated.Codec.Both.Codec.V1 as V1
import Json.Decode
import Json.Encode
import Proto.Binary


{-| Each direction of each codec, and `toBinary` to turn a JSON input into its
binary once, outside the timing.
-}
type alias Entry =
    { decodeJson : String -> Bool
    , decodeBinary : Bytes -> Bool
    , prepareJson : String -> Maybe (() -> String)
    , prepareBinary : Bytes -> Maybe (() -> Bytes)
    , toBinary : String -> Maybe Bytes
    }


entry : Json.Decode.Decoder a -> (a -> Json.Encode.Value) -> Proto.Binary.Decoder a -> (a -> Bytes.Encode.Encoder) -> Entry
entry decoder encode decoderBytes encodeBytes =
    { decodeJson =
        \input ->
            case Json.Decode.decodeString decoder input of
                Ok _ ->
                    True

                Err _ ->
                    False
    , decodeBinary =
        \input ->
            case Proto.Binary.decode decoderBytes input of
                Just _ ->
                    True

                Nothing ->
                    False
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
    }


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
