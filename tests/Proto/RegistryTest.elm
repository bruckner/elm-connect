module Proto.RegistryTest exposing (suite)

import Expect
import Proto.Enum as Enum
import Proto.EnumValue as EnumValue
import Proto.Field as Field exposing (Cardinality(..), Kind(..), Scalar(..))
import Proto.Message as Message
import Proto.Registry as Registry
import Test exposing (Test, describe, test)


note : String -> Message.Descriptor
note title =
    Message.descriptor "notes.v1.Note" [ Field.descriptor title title 1 CardinalitySingular (KindScalar ScalarString) ]


visibility : Enum.Descriptor
visibility =
    Enum.descriptor "notes.v1.Visibility" [ EnumValue.descriptor "VISIBILITY_UNSPECIFIED" 0 ]


fieldName : Maybe Message.Descriptor -> Maybe String
fieldName =
    Maybe.andThen (Message.fields >> List.head) >> Maybe.map Field.name


resolves : Kind -> Bool
resolves kind =
    case kind of
        KindMessage name ->
            Registry.message name Registry.wellKnown /= Nothing

        KindEnum name ->
            Registry.enum name Registry.wellKnown /= Nothing

        KindScalar _ ->
            True


suite : Test
suite =
    describe "Proto.Registry"
        [ test "a message and an enum by full name" <|
            \_ ->
                let
                    registry =
                        Registry.fromDescriptors [ note "title" ] [ visibility ]
                in
                ( Registry.message "notes.v1.Note" registry |> Maybe.map Message.typeName
                , Registry.enum "notes.v1.Visibility" registry |> Maybe.map Enum.typeName
                , ( Registry.message "notes.v1.Visibility" registry, Registry.enum "notes.v1.Note" registry )
                )
                    |> Expect.equal ( Just "notes.v1.Note", Just "notes.v1.Visibility", ( Nothing, Nothing ) )
        , test "the empty registry has nothing" <|
            \_ ->
                ( Registry.messages Registry.empty, Registry.enums Registry.empty )
                    |> Expect.equal ( [], [] )
        , test "of two descriptors with one name, the first is kept" <|
            \_ ->
                Registry.fromDescriptors [ note "first", note "second" ] []
                    |> Registry.message "notes.v1.Note"
                    |> fieldName
                    |> Expect.equal (Just "first")
        , test "a union keeps the left one's" <|
            \_ ->
                Registry.union (Registry.fromDescriptors [ note "left" ] []) (Registry.fromDescriptors [ note "right" ] [ visibility ])
                    |> (\registry -> ( Registry.message "notes.v1.Note" registry |> fieldName, List.length (Registry.enums registry) ))
                    |> Expect.equal ( Just "left", 1 )
        , test "a union of a diamond holds each type once" <|
            \_ ->
                let
                    shared =
                        Registry.fromDescriptors [ note "title" ] [ visibility ]
                in
                Registry.union (Registry.union shared Registry.wellKnown) (Registry.union shared Registry.wellKnown)
                    |> (\registry -> ( List.length (Registry.messages registry), List.length (Registry.enums registry) ))
                    |> Expect.equal ( 18, 2 )
        , test "the well-known types" <|
            \_ ->
                Registry.messages Registry.wellKnown
                    |> List.map Message.typeName
                    |> Expect.equal
                        [ "google.protobuf.Any"
                        , "google.protobuf.BoolValue"
                        , "google.protobuf.BytesValue"
                        , "google.protobuf.DoubleValue"
                        , "google.protobuf.Duration"
                        , "google.protobuf.Empty"
                        , "google.protobuf.FieldMask"
                        , "google.protobuf.FloatValue"
                        , "google.protobuf.Int32Value"
                        , "google.protobuf.Int64Value"
                        , "google.protobuf.ListValue"
                        , "google.protobuf.StringValue"
                        , "google.protobuf.Struct"
                        , "google.protobuf.Timestamp"
                        , "google.protobuf.UInt32Value"
                        , "google.protobuf.UInt64Value"
                        , "google.protobuf.Value"
                        ]
        , test "every type a well-known message refers to is in the registry" <|
            \_ ->
                Registry.messages Registry.wellKnown
                    |> List.concatMap Message.fields
                    |> List.filter (\field -> not (resolves (Field.kind field)))
                    |> Expect.equal []
        , test "Value is a oneof of its six kinds, and Struct a map of Values" <|
            \_ ->
                ( Registry.message "google.protobuf.Value" Registry.wellKnown
                    |> Maybe.map (\value -> ( Message.oneofs value, List.map (\field -> ( Field.jsonName field, Field.oneof field )) (Message.fields value) ))
                , Registry.message "google.protobuf.Struct" Registry.wellKnown
                    |> Maybe.map (Message.fields >> List.map (\field -> ( Field.cardinality field, Field.kind field )))
                )
                    |> Expect.equal
                        ( Just
                            ( [ "kind" ]
                            , [ ( "nullValue", Just "kind" )
                              , ( "numberValue", Just "kind" )
                              , ( "stringValue", Just "kind" )
                              , ( "boolValue", Just "kind" )
                              , ( "structValue", Just "kind" )
                              , ( "listValue", Just "kind" )
                              ]
                            )
                        , Just [ ( CardinalityMap ScalarString, KindMessage "google.protobuf.Value" ) ]
                        )
        ]
