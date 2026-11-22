module Proto.WriteTest exposing (suite)

import Dict
import Expect
import Json.Encode
import Proto.Duration
import Proto.Error exposing (Error(..), WriteReason(..))
import Proto.Json
import Proto.Value exposing (Value(..))
import Test exposing (Test, describe, test)
import Time


refusal : Proto.Json.Encoder -> Maybe ( String, List String, WriteReason )
refusal encoder =
    case Proto.Json.encode encoder of
        Err (NotWritable { typeName, path, reason }) ->
            Just ( typeName, path, reason )

        _ ->
            Nothing


written : Proto.Json.Encoder -> Result Error String
written =
    Proto.Json.encode >> Result.map (Json.Encode.encode 0)


suite : Test
suite =
    describe "Proto.Json encoders"
        [ test "a value with a JSON form is written, fields that cannot fail first" <|
            \_ ->
                Proto.Json.writeObject [ ( "a", Just (Json.Encode.int 1) ), ( "b", Nothing ) ]
                    [ ( "t", Proto.Json.writeOptional Proto.Json.writeTimestamp (Just (Time.millisToPosix 0)) )
                    , ( "u", Proto.Json.writeOptional Proto.Json.writeTimestamp Nothing )
                    ]
                    |> written
                    |> Expect.equal (Ok """{"a":1,"t":"1970-01-01T00:00:00Z"}""")
        , test "each kind of value with no JSON form is refused, named, at its path" <|
            \_ ->
                [ Proto.Json.writeObject [] [ ( "when", Proto.Json.writeTimestamp (Time.millisToPosix 300000000000000) ) ]
                , Proto.Json.writeObject [] [ ( "ttl", Proto.Json.writeDuration (Proto.Duration.fromParts 315576000001 0) ) ]
                , Proto.Json.writeObject [] [ ( "mask", Proto.Json.writeFieldMask [ "fooBar" ] ) ]
                , Proto.Json.writeObject [] [ ( "items", Proto.Json.writeRepeated Proto.Json.writeValue [ ValueNumber 1, ValueNumber (0 / 0) ] ) ]
                , Proto.Json.writeObject [] [ ( "data", Proto.Json.writeStruct (Dict.singleton "x" (ValueNumber (1 / 0))) ) ]
                ]
                    |> List.map refusal
                    |> Expect.equal
                        [ Just ( "google.protobuf.Timestamp", [ "when" ], NoJsonForm )
                        , Just ( "google.protobuf.Duration", [ "ttl" ], NoJsonForm )
                        , Just ( "google.protobuf.FieldMask", [ "mask" ], NoJsonForm )
                        , Just ( "google.protobuf.Value", [ "items", "1" ], NoJsonForm )
                        , Just ( "google.protobuf.Struct", [ "data" ], NoJsonForm )
                        ]
        , test "a Struct nested past the limit is refused, and one at it is written" <|
            \_ ->
                let
                    nested n =
                        List.foldl (\_ inner -> Dict.singleton "a" (ValueStruct inner)) Dict.empty (List.range 2 n)
                in
                [ refusal (Proto.Json.writeStruct (nested 100)), refusal (Proto.Json.writeStruct (nested 101)) ]
                    |> Expect.equal [ Nothing, Just ( "google.protobuf.Struct", [], NestedTooDeep ) ]
        , test "a message on a cycle nested past the limit is refused without being built" <|
            \_ ->
                let
                    chain n =
                        List.foldl (\_ inner -> Chain [ inner ]) (Chain []) (List.range 2 n)
                in
                [ refusal (encodeChain (chain 100)), refusal (encodeChain (chain 100000)) |> Maybe.map (\( name, _, why ) -> ( name, why )) |> Maybe.map (\( n, w ) -> ( n, [], w )) ]
                    |> Expect.equal [ Nothing, Just ( "t.Chain", [], NestedTooDeep ) ]
        ]


type Chain
    = Chain (List Chain)


encodeChain : Chain -> Proto.Json.Encoder
encodeChain =
    Proto.Json.writeFrom encodeChainAt


encodeChainAt : Int -> Chain -> Proto.Json.Encoder
encodeChainAt depth (Chain children) =
    if depth > Proto.Json.writeLimit then
        Proto.Json.writeTooDeep "t.Chain"

    else
        Proto.Json.writeObject [] [ ( "children", Proto.Json.writeRepeated (encodeChainAt (depth + 1)) children ) ]
