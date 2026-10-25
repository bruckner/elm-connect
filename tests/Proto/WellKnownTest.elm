module Proto.WellKnownTest exposing (suite)

import Dict
import Expect
import Json.Decode
import Json.Encode
import Proto.Duration as Duration
import Proto.Enum as Enum
import Proto.Field as Field exposing (Cardinality(..), Kind(..), Scalar(..))
import Proto.Message as Message exposing (Message)
import Proto.WellKnown as WellKnown
import Test exposing (Test, describe, test)
import Time


{-| The type name of a well-known message, and whether its default survives a
round trip through its JSON.
-}
check : Message a -> ( String, Bool )
check message =
    ( Message.typeName (Message.toDescriptor message)
    , Json.Decode.decodeValue (Message.decoder message) (Message.encode message (Message.default message)) == Ok (Message.default message)
    )


fieldsOf : Message a -> List Field.Descriptor
fieldsOf =
    Message.toDescriptor >> Message.fields


suite : Test
suite =
    describe "Proto.WellKnown"
        [ test "each is the well-known type it says, and its default round-trips" <|
            \_ ->
                [ check WellKnown.empty
                , check WellKnown.timestamp
                , check WellKnown.duration
                , check WellKnown.fieldMask
                , check WellKnown.any
                , check WellKnown.struct
                , check WellKnown.listValue
                , check WellKnown.doubleValue
                , check WellKnown.floatValue
                , check WellKnown.int64Value
                , check WellKnown.int64ValueAsInt
                , check WellKnown.uint64Value
                , check WellKnown.uint64ValueAsInt
                , check WellKnown.int32Value
                , check WellKnown.uint32Value
                , check WellKnown.boolValue
                , check WellKnown.stringValue
                , check WellKnown.bytesValue
                ]
                    |> Expect.equal
                        [ ( "google.protobuf.Empty", True )
                        , ( "google.protobuf.Timestamp", True )
                        , ( "google.protobuf.Duration", True )
                        , ( "google.protobuf.FieldMask", True )
                        , ( "google.protobuf.Any", True )
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
        , test "FloatValue reads only a float's range, DoubleValue a double's" <|
            \_ ->
                ( Json.Decode.decodeString (Message.decoder WellKnown.floatValue) "1e300" |> Result.toMaybe
                , Json.Decode.decodeString (Message.decoder WellKnown.doubleValue) "1e300" |> Result.toMaybe
                )
                    |> Expect.equal ( Nothing, Just 1.0e300 )
        , test "NullValue's typed value: its descriptor, name and number" <|
            \_ ->
                ( ( Enum.typeName (Enum.toDescriptor WellKnown.nullValue), Enum.toName WellKnown.nullValue () )
                , ( Enum.toNumber WellKnown.nullValue (), Enum.fromName WellKnown.nullValue "NULL_VALUE", Enum.fromNumber WellKnown.nullValue 0 )
                , Json.Encode.encode 0 (Enum.encode WellKnown.nullValue (Enum.default WellKnown.nullValue))
                )
                    |> Expect.equal ( ( "google.protobuf.NullValue", "" ), ( 0, Just (), Just () ), "null" )
        , test "Value's default is null" <|
            \_ ->
                ( Message.typeName (Message.toDescriptor WellKnown.value), Json.Encode.encode 0 (Message.default WellKnown.value) )
                    |> Expect.equal ( "google.protobuf.Value", "null" )
        , test "the defaults are the zero values" <|
            \_ ->
                ( ( Time.posixToMillis (Message.default WellKnown.timestamp), Duration.toMilliseconds (Message.default WellKnown.duration) )
                , ( Message.default WellKnown.int64Value, Dict.isEmpty (Message.default WellKnown.struct) )
                )
                    |> Expect.equal ( ( 0, 0 ), ( "0", True ) )
        , test "the wire forms are the well-known types' own" <|
            \_ ->
                [ Message.encode WellKnown.empty ()
                , Message.encode WellKnown.timestamp (Time.millisToPosix 1500)
                , Message.encode WellKnown.duration (Duration.fromMilliseconds 1500)
                , Message.encode WellKnown.fieldMask [ "display_name", "author.email" ]
                , Message.encode WellKnown.int64ValueAsInt 7
                ]
                    |> List.map (Json.Encode.encode 0)
                    |> Expect.equal [ "{}", "\"1970-01-01T00:00:01.500Z\"", "\"1.500s\"", "\"displayName,author.email\"", "\"7\"" ]
        , test "the descriptors are protobuf's" <|
            \_ ->
                ( fieldsOf WellKnown.timestamp |> List.map (\field -> ( Field.name field, Field.number field, Field.kind field ))
                , fieldsOf WellKnown.fieldMask |> List.map (\field -> ( Field.name field, Field.cardinality field ))
                , fieldsOf WellKnown.uint64ValueAsInt |> List.map Field.kind
                )
                    |> Expect.equal
                        ( [ ( "seconds", 1, KindScalar ScalarInt64 ), ( "nanos", 2, KindScalar ScalarInt32 ) ]
                        , [ ( "paths", CardinalityRepeated ) ]
                        , [ KindScalar ScalarUint64 ]
                        )
        , test "a type URL names the type" <|
            \_ ->
                Message.typeUrl (Message.toDescriptor WellKnown.duration)
                    |> Expect.equal "type.googleapis.com/google.protobuf.Duration"
        ]
