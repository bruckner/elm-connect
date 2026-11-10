module Proto.WellKnownTest exposing (suite)

import Dict
import Expect
import Json.Decode
import Json.Encode
import Proto.Any as Any
import Proto.Descriptors as Descriptors
import Proto.Duration as Duration
import Proto.Enum as Enum
import Proto.Field as Field exposing (Cardinality(..), Kind(..), Scalar(..))
import Proto.Json
import Proto.Message as Message exposing (Message)
import Proto.WellKnown as WellKnown
import Test exposing (Test, describe, test)
import Time


{-| The type name of a well-known message, and whether a value survives
packing and unpacking.
-}
check : Message a -> a -> ( String, Bool )
check message value =
    ( Message.typeName message
    , Any.unpack message (Any.pack message value) == Just value
    )


fieldsOf : String -> List Field.Descriptor
fieldsOf name =
    Descriptors.message name WellKnown.descriptors
        |> Maybe.map Message.fields
        |> Maybe.withDefault []


suite : Test
suite =
    describe "Proto.WellKnown"
        [ test "each is the well-known type it says, and a value survives an Any" <|
            \_ ->
                [ check WellKnown.empty ()
                , check WellKnown.timestamp (Time.millisToPosix 1500)
                , check WellKnown.duration (Duration.fromMilliseconds 1500)
                , check WellKnown.fieldMask [ "a.b" ]
                , check WellKnown.struct (Dict.fromList [ ( "k", Json.Encode.string "v" ) ])
                , check WellKnown.listValue [ Json.Encode.string "v" ]
                , check WellKnown.doubleValue 1.5
                , check WellKnown.floatValue 1.5
                , check WellKnown.int64Value "-7"
                , check WellKnown.int64ValueAsInt -7
                , check WellKnown.uint64Value "7"
                , check WellKnown.uint64ValueAsInt 7
                , check WellKnown.int32Value -7
                , check WellKnown.uint32Value 7
                , check WellKnown.boolValue True
                , check WellKnown.stringValue "hi"
                , check WellKnown.bytesValue "aGk="
                ]
                    |> Expect.equal
                        [ ( "google.protobuf.Empty", True )
                        , ( "google.protobuf.Timestamp", True )
                        , ( "google.protobuf.Duration", True )
                        , ( "google.protobuf.FieldMask", True )
                        , ( "google.protobuf.Struct", True )
                        , ( "google.protobuf.ListValue", True )
                        , ( "google.protobuf.DoubleValue", True )
                        , ( "google.protobuf.FloatValue", True )
                        , ( "google.protobuf.Int64Value", True )
                        , ( "google.protobuf.Int64Value", True )
                        , ( "google.protobuf.UInt64Value", True )
                        , ( "google.protobuf.UInt64Value", True )
                        , ( "google.protobuf.Int32Value", True )
                        , ( "google.protobuf.UInt32Value", True )
                        , ( "google.protobuf.BoolValue", True )
                        , ( "google.protobuf.StringValue", True )
                        , ( "google.protobuf.BytesValue", True )
                        ]
        , test "Value, and Any inside Any" <|
            \_ ->
                ( Message.typeName WellKnown.value
                , Any.unpack WellKnown.value (Any.pack WellKnown.value Json.Encode.null) |> Maybe.map (Json.Encode.encode 0)
                , Any.pack WellKnown.any (Any.pack WellKnown.boolValue True)
                    |> Any.unpack WellKnown.any
                    |> Maybe.andThen (Any.unpack WellKnown.boolValue)
                )
                    |> Expect.equal ( "google.protobuf.Value", Just "null", Just True )
        , test "FloatValue reads only a float's range, DoubleValue a double's" <|
            \_ ->
                let
                    holding name =
                        Json.Decode.decodeString Json.Decode.value ("{\"@type\":\"type.googleapis.com/google.protobuf." ++ name ++ "\",\"value\":1e300}")
                            |> Result.andThen (Json.Decode.decodeValue (Proto.Json.anyWith WellKnown.registry))
                            |> Result.toMaybe
                in
                ( holding "FloatValue" |> Maybe.andThen (Any.unpack WellKnown.floatValue)
                , holding "DoubleValue" |> Maybe.andThen (Any.unpack WellKnown.doubleValue)
                )
                    |> Expect.equal ( Nothing, Just 1.0e300 )
        , test "NullValue's typed value: its descriptor, name and number" <|
            \_ ->
                ( ( Enum.fullName (Enum.toDescriptor WellKnown.nullValue), Enum.toName WellKnown.nullValue () )
                , ( Enum.toNumber WellKnown.nullValue (), Enum.fromName WellKnown.nullValue "NULL_VALUE", Enum.fromNumber WellKnown.nullValue 0 )
                , Json.Encode.encode 0 (Enum.encode WellKnown.nullValue (Enum.default WellKnown.nullValue))
                )
                    |> Expect.equal ( ( "google.protobuf.NullValue", "" ), ( 0, Just (), Just () ), "null" )
        , test "the wire forms are the well-known types' own" <|
            \_ ->
                [ Any.pack WellKnown.empty ()
                , Any.pack WellKnown.timestamp (Time.millisToPosix 1500)
                , Any.pack WellKnown.duration (Duration.fromMilliseconds 1500)
                , Any.pack WellKnown.fieldMask [ "display_name", "author.email" ]
                , Any.pack WellKnown.int64ValueAsInt 7
                ]
                    |> List.filterMap (Any.toJson WellKnown.registry >> Result.toMaybe >> Maybe.map (Json.Encode.encode 0))
                    |> Expect.equal [ "{}", "\"1970-01-01T00:00:01.500Z\"", "\"1.500s\"", "\"displayName,author.email\"", "\"7\"" ]
        , test "the descriptors are protobuf's" <|
            \_ ->
                ( fieldsOf "google.protobuf.Timestamp" |> List.map (\field -> ( Field.name field, Field.number field, Field.kind field ))
                , fieldsOf "google.protobuf.FieldMask" |> List.map (\field -> ( Field.name field, Field.cardinality field ))
                , fieldsOf "google.protobuf.UInt64Value" |> List.map Field.kind
                )
                    |> Expect.equal
                        ( [ ( "seconds", 1, KindScalar ScalarInt64 ), ( "nanos", 2, KindScalar ScalarInt32 ) ]
                        , [ ( "paths", CardinalityRepeated ) ]
                        , [ KindScalar ScalarUint64 ]
                        )
        ]
