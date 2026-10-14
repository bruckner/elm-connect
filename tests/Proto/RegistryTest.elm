module Proto.RegistryTest exposing (suite)

import Expect
import Proto.Descriptor exposing (Cardinality(..), EnumDescriptor, Kind(..), MessageDescriptor, Scalar(..))
import Proto.Registry as Registry
import Test exposing (Test, describe, test)


note : String -> MessageDescriptor
note title =
    { typeName = "notes.v1.Note"
    , fields = [ { name = title, jsonName = title, number = 1, cardinality = Singular, kind = Scalar String, oneof = Nothing } ]
    , oneofs = []
    }


visibility : EnumDescriptor
visibility =
    { typeName = "notes.v1.Visibility"
    , values = [ { name = "VISIBILITY_UNSPECIFIED", number = 0 } ]
    }


fieldName : Maybe MessageDescriptor -> Maybe String
fieldName =
    Maybe.andThen (.fields >> List.head) >> Maybe.map .name


resolves : Kind -> Bool
resolves kind =
    case kind of
        Message name ->
            Registry.message name Registry.wellKnown /= Nothing

        Enum name ->
            Registry.enum name Registry.wellKnown /= Nothing

        Scalar _ ->
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
                ( Registry.message "notes.v1.Note" registry |> Maybe.map .typeName
                , Registry.enum "notes.v1.Visibility" registry |> Maybe.map .typeName
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
                    |> Expect.equal ( 17, 2 )
        , test "the well-known types" <|
            \_ ->
                Registry.messages Registry.wellKnown
                    |> List.map .typeName
                    |> Expect.equal
                        [ "google.protobuf.BoolValue"
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
                    |> List.concatMap .fields
                    |> List.filter (\field -> not (resolves field.kind))
                    |> Expect.equal []
        , test "Value is a oneof of its six kinds, and Struct a map of Values" <|
            \_ ->
                ( Registry.message "google.protobuf.Value" Registry.wellKnown
                    |> Maybe.map (\value -> ( value.oneofs, List.map (\field -> ( field.jsonName, field.oneof )) value.fields ))
                , Registry.message "google.protobuf.Struct" Registry.wellKnown
                    |> Maybe.map (.fields >> List.map (\field -> ( field.cardinality, field.kind )))
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
                        , Just [ ( Map String, Message "google.protobuf.Value" ) ]
                        )
        ]
