module Proto.WellKnownTest exposing (suite)

import Dict
import Expect
import Json.Decode
import Json.Encode
import Proto.Any as Any
import Proto.Codec exposing (Json, Proto)
import Proto.Descriptors as Descriptors
import Proto.Duration as Duration
import Proto.Enum as Enum
import Proto.Field as Field exposing (Cardinality(..), Kind(..), Scalar(..))
import Proto.Json
import Proto.Message as Message exposing (Message)
import Proto.WellKnown as WellKnown
import Test exposing (Test, describe, test)
import Time


{-| The type name of a well-known message in each world, and whether a value
survives packing and unpacking in each.
-}
check : Message Json a -> Message Proto a -> a -> ( String, Bool )
check json proto value =
    ( if Message.typeName json == Message.typeName proto then
        Message.typeName json

      else
        "two names"
    , ( Any.unpackJson json (Any.packJson json value), Any.unpack proto (Any.pack proto value) ) == ( Just value, Just value )
    )


fieldsOf : String -> List Field.Descriptor
fieldsOf name =
    Descriptors.message name Descriptors.wellKnown
        |> Maybe.map Message.fields
        |> Maybe.withDefault []


suite : Test
suite =
    describe "Proto.WellKnown"
        [ test "each is the well-known type it says in both worlds, and a value survives an Any" <|
            \_ ->
                [ check WellKnown.empty WellKnown.emptyProto ()
                , check WellKnown.timestamp WellKnown.timestampProto (Time.millisToPosix 1500)
                , check WellKnown.duration WellKnown.durationProto (Duration.fromMilliseconds 1500)
                , check WellKnown.fieldMask WellKnown.fieldMaskProto [ "a.b" ]
                , check WellKnown.struct WellKnown.structProto (Dict.fromList [ ( "k", Json.Encode.string "v" ) ])
                , check WellKnown.listValue WellKnown.listValueProto [ Json.Encode.string "v" ]
                , check WellKnown.doubleValue WellKnown.doubleValueProto 1.5
                , check WellKnown.floatValue WellKnown.floatValueProto 1.5
                , check WellKnown.int64Value WellKnown.int64ValueProto "-7"
                , check WellKnown.int64ValueAsInt WellKnown.int64ValueAsIntProto -7
                , check WellKnown.uint64Value WellKnown.uint64ValueProto "7"
                , check WellKnown.uint64ValueAsInt WellKnown.uint64ValueAsIntProto 7
                , check WellKnown.int32Value WellKnown.int32ValueProto -7
                , check WellKnown.uint32Value WellKnown.uint32ValueProto 7
                , check WellKnown.boolValue WellKnown.boolValueProto True
                , check WellKnown.stringValue WellKnown.stringValueProto "hi"
                , check WellKnown.bytesValue WellKnown.bytesValueProto "aGk="
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
        , test "Value, and Any inside Any, in both worlds" <|
            \_ ->
                ( ( Message.typeName WellKnown.value, Message.typeName WellKnown.valueProto )
                , ( Any.unpackJson WellKnown.value (Any.packJson WellKnown.value Json.Encode.null) |> Maybe.map (Json.Encode.encode 0)
                  , Any.unpack WellKnown.valueProto (Any.pack WellKnown.valueProto Json.Encode.null) |> Maybe.map (Json.Encode.encode 0)
                  )
                , ( Any.packJson WellKnown.any (Any.packJson WellKnown.boolValue True)
                        |> Any.unpackJson WellKnown.any
                        |> Maybe.andThen (Any.unpackJson WellKnown.boolValue)
                  , Any.pack WellKnown.anyProto (Any.pack WellKnown.boolValueProto True)
                        |> Any.unpack WellKnown.anyProto
                        |> Maybe.andThen (Any.unpack WellKnown.boolValueProto)
                  )
                )
                    |> Expect.equal ( ( "google.protobuf.Value", "google.protobuf.Value" ), ( Just "null", Just "null" ), ( Just True, Just True ) )
        , test "FloatValue reads only a float's range, DoubleValue a double's" <|
            \_ ->
                let
                    holding name =
                        Json.Decode.decodeString Json.Decode.value ("{\"@type\":\"type.googleapis.com/google.protobuf." ++ name ++ "\",\"value\":1e300}")
                            |> Result.andThen (Json.Decode.decodeValue Proto.Json.any)
                            |> Result.toMaybe
                in
                ( holding "FloatValue" |> Maybe.andThen (Any.unpackJson WellKnown.floatValue)
                , holding "DoubleValue" |> Maybe.andThen (Any.unpackJson WellKnown.doubleValue)
                )
                    |> Expect.equal ( Nothing, Just 1.0e300 )
        , test "NullValue's typed value: its descriptor, name and number" <|
            \_ ->
                ( ( Enum.typeName (Enum.toDescriptor WellKnown.nullValue), Enum.toName WellKnown.nullValue () )
                , ( Enum.toNumber WellKnown.nullValue (), Enum.fromName WellKnown.nullValue "NULL_VALUE", Enum.fromNumber WellKnown.nullValue 0 )
                , Json.Encode.encode 0 (Enum.encode WellKnown.nullValue (Enum.default WellKnown.nullValue))
                )
                    |> Expect.equal ( ( "google.protobuf.NullValue", "" ), ( 0, Just (), Just () ), "null" )
        , test "the wire forms are the well-known types' own" <|
            \_ ->
                [ Any.packJson WellKnown.empty ()
                , Any.packJson WellKnown.timestamp (Time.millisToPosix 1500)
                , Any.packJson WellKnown.duration (Duration.fromMilliseconds 1500)
                , Any.packJson WellKnown.fieldMask [ "display_name", "author.email" ]
                , Any.packJson WellKnown.int64ValueAsInt 7
                ]
                    |> List.map (Any.json >> Json.Encode.encode 0)
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
