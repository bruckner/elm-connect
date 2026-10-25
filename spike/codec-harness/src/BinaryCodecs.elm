module BinaryCodecs exposing (table)

{-| The protobuf binary codecs of every top-level message of
conformance/codec/codec.proto under `codec=binary`, by full name: each reads
base64 text as the message and writes it back as base64.
-}

import Bytes.Decode
import Bytes.Encode
import Dict exposing (Dict)
import Generated.Codec.Binary.Codec.V1 as V1
import Proto.Binary
import Proto.Bytes


entry : Proto.Binary.Decoder a -> (a -> Bytes.Encode.Encoder) -> String -> Maybe String
entry decoder encode input =
    Proto.Bytes.fromBase64 input
        |> Maybe.andThen (Proto.Binary.decode decoder)
        |> Maybe.map (Proto.Binary.encode encode >> Proto.Bytes.toBase64)


table : Dict String (String -> Maybe String)
table =
    Dict.fromList
        [ ( "codec.v1.Scalars", entry V1.decodeScalarsBytes V1.encodeScalarsBytes )
        , ( "codec.v1.Optionals", entry V1.decodeOptionalsBytes V1.encodeOptionalsBytes )
        , ( "codec.v1.Repeated", entry V1.decodeRepeatedBytes V1.encodeRepeatedBytes )
        , ( "codec.v1.Maps", entry V1.decodeMapsBytes V1.encodeMapsBytes )
        , ( "codec.v1.Choice", entry V1.decodeChoiceBytes V1.encodeChoiceBytes )
        , ( "codec.v1.Names", entry V1.decodeNamesBytes V1.encodeNamesBytes )
        , ( "codec.v1.Outer", entry V1.decodeOuterBytes V1.encodeOuterBytes )
        , ( "codec.v1.Tree", entry V1.decodeTreeBytes V1.encodeTreeBytes )
        , ( "codec.v1.WellKnown", entry V1.decodeWellKnownBytes V1.encodeWellKnownBytes )
        , ( "codec.v1.Wrappers", entry V1.decodeWrappersBytes V1.encodeWrappersBytes )
        , ( "codec.v1.Across", entry V1.decodeAcrossBytes V1.encodeAcrossBytes )
        , ( "codec.v1.Leaf", entry V1.decodeLeafBytes V1.encodeLeafBytes )
        , ( "codec.v1.Everything", entry V1.decodeEverythingBytes V1.encodeEverythingBytes )
        ]
