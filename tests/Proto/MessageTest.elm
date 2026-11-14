module Proto.MessageTest exposing (suite)

import Bytes.Encode
import Expect
import Json.Encode
import Proto.Any
import Proto.Duration
import Proto.Enum as Enum
import Proto.EnumValue as EnumValue
import Proto.Error exposing (Error(..), Reason(..))
import Proto.Field as Field exposing (Behavior(..), Cardinality(..), Kind(..), Scalar(..))
import Proto.Message as Message
import Proto.Registry
import Proto.WellKnown
import Test exposing (Test, describe, test)


level : Enum.Descriptor
level =
    Enum.descriptor "t.v1.Level" [ EnumValue.descriptor "LEVEL_UNSPECIFIED" 0 ]


{-| A message as generated code builds one: a oneof whose members are apart,
another after it, and a field with every modifier.
-}
event : Message.Descriptor
event =
    Message.descriptor "t.v1.Event"
        [ Field.descriptor "name" "name" 1 CardinalitySingular (KindScalar ScalarString) |> Field.withBehavior [ BehaviorIdentifier ]
        , Field.descriptor "text" "text" 2 CardinalitySingular (KindScalar ScalarString) |> Field.inOneof "body"
        , Field.descriptor "level" "level" 3 CardinalityOptional (KindEnum level) |> Field.inOneof "source"
        , Field.descriptor "link" "link" 4 CardinalitySingular (KindScalar ScalarString) |> Field.inOneof "body"
        , Field.descriptor "create_time" "createTime" 5 CardinalitySingular (KindMessage "google.protobuf.Timestamp")
            |> Field.withBehavior [ BehaviorOutputOnly ]
            |> Field.withBehavior [ BehaviorImmutable ]
            |> Field.withDeprecated
        ]


suite : Test
suite =
    describe "Proto.Message"
        [ test "a message's oneofs are the ones its fields name, in order of first appearance" <|
            \_ ->
                ( Message.fullName event, Message.oneofs event, List.map Field.oneof (Message.fields event) )
                    |> Expect.equal ( "t.v1.Event", [ "body", "source" ], [ Nothing, Just "body", Just "source", Just "body", Nothing ] )
        , test "a field reads back what built it, and nothing more until a modifier says so" <|
            \_ ->
                List.map
                    (\f -> ( ( Field.name f, Field.jsonName f, Field.number f ), ( Field.cardinality f, Field.kind f ), ( Field.behavior f, Field.deprecated f ) ))
                    (Message.fields event)
                    |> Expect.equal
                        [ ( ( "name", "name", 1 ), ( CardinalitySingular, KindScalar ScalarString ), ( [ BehaviorIdentifier ], False ) )
                        , ( ( "text", "text", 2 ), ( CardinalitySingular, KindScalar ScalarString ), ( [], False ) )
                        , ( ( "level", "level", 3 ), ( CardinalityOptional, KindEnum level ), ( [], False ) )
                        , ( ( "link", "link", 4 ), ( CardinalitySingular, KindScalar ScalarString ), ( [], False ) )
                        , ( ( "create_time", "createTime", 5 ), ( CardinalitySingular, KindMessage "google.protobuf.Timestamp" ), ( [ BehaviorOutputOnly, BehaviorImmutable ], True ) )
                        ]
        , reading
        ]


durationAny : Json.Encode.Value
durationAny =
    Json.Encode.object
        [ ( "@type", Json.Encode.string "type.googleapis.com/google.protobuf.Duration" )
        , ( "value", Json.Encode.string "2s" )
        ]


bytesOf : List Int -> Bytes.Encode.Encoder
bytesOf =
    List.map Bytes.Encode.unsignedInt8 >> Bytes.Encode.sequence


reading : Test
reading =
    describe "reading a message"
        [ test "decodeJson reads a message's proto3 JSON" <|
            \_ ->
                Message.decodeJson Proto.Registry.empty Proto.WellKnown.duration (Json.Encode.string "2.5s")
                    |> Result.map Proto.Duration.toMilliseconds
                    |> Expect.equal (Ok 2500)
        , test "decodeJson converts an Any through the registry, and names a type it lacks" <|
            \_ ->
                ( Message.decodeJson Proto.WellKnown.registry Proto.WellKnown.any durationAny
                    |> Result.map Proto.Any.typeName
                , Message.decodeJson Proto.Registry.empty Proto.WellKnown.any durationAny
                , Message.decodeJson (Proto.Registry.lenient Proto.Registry.empty) Proto.WellKnown.any durationAny
                    |> Result.map Proto.Any.typeName
                )
                    |> Expect.equal
                        ( Ok "google.protobuf.Duration"
                        , Err (UnregisteredType "type.googleapis.com/google.protobuf.Duration")
                        , Ok "google.protobuf.Duration"
                        )
        , test "decodeJson gives elm/json's error for anything else, a registered Any's bad JSON included" <|
            \_ ->
                [ Message.decodeJson Proto.Registry.empty Proto.WellKnown.duration (Json.Encode.int 3)
                , Message.decodeJson Proto.WellKnown.registry
                    Proto.WellKnown.duration
                    (Json.Encode.object [ ( "@type", Json.Encode.string "type.googleapis.com/google.protobuf.Duration" ), ( "value", Json.Encode.int 2 ) ])
                , Message.decodeJson Proto.WellKnown.registry
                    Proto.WellKnown.any
                    (Json.Encode.object [ ( "@type", Json.Encode.string "type.googleapis.com/google.protobuf.Duration" ), ( "value", Json.Encode.int 2 ) ])
                    |> Result.map (\_ -> Proto.Duration.fromMilliseconds 0)
                ]
                    |> List.map
                        (\result ->
                            case result of
                                Err (BadJson _) ->
                                    True

                                _ ->
                                    False
                        )
                    |> Expect.equal [ True, True, True ]
        , test "decodeBinary reads a message's protobuf binary" <|
            \_ ->
                Message.decodeBinary Proto.WellKnown.stringValue (Bytes.Encode.encode (bytesOf [ 0x0A, 0x02, 0x68, 0x69 ]))
                    |> Expect.equal (Ok "hi")
        , test "decodeBinary gives the binary report of a failure" <|
            \_ ->
                Message.decodeBinary Proto.WellKnown.stringValue (Bytes.Encode.encode (bytesOf [ 0x0A, 0x05, 0x68 ]))
                    |> Expect.equal (Err { typeName = "google.protobuf.StringValue", reason = Truncated, path = [ ( "google.protobuf.StringValue", 1 ) ], offset = 1 })
        ]
