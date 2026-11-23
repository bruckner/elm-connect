module Proto.WriteTest exposing (suite)

import Dict
import Expect
import Json.Encode
import Proto.Duration
import Proto.Error exposing (Error(..))
import Proto.Json
import Proto.Value exposing (Value(..))
import Test exposing (Test, describe, test)
import Time


refusal : Proto.Json.Encoder -> Maybe ( String, List String )
refusal encoder =
    case Proto.Json.encode encoder of
        Err (NotWritable { typeName, path }) ->
            Just ( typeName, path )

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
                        [ Just ( "google.protobuf.Timestamp", [ "when" ] )
                        , Just ( "google.protobuf.Duration", [ "ttl" ] )
                        , Just ( "google.protobuf.FieldMask", [ "mask" ] )
                        , Just ( "google.protobuf.Value", [ "items", "1" ] )
                        , Just ( "google.protobuf.Struct", [ "data" ] )
                        ]
        ]

