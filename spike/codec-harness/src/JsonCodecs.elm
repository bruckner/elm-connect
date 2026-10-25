module JsonCodecs exposing (Entry, table)

{-| The proto3 JSON codecs of every top-level message of
conformance/codec/codec.proto under the default options, by full name, in
the shape the bench and the size programs run them.
-}

import Dict exposing (Dict)
import Generated.Codec.Default.Codec.V1 as V1
import Json.Decode
import Json.Encode


{-| `decode` reads the JSON and says whether it decoded; `prepare` decodes it
once and gives a function that encodes the value back to JSON text.
-}
type alias Entry =
    { decode : String -> Bool
    , prepare : String -> Maybe (() -> String)
    }


entry : Json.Decode.Decoder a -> (a -> Json.Encode.Value) -> Entry
entry decoder encode =
    { decode =
        \input ->
            case Json.Decode.decodeString decoder input of
                Ok _ ->
                    True

                Err _ ->
                    False
    , prepare =
        \input ->
            Json.Decode.decodeString decoder input
                |> Result.toMaybe
                |> Maybe.map (\value () -> Json.Encode.encode 0 (encode value))
    }


table : Dict String Entry
table =
    Dict.fromList
        [ ( "codec.v1.Scalars", entry V1.decodeScalars V1.encodeScalars )
        , ( "codec.v1.Optionals", entry V1.decodeOptionals V1.encodeOptionals )
        , ( "codec.v1.Repeated", entry V1.decodeRepeated V1.encodeRepeated )
        , ( "codec.v1.Maps", entry V1.decodeMaps V1.encodeMaps )
        , ( "codec.v1.Choice", entry V1.decodeChoice V1.encodeChoice )
        , ( "codec.v1.Names", entry V1.decodeNames V1.encodeNames )
        , ( "codec.v1.Outer", entry V1.decodeOuter V1.encodeOuter )
        , ( "codec.v1.Tree", entry V1.decodeTree V1.encodeTree )
        , ( "codec.v1.WellKnown", entry V1.decodeWellKnown V1.encodeWellKnown )
        , ( "codec.v1.Wrappers", entry V1.decodeWrappers V1.encodeWrappers )
        , ( "codec.v1.Across", entry V1.decodeAcross V1.encodeAcross )
        , ( "codec.v1.Leaf", entry V1.decodeLeaf V1.encodeLeaf )
        , ( "codec.v1.Everything", entry V1.decodeEverything V1.encodeEverything )
        ]
