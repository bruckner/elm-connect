module Proto.MessageTest exposing (suite)

import Expect
import Proto.Field as Field exposing (Behavior(..), Cardinality(..), Kind(..), Scalar(..))
import Proto.Message as Message
import Test exposing (Test, describe, test)


{-| A message as generated code builds one: a oneof whose members are apart,
another after it, and a field with every modifier.
-}
event : Message.Descriptor
event =
    Message.descriptor "t.v1.Event"
        [ Field.descriptor "name" "name" 1 CardinalitySingular (KindScalar ScalarString) |> Field.withBehavior [ BehaviorIdentifier ]
        , Field.descriptor "text" "text" 2 CardinalitySingular (KindScalar ScalarString) |> Field.inOneof "body"
        , Field.descriptor "level" "level" 3 CardinalityOptional (KindEnum "t.v1.Level") |> Field.inOneof "source"
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
                ( Message.typeName event, Message.oneofs event, List.map Field.oneof (Message.fields event) )
                    |> Expect.equal ( "t.v1.Event", [ "body", "source" ], [ Nothing, Just "body", Just "source", Just "body", Nothing ] )
        , test "a field reads back what built it, and nothing more until a modifier says so" <|
            \_ ->
                List.map
                    (\f -> ( ( Field.name f, Field.jsonName f, Field.number f ), ( Field.cardinality f, Field.kind f ), ( Field.behavior f, Field.deprecated f ) ))
                    (Message.fields event)
                    |> Expect.equal
                        [ ( ( "name", "name", 1 ), ( CardinalitySingular, KindScalar ScalarString ), ( [ BehaviorIdentifier ], False ) )
                        , ( ( "text", "text", 2 ), ( CardinalitySingular, KindScalar ScalarString ), ( [], False ) )
                        , ( ( "level", "level", 3 ), ( CardinalityOptional, KindEnum "t.v1.Level" ), ( [], False ) )
                        , ( ( "link", "link", 4 ), ( CardinalitySingular, KindScalar ScalarString ), ( [], False ) )
                        , ( ( "create_time", "createTime", 5 ), ( CardinalitySingular, KindMessage "google.protobuf.Timestamp" ), ( [ BehaviorOutputOnly, BehaviorImmutable ], True ) )
                        ]
        ]
