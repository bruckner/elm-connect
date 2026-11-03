module Proto.WellKnown exposing
    ( empty, emptyProto, timestamp, timestampProto, duration, durationProto
    , fieldMask, fieldMaskProto, any, anyProto
    , struct, structProto, value, valueProto, listValue, listValueProto, nullValue
    , doubleValue, doubleValueProto, floatValue, floatValueProto
    , int64Value, int64ValueProto, int64ValueAsInt, int64ValueAsIntProto
    , uint64Value, uint64ValueProto, uint64ValueAsInt, uint64ValueAsIntProto
    , int32Value, int32ValueProto, uint32Value, uint32ValueProto
    , boolValue, boolValueProto, stringValue, stringValueProto, bytesValue, bytesValueProto
    )

{-| The `google.protobuf` types elm-connect maps, as
[`Message`](Proto-Message#Message) values, each in the Elm form generated code
gives the type: one with proto3 JSON codecs, and one with protobuf binary
codecs, named with `Proto` at the end. Pack and unpack an `Any` of one with
them.

@docs empty, emptyProto, timestamp, timestampProto, duration, durationProto
@docs fieldMask, fieldMaskProto, any, anyProto


# JSON

@docs struct, structProto, value, valueProto, listValue, listValueProto, nullValue


# Wrappers

A wrapper's Elm form is its scalar; a field of one is a `Maybe` of it. The
64-bit wrappers come in both forms the `int64` option chooses between.

@docs doubleValue, doubleValueProto, floatValue, floatValueProto
@docs int64Value, int64ValueProto, int64ValueAsInt, int64ValueAsIntProto
@docs uint64Value, uint64ValueProto, uint64ValueAsInt, uint64ValueAsIntProto
@docs int32Value, int32ValueProto, uint32Value, uint32ValueProto
@docs boolValue, boolValueProto, stringValue, stringValueProto, bytesValue, bytesValueProto

-}

import Dict exposing (Dict)
import Json.Decode
import Json.Encode
import Proto.Any exposing (Any)
import Proto.Binary
import Proto.Codec exposing (Json, Proto)
import Proto.Duration exposing (Duration)
import Proto.Enum exposing (Enum, enum)
import Proto.Internal.WellKnown as Descriptors
import Proto.Json
import Proto.Message exposing (Message, initJson, initProto)
import Time


{-| `google.protobuf.Empty`: `()`, written `{}`.
-}
empty : Message Json ()
empty =
    initJson "google.protobuf.Empty" Proto.Json.encodeEmpty Proto.Json.empty


{-| [`empty`](#empty) with protobuf binary codecs.
-}
emptyProto : Message Proto ()
emptyProto =
    initProto "google.protobuf.Empty" (Proto.Binary.messageEncoder Proto.Binary.empty) (Proto.Binary.messageDecoder Proto.Binary.empty)


{-| `google.protobuf.Timestamp`: a `Time.Posix`, written in RFC 3339.
-}
timestamp : Message Json Time.Posix
timestamp =
    initJson "google.protobuf.Timestamp" Proto.Json.encodeTimestamp Proto.Json.timestamp


{-| [`timestamp`](#timestamp) with protobuf binary codecs.
-}
timestampProto : Message Proto Time.Posix
timestampProto =
    initProto "google.protobuf.Timestamp" (Proto.Binary.messageEncoder Proto.Binary.timestamp) (Proto.Binary.messageDecoder Proto.Binary.timestamp)


{-| `google.protobuf.Duration`, written as seconds (`"1.5s"`).
-}
duration : Message Json Duration
duration =
    initJson "google.protobuf.Duration" Proto.Json.encodeDuration Proto.Json.duration


{-| [`duration`](#duration) with protobuf binary codecs.
-}
durationProto : Message Proto Duration
durationProto =
    initProto "google.protobuf.Duration" (Proto.Binary.messageEncoder Proto.Binary.duration) (Proto.Binary.messageDecoder Proto.Binary.duration)


{-| `google.protobuf.FieldMask`: its paths, written comma-separated.
-}
fieldMask : Message Json (List String)
fieldMask =
    initJson "google.protobuf.FieldMask" Proto.Json.encodeFieldMask Proto.Json.fieldMask


{-| [`fieldMask`](#fieldMask) with protobuf binary codecs.
-}
fieldMaskProto : Message Proto (List String)
fieldMaskProto =
    initProto "google.protobuf.FieldMask" (Proto.Binary.messageEncoder Proto.Binary.fieldMask) (Proto.Binary.messageDecoder Proto.Binary.fieldMask)


{-| `google.protobuf.Any`, a [`Proto.Any.Any`](Proto-Any#Any).
-}
any : Message Json (Any Json)
any =
    initJson "google.protobuf.Any" Proto.Json.encodeAny Proto.Json.any


{-| [`any`](#any) with protobuf binary codecs.
-}
anyProto : Message Proto (Any Proto)
anyProto =
    initProto "google.protobuf.Any" (Proto.Binary.messageEncoder Proto.Binary.any) (Proto.Binary.messageDecoder Proto.Binary.any)


{-| `google.protobuf.Struct`: a JSON object.
-}
struct : Message Json (Dict String Json.Encode.Value)
struct =
    initJson "google.protobuf.Struct" Proto.Json.encodeStruct Proto.Json.struct


{-| [`struct`](#struct) with protobuf binary codecs.
-}
structProto : Message Proto (Dict String Json.Encode.Value)
structProto =
    initProto "google.protobuf.Struct" (Proto.Binary.messageEncoder Proto.Binary.struct) (Proto.Binary.messageDecoder Proto.Binary.struct)


{-| `google.protobuf.Value`: any JSON.
-}
value : Message Json Json.Encode.Value
value =
    initJson "google.protobuf.Value" identity Json.Decode.value


{-| [`value`](#value) with protobuf binary codecs.
-}
valueProto : Message Proto Json.Encode.Value
valueProto =
    initProto "google.protobuf.Value" (Proto.Binary.messageEncoder Proto.Binary.value) (Proto.Binary.messageDecoder Proto.Binary.value)


{-| `google.protobuf.ListValue`: a JSON array.
-}
listValue : Message Json (List Json.Encode.Value)
listValue =
    initJson "google.protobuf.ListValue" Proto.Json.encodeListValue Proto.Json.listValue


{-| [`listValue`](#listValue) with protobuf binary codecs.
-}
listValueProto : Message Proto (List Json.Encode.Value)
listValueProto =
    initProto "google.protobuf.ListValue" (Proto.Binary.messageEncoder Proto.Binary.listValue) (Proto.Binary.messageDecoder Proto.Binary.listValue)


{-| `google.protobuf.DoubleValue`.
-}
doubleValue : Message Json Float
doubleValue =
    initJson "google.protobuf.DoubleValue" Proto.Json.encodeFloat Proto.Json.float


{-| [`doubleValue`](#doubleValue) with protobuf binary codecs.
-}
doubleValueProto : Message Proto Float
doubleValueProto =
    initProto "google.protobuf.DoubleValue" (Proto.Binary.messageEncoder Proto.Binary.doubleValue) (Proto.Binary.messageDecoder Proto.Binary.doubleValue)


{-| `google.protobuf.FloatValue`.
-}
floatValue : Message Json Float
floatValue =
    initJson "google.protobuf.FloatValue" Proto.Json.encodeFloat Proto.Json.float32


{-| [`floatValue`](#floatValue) with protobuf binary codecs.
-}
floatValueProto : Message Proto Float
floatValueProto =
    initProto "google.protobuf.FloatValue" (Proto.Binary.messageEncoder Proto.Binary.floatValue) (Proto.Binary.messageDecoder Proto.Binary.floatValue)


{-| `google.protobuf.Int64Value`, its decimal string.
-}
int64Value : Message Json String
int64Value =
    initJson "google.protobuf.Int64Value" Proto.Json.encodeInt64 Proto.Json.int64


{-| [`int64Value`](#int64Value) with protobuf binary codecs.
-}
int64ValueProto : Message Proto String
int64ValueProto =
    initProto "google.protobuf.Int64Value" (Proto.Binary.messageEncoder Proto.Binary.int64Value) (Proto.Binary.messageDecoder Proto.Binary.int64Value)


{-| `google.protobuf.Int64Value` as an `Int`, under the `int64=int` option.
-}
int64ValueAsInt : Message Json Int
int64ValueAsInt =
    initJson "google.protobuf.Int64Value" Proto.Json.encodeInt64AsInt Proto.Json.int64AsInt


{-| [`int64ValueAsInt`](#int64ValueAsInt) with protobuf binary codecs.
-}
int64ValueAsIntProto : Message Proto Int
int64ValueAsIntProto =
    initProto "google.protobuf.Int64Value" (Proto.Binary.messageEncoder Proto.Binary.int64ValueAsInt) (Proto.Binary.messageDecoder Proto.Binary.int64ValueAsInt)


{-| `google.protobuf.UInt64Value`, its decimal string.
-}
uint64Value : Message Json String
uint64Value =
    initJson "google.protobuf.UInt64Value" Proto.Json.encodeInt64 Proto.Json.uint64


{-| [`uint64Value`](#uint64Value) with protobuf binary codecs.
-}
uint64ValueProto : Message Proto String
uint64ValueProto =
    initProto "google.protobuf.UInt64Value" (Proto.Binary.messageEncoder Proto.Binary.uint64Value) (Proto.Binary.messageDecoder Proto.Binary.uint64Value)


{-| `google.protobuf.UInt64Value` as an `Int`, under the `int64=int` option.
-}
uint64ValueAsInt : Message Json Int
uint64ValueAsInt =
    initJson "google.protobuf.UInt64Value" Proto.Json.encodeInt64AsInt Proto.Json.uint64AsInt


{-| [`uint64ValueAsInt`](#uint64ValueAsInt) with protobuf binary codecs.
-}
uint64ValueAsIntProto : Message Proto Int
uint64ValueAsIntProto =
    initProto "google.protobuf.UInt64Value" (Proto.Binary.messageEncoder Proto.Binary.uint64ValueAsInt) (Proto.Binary.messageDecoder Proto.Binary.uint64ValueAsInt)


{-| `google.protobuf.Int32Value`.
-}
int32Value : Message Json Int
int32Value =
    initJson "google.protobuf.Int32Value" Json.Encode.int Proto.Json.int32


{-| [`int32Value`](#int32Value) with protobuf binary codecs.
-}
int32ValueProto : Message Proto Int
int32ValueProto =
    initProto "google.protobuf.Int32Value" (Proto.Binary.messageEncoder Proto.Binary.int32Value) (Proto.Binary.messageDecoder Proto.Binary.int32Value)


{-| `google.protobuf.UInt32Value`.
-}
uint32Value : Message Json Int
uint32Value =
    initJson "google.protobuf.UInt32Value" Json.Encode.int Proto.Json.uint32


{-| [`uint32Value`](#uint32Value) with protobuf binary codecs.
-}
uint32ValueProto : Message Proto Int
uint32ValueProto =
    initProto "google.protobuf.UInt32Value" (Proto.Binary.messageEncoder Proto.Binary.uint32Value) (Proto.Binary.messageDecoder Proto.Binary.uint32Value)


{-| `google.protobuf.BoolValue`.
-}
boolValue : Message Json Bool
boolValue =
    initJson "google.protobuf.BoolValue" Json.Encode.bool Json.Decode.bool


{-| [`boolValue`](#boolValue) with protobuf binary codecs.
-}
boolValueProto : Message Proto Bool
boolValueProto =
    initProto "google.protobuf.BoolValue" (Proto.Binary.messageEncoder Proto.Binary.boolValue) (Proto.Binary.messageDecoder Proto.Binary.boolValue)


{-| `google.protobuf.StringValue`.
-}
stringValue : Message Json String
stringValue =
    initJson "google.protobuf.StringValue" Json.Encode.string Proto.Json.string


{-| [`stringValue`](#stringValue) with protobuf binary codecs.
-}
stringValueProto : Message Proto String
stringValueProto =
    initProto "google.protobuf.StringValue" (Proto.Binary.messageEncoder Proto.Binary.stringValue) (Proto.Binary.messageDecoder Proto.Binary.stringValue)


{-| `google.protobuf.BytesValue`, its base64 text.
-}
bytesValue : Message Json String
bytesValue =
    initJson "google.protobuf.BytesValue" Proto.Json.encodeBytes Proto.Json.bytes


{-| [`bytesValue`](#bytesValue) with protobuf binary codecs.
-}
bytesValueProto : Message Proto String
bytesValueProto =
    initProto "google.protobuf.BytesValue" (Proto.Binary.messageEncoder Proto.Binary.bytesValue) (Proto.Binary.messageDecoder Proto.Binary.bytesValue)


{-| The enum `google.protobuf.NullValue`: `()`, its one value `NULL_VALUE`,
written `null`. Since its encoder writes no string,
[`Proto.Enum.toName`](Proto-Enum#toName) gives `""` for it; `fromName` and
`fromNumber` read `"NULL_VALUE"` and `0`. Generated descriptors of a field of it
name its descriptor through this value.
-}
nullValue : Enum ()
nullValue =
    enum Proto.Json.encodeNullValue Proto.Json.nullValue () Descriptors.nullValue
