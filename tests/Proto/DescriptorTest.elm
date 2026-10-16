module Proto.DescriptorTest exposing (suite)

import Expect
import Proto.Descriptor as D exposing (Behavior(..), Cardinality(..), Idempotency(..), Kind(..), Scalar(..))
import Proto.EnumDescriptor
import Proto.EnumValue as EnumValue
import Proto.Field as Field
import Proto.MessageDescriptor as MessageDescriptor
import Proto.MethodDescriptor as MethodDescriptor
import Test exposing (Test, describe, test)


{-| A message as generated code builds one: a oneof whose members are apart,
another after it, and a field with every modifier.
-}
event : D.MessageDescriptor
event =
    D.message "t.v1.Event"
        [ D.field "name" "name" 1 Singular (Scalar String) |> D.withBehavior [ Identifier ]
        , D.field "text" "text" 2 Singular (Scalar String) |> D.inOneof "body"
        , D.field "level" "level" 3 Optional (Enum "t.v1.Level") |> D.inOneof "source"
        , D.field "link" "link" 4 Singular (Scalar String) |> D.inOneof "body"
        , D.field "create_time" "createTime" 5 Singular (Message "google.protobuf.Timestamp")
            |> D.withBehavior [ OutputOnly ]
            |> D.withBehavior [ Immutable ]
            |> D.withDeprecated
        ]


suite : Test
suite =
    describe "Proto.Descriptor"
        [ test "a message's oneofs are the ones its fields name, in order of first appearance" <|
            \_ ->
                ( MessageDescriptor.typeName event, MessageDescriptor.oneofs event, List.map Field.oneof (MessageDescriptor.fields event) )
                    |> Expect.equal ( "t.v1.Event", [ "body", "source" ], [ Nothing, Just "body", Just "source", Just "body", Nothing ] )
        , test "a field reads back what built it, and nothing more until a modifier says so" <|
            \_ ->
                List.map
                    (\f -> ( ( Field.name f, Field.jsonName f, Field.number f ), ( Field.cardinality f, Field.kind f ), ( Field.behavior f, Field.deprecated f ) ))
                    (MessageDescriptor.fields event)
                    |> Expect.equal
                        [ ( ( "name", "name", 1 ), ( Singular, Scalar String ), ( [ Identifier ], False ) )
                        , ( ( "text", "text", 2 ), ( Singular, Scalar String ), ( [], False ) )
                        , ( ( "level", "level", 3 ), ( Optional, Enum "t.v1.Level" ), ( [], False ) )
                        , ( ( "link", "link", 4 ), ( Singular, Scalar String ), ( [], False ) )
                        , ( ( "create_time", "createTime", 5 ), ( Singular, Message "google.protobuf.Timestamp" ), ( [ OutputOnly, Immutable ], True ) )
                        ]
        , test "an enum's values, aliases and deprecation included" <|
            \_ ->
                let
                    level =
                        D.enum "t.v1.Level"
                            [ D.value "LEVEL_UNSPECIFIED" 0
                            , D.value "LEVEL_HIGH" 1
                            , D.value "LEVEL_URGENT" 1 |> D.withDeprecatedValue
                            ]
                in
                ( Proto.EnumDescriptor.typeName level
                , Proto.EnumDescriptor.values level |> List.map (\v -> ( EnumValue.name v, EnumValue.number v, EnumValue.deprecated v ))
                )
                    |> Expect.equal
                        ( "t.v1.Level"
                        , [ ( "LEVEL_UNSPECIFIED", 0, False ), ( "LEVEL_HIGH", 1, False ), ( "LEVEL_URGENT", 1, True ) ]
                        )
        , test "a method reads back what built it" <|
            \_ ->
                let
                    get =
                        D.method "t.v1.Events" "Get" Idempotent "t.v1.GetRequest" "t.v1.Event" []
                in
                ( ( MethodDescriptor.service get, MethodDescriptor.name get, MethodDescriptor.idempotency get )
                , ( MethodDescriptor.input get, MethodDescriptor.output get, List.length (MethodDescriptor.bindings get) )
                )
                    |> Expect.equal ( ( "t.v1.Events", "Get", Idempotent ), ( "t.v1.GetRequest", "t.v1.Event", 0 ) )
        ]
