module Proto.DepthGapsTest exposing (suite)

{-| The guard, the JSON bound on `Struct`/`Value`/`ListValue`, the `Any`
depth through the registry, and scrubbed errors.

The guard rests on elm/json's `decodeString` catching what its decoder
throws (`_Json_runOnString`); the first test fails if a release stops doing
so.

-}

import Expect
import Json.Decode
import Json.Encode
import Proto.Any
import Proto.Binary
import Proto.Duration
import Proto.Error
import Proto.Json
import Proto.Message
import Proto.WellKnown
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "guards on depth"
        [ test "a Value read from JSON nests at most 100 arrays and objects" <|
            \_ ->
                Expect.all
                    [ \_ -> Json.Decode.decodeString Proto.Json.jsonValue (lists 100) |> Result.map (\_ -> ()) |> Expect.equal (Ok ())
                    , \_ -> Json.Decode.decodeString Proto.Json.jsonValue (lists 101) |> Result.map (\_ -> ()) |> Expect.notEqual (Ok ())
                    , \_ -> Json.Decode.decodeString Proto.Json.struct ("{\"a\":" ++ lists 99 ++ "}") |> Result.map (\_ -> ()) |> Expect.equal (Ok ())
                    , \_ -> Json.Decode.decodeString Proto.Json.struct ("{\"a\":" ++ lists 100 ++ "}") |> Result.map (\_ -> ()) |> Expect.notEqual (Ok ())
                    ]
                    ()
        , test "a Value read at the limit writes as JSON and as binary and reads back" <|
            \_ ->
                case Proto.Message.decodeJson Proto.WellKnown.registry Proto.WellKnown.value (Json.Decode.decodeString Json.Decode.value (lists 100) |> Result.withDefault Json.Encode.null) of
                    Ok value ->
                        Proto.Binary.decode (Proto.Binary.messageDecoder Proto.Binary.value) (Proto.Binary.encode (Proto.Binary.messageEncoder Proto.Binary.value) value)
                            |> Expect.equal (Ok value)

                    Err _ ->
                        Expect.fail "100 levels did not read"
        , test "an Any holding an Any 101 deep fails, from JSON and to JSON" <|
            \_ ->
                Expect.all
                    [ \_ -> Proto.Message.decodeJson Proto.WellKnown.registry Proto.WellKnown.any (parse (anys 100)) |> Result.map (\_ -> ()) |> Expect.equal (Ok ())
                    , \_ -> Proto.Message.decodeJson Proto.WellKnown.registry Proto.WellKnown.any (parse (anys 101)) |> Result.map (\_ -> ()) |> Expect.notEqual (Ok ())
                    , \_ -> Proto.Any.toJson Proto.WellKnown.registry (packed 101) |> Result.mapError reason |> Result.map (\_ -> ()) |> Expect.equal (Err (Just Proto.Error.TooDeep))
                    , \_ -> Proto.Any.toJson Proto.WellKnown.registry (packed 100) |> Result.map (\_ -> ()) |> Expect.equal (Ok ())
                    ]
                    ()
        ]


lists : Int -> String
lists depth =
    String.repeat depth "[" ++ String.repeat depth "]"


anys : Int -> String
anys depth =
    String.repeat (depth - 1) "{\"@type\":\"type.googleapis.com/google.protobuf.Any\",\"value\":"
        ++ "{\"@type\":\"type.googleapis.com/google.protobuf.Duration\",\"value\":\"1s\"}"
        ++ String.repeat (depth - 1) "}"


packed : Int -> Proto.Any.Any
packed depth =
    List.foldl (\_ inner -> Proto.Any.pack Proto.WellKnown.any inner)
        (Proto.Any.pack Proto.WellKnown.duration (Proto.Duration.fromParts 1 0))
        (List.range 2 depth)


parse : String -> Json.Decode.Value
parse text =
    Json.Decode.decodeString Json.Decode.value text |> Result.withDefault Json.Encode.null


reason : Proto.Error.Error -> Maybe Proto.Error.Reason
reason error =
    case error of
        Proto.Error.BadBinary binary ->
            Just binary.reason

        _ ->
            Nothing


leafText : Json.Decode.Error -> List String
leafText error =
    case error of
        Json.Decode.Field _ inner ->
            leafText inner

        Json.Decode.Index _ inner ->
            leafText inner

        Json.Decode.OneOf ways ->
            List.concatMap leafText ways

        Json.Decode.Failure text _ ->
            [ text ]
