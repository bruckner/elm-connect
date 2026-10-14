module Proto.WellKnownTest exposing (suite)

import Dict
import Expect
import Json.Decode
import Json.Encode
import Proto.Descriptor exposing (Cardinality(..), Kind(..), Scalar(..))
import Proto.Duration as Duration
import Proto.Message as Message exposing (Message)
import Proto.WellKnown as WellKnown
import Test exposing (Test, describe, test)
import Time


{-| The type name of a well-known message, and whether its default survives a
round trip through its JSON.
-}
check : Message a -> ( String, Bool )
check message =
    ( Message.typeName message
    , Json.Decode.decodeValue message.jsonDecoder (message.encodeJson message.default) == Ok message.default
    )


suite : Test
suite =
    describe "Proto.WellKnown"
        [ test "each is the well-known type it says, and its default round-trips" <|
            \_ ->
                [ check WellKnown.empty
                , check WellKnown.timestamp
                , check WellKnown.duration
                , check WellKnown.fieldMask
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
        , test "Value's default is null" <|
            \_ ->
                ( Message.typeName WellKnown.value, Json.Encode.encode 0 WellKnown.value.default )
                    |> Expect.equal ( "google.protobuf.Value", "null" )
        , test "the defaults are the zero values" <|
            \_ ->
                ( ( Time.posixToMillis WellKnown.timestamp.default, Duration.milliseconds WellKnown.duration.default )
                , ( WellKnown.int64Value.default, Dict.isEmpty WellKnown.struct.default )
                )
                    |> Expect.equal ( ( 0, 0 ), ( "0", True ) )
        , test "the wire forms are the well-known types' own" <|
            \_ ->
                [ WellKnown.empty.encodeJson ()
                , WellKnown.timestamp.encodeJson (Time.millisToPosix 1500)
                , WellKnown.duration.encodeJson (Duration.fromMilliseconds 1500)
                , WellKnown.fieldMask.encodeJson [ "display_name", "author.email" ]
                , WellKnown.int64ValueAsInt.encodeJson 7
                ]
                    |> List.map (Json.Encode.encode 0)
                    |> Expect.equal [ "{}", "\"1970-01-01T00:00:01.500Z\"", "\"1.500s\"", "\"displayName,author.email\"", "\"7\"" ]
        , test "the descriptors are protobuf's" <|
            \_ ->
                ( WellKnown.timestamp.descriptor.fields |> List.map (\field -> ( field.name, field.number, field.kind ))
                , WellKnown.fieldMask.descriptor.fields |> List.map (\field -> ( field.name, field.cardinality ))
                , WellKnown.uint64ValueAsInt.descriptor.fields |> List.map .kind
                )
                    |> Expect.equal
                        ( [ ( "seconds", 1, Scalar Int64 ), ( "nanos", 2, Scalar Int32 ) ]
                        , [ ( "paths", Repeated ) ]
                        , [ Scalar Uint64 ]
                        )
        , test "a type URL names the type" <|
            \_ ->
                Message.typeUrl WellKnown.duration
                    |> Expect.equal "type.googleapis.com/google.protobuf.Duration"
        ]
