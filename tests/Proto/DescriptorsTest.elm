module Proto.DescriptorsTest exposing (suite)

import Expect
import Proto.Descriptors as Descriptors
import Proto.Enum as Enum
import Proto.EnumValue as EnumValue
import Proto.Field as Field exposing (Cardinality(..), Kind(..), Scalar(..))
import Proto.Message as Message
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
            Descriptors.message name Descriptors.wellKnown /= Nothing

        KindEnum descriptor ->
            Descriptors.enum (Enum.typeName descriptor) Descriptors.wellKnown /= Nothing

        KindScalar _ ->
            True


suite : Test
suite =
    describe "Proto.Descriptors"
        [ test "a message and an enum by full name" <|
            \_ ->
                let
                    descriptors =
                        Descriptors.fromDescriptors [ note "title" ] [ visibility ]
                in
                ( Descriptors.message "notes.v1.Note" descriptors |> Maybe.map Message.fullName
                , Descriptors.enum "notes.v1.Visibility" descriptors |> Maybe.map Enum.typeName
                , ( Descriptors.message "notes.v1.Visibility" descriptors, Descriptors.enum "notes.v1.Note" descriptors )
                )
                    |> Expect.equal ( Just "notes.v1.Note", Just "notes.v1.Visibility", ( Nothing, Nothing ) )
        , test "empty has nothing" <|
            \_ ->
                ( Descriptors.messages Descriptors.empty, Descriptors.enums Descriptors.empty )
                    |> Expect.equal ( [], [] )
        , test "of two descriptors with one name, the first is kept" <|
            \_ ->
                Descriptors.fromDescriptors [ note "first", note "second" ] []
                    |> Descriptors.message "notes.v1.Note"
                    |> fieldName
                    |> Expect.equal (Just "first")
        , test "a union keeps the left one's" <|
            \_ ->
                Descriptors.union (Descriptors.fromDescriptors [ note "left" ] []) (Descriptors.fromDescriptors [ note "right" ] [ visibility ])
                    |> (\descriptors -> ( Descriptors.message "notes.v1.Note" descriptors |> fieldName, List.length (Descriptors.enums descriptors) ))
                    |> Expect.equal ( Just "left", 1 )
        , test "a union of a diamond holds each type once" <|
            \_ ->
                let
                    shared =
                        Descriptors.fromDescriptors [ note "title" ] [ visibility ]
                in
                Descriptors.union (Descriptors.union shared Descriptors.wellKnown) (Descriptors.union shared Descriptors.wellKnown)
                    |> (\descriptors -> ( List.length (Descriptors.messages descriptors), List.length (Descriptors.enums descriptors) ))
                    |> Expect.equal ( 18, 2 )
        , test "the well-known types" <|
            \_ ->
                Descriptors.messages Descriptors.wellKnown
                    |> List.map Message.fullName
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
        , test "every type a well-known message refers to is among them" <|
            \_ ->
                Descriptors.messages Descriptors.wellKnown
                    |> List.concatMap Message.fields
                    |> List.filter (\field -> not (resolves (Field.kind field)))
                    |> Expect.equal []
        , test "Value is a oneof of its six kinds, and Struct a map of Values" <|
            \_ ->
                ( Descriptors.message "google.protobuf.Value" Descriptors.wellKnown
                    |> Maybe.map (\value -> ( Message.oneofs value, List.map (\field -> ( Field.jsonName field, Field.oneof field )) (Message.fields value) ))
                , Descriptors.message "google.protobuf.Struct" Descriptors.wellKnown
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
