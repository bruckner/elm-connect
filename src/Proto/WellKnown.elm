module Proto.WellKnown exposing
    ( empty, timestamp, duration
    , fieldMask, any
    , struct, value, listValue, nullValue
    , doubleValue, floatValue
    , int64Value, int64ValueAsInt
    , uint64Value, uint64ValueAsInt
    , int32Value, uint32Value
    , boolValue, stringValue, bytesValue
    )

{-| The `google.protobuf` types elm-connect maps, as
[`Message`](Proto-Message#Message) values, each in the Elm form generated code
gives the type, with both its codecs. Pack and unpack an `Any` of one with
them.

@docs empty, timestamp, duration
@docs fieldMask, any


# JSON

@docs struct, value, listValue, nullValue


# Wrappers

A wrapper's Elm form is its scalar; a field of one is a `Maybe` of it. The
64-bit wrappers come in both forms the `int64` option chooses between.

@docs doubleValue, floatValue
@docs int64Value, int64ValueAsInt
@docs uint64Value, uint64ValueAsInt
@docs int32Value, uint32Value
@docs boolValue, stringValue, bytesValue

-}

import Dict exposing (Dict)
import Json.Decode
import Json.Encode
import Proto.Any exposing (Any)
import Proto.Binary
import Proto.Duration exposing (Duration)
import Proto.Enum exposing (Enum, enum)
import Proto.Internal.WellKnown as Descriptors
import Proto.Json
import Proto.Message exposing (Message, init, initWith)
import Time


{-| `google.protobuf.Empty`: `()`, written `{}`.
-}
empty : Message ()
empty =
    init "google.protobuf.Empty" Proto.Json.encodeEmpty Proto.Json.empty (Proto.Binary.messageEncoder Proto.Binary.empty) (Proto.Binary.messageDecoder Proto.Binary.empty)


{-| `google.protobuf.Timestamp`: a `Time.Posix`, written in RFC 3339.
-}
timestamp : Message Time.Posix
timestamp =
    init "google.protobuf.Timestamp" Proto.Json.encodeTimestamp Proto.Json.timestamp (Proto.Binary.messageEncoder Proto.Binary.timestamp) (Proto.Binary.messageDecoder Proto.Binary.timestamp)


{-| `google.protobuf.Duration`, written as seconds (`"1.5s"`).
-}
duration : Message Duration
duration =
    init "google.protobuf.Duration" Proto.Json.encodeDuration Proto.Json.duration (Proto.Binary.messageEncoder Proto.Binary.duration) (Proto.Binary.messageDecoder Proto.Binary.duration)


{-| `google.protobuf.FieldMask`: its paths, written comma-separated.
-}
fieldMask : Message (List String)
fieldMask =
    init "google.protobuf.FieldMask" Proto.Json.encodeFieldMask Proto.Json.fieldMask (Proto.Binary.messageEncoder Proto.Binary.fieldMask) (Proto.Binary.messageDecoder Proto.Binary.fieldMask)


{-| `google.protobuf.Any`, a [`Proto.Any.Any`](Proto-Any#Any).
-}
any : Message Any
any =
    initWith "google.protobuf.Any" Proto.Json.encodeAnyWith Proto.Json.anyWith (Proto.Binary.messageEncoder Proto.Binary.any) (Proto.Binary.messageDecoder Proto.Binary.any)


{-| `google.protobuf.Struct`: a JSON object.
-}
struct : Message (Dict String Json.Encode.Value)
struct =
    init "google.protobuf.Struct" Proto.Json.encodeStruct Proto.Json.struct (Proto.Binary.messageEncoder Proto.Binary.struct) (Proto.Binary.messageDecoder Proto.Binary.struct)


{-| `google.protobuf.Value`: any JSON.
-}
value : Message Json.Encode.Value
value =
    init "google.protobuf.Value" identity Json.Decode.value (Proto.Binary.messageEncoder Proto.Binary.value) (Proto.Binary.messageDecoder Proto.Binary.value)


{-| `google.protobuf.ListValue`: a JSON array.
-}
listValue : Message (List Json.Encode.Value)
listValue =
    init "google.protobuf.ListValue" Proto.Json.encodeListValue Proto.Json.listValue (Proto.Binary.messageEncoder Proto.Binary.listValue) (Proto.Binary.messageDecoder Proto.Binary.listValue)


{-| `google.protobuf.DoubleValue`.
-}
doubleValue : Message Float
doubleValue =
    init "google.protobuf.DoubleValue" Proto.Json.encodeFloat Proto.Json.float (Proto.Binary.messageEncoder Proto.Binary.doubleValue) (Proto.Binary.messageDecoder Proto.Binary.doubleValue)


{-| `google.protobuf.FloatValue`.
-}
floatValue : Message Float
floatValue =
    init "google.protobuf.FloatValue" Proto.Json.encodeFloat Proto.Json.float32 (Proto.Binary.messageEncoder Proto.Binary.floatValue) (Proto.Binary.messageDecoder Proto.Binary.floatValue)


{-| `google.protobuf.Int64Value`, its decimal string.
-}
int64Value : Message String
int64Value =
    init "google.protobuf.Int64Value" Proto.Json.encodeInt64 Proto.Json.int64 (Proto.Binary.messageEncoder Proto.Binary.int64Value) (Proto.Binary.messageDecoder Proto.Binary.int64Value)


{-| `google.protobuf.Int64Value` as an `Int`, under the `int64=int` option.
-}
int64ValueAsInt : Message Int
int64ValueAsInt =
    init "google.protobuf.Int64Value" Proto.Json.encodeInt64AsInt Proto.Json.int64AsInt (Proto.Binary.messageEncoder Proto.Binary.int64ValueAsInt) (Proto.Binary.messageDecoder Proto.Binary.int64ValueAsInt)


{-| `google.protobuf.UInt64Value`, its decimal string.
-}
uint64Value : Message String
uint64Value =
    init "google.protobuf.UInt64Value" Proto.Json.encodeInt64 Proto.Json.uint64 (Proto.Binary.messageEncoder Proto.Binary.uint64Value) (Proto.Binary.messageDecoder Proto.Binary.uint64Value)


{-| `google.protobuf.UInt64Value` as an `Int`, under the `int64=int` option.
-}
uint64ValueAsInt : Message Int
uint64ValueAsInt =
    init "google.protobuf.UInt64Value" Proto.Json.encodeInt64AsInt Proto.Json.uint64AsInt (Proto.Binary.messageEncoder Proto.Binary.uint64ValueAsInt) (Proto.Binary.messageDecoder Proto.Binary.uint64ValueAsInt)


{-| `google.protobuf.Int32Value`.
-}
int32Value : Message Int
int32Value =
    init "google.protobuf.Int32Value" Json.Encode.int Proto.Json.int32 (Proto.Binary.messageEncoder Proto.Binary.int32Value) (Proto.Binary.messageDecoder Proto.Binary.int32Value)


{-| `google.protobuf.UInt32Value`.
-}
uint32Value : Message Int
uint32Value =
    init "google.protobuf.UInt32Value" Json.Encode.int Proto.Json.uint32 (Proto.Binary.messageEncoder Proto.Binary.uint32Value) (Proto.Binary.messageDecoder Proto.Binary.uint32Value)


{-| `google.protobuf.BoolValue`.
-}
boolValue : Message Bool
boolValue =
    init "google.protobuf.BoolValue" Json.Encode.bool Json.Decode.bool (Proto.Binary.messageEncoder Proto.Binary.boolValue) (Proto.Binary.messageDecoder Proto.Binary.boolValue)


{-| `google.protobuf.StringValue`.
-}
stringValue : Message String
stringValue =
    init "google.protobuf.StringValue" Json.Encode.string Proto.Json.string (Proto.Binary.messageEncoder Proto.Binary.stringValue) (Proto.Binary.messageDecoder Proto.Binary.stringValue)


{-| `google.protobuf.BytesValue`, its base64 text.
-}
bytesValue : Message String
bytesValue =
    init "google.protobuf.BytesValue" Proto.Json.encodeBytes Proto.Json.bytes (Proto.Binary.messageEncoder Proto.Binary.bytesValue) (Proto.Binary.messageDecoder Proto.Binary.bytesValue)


{-| The enum `google.protobuf.NullValue`: `()`, its one value `NULL_VALUE`,
written `null`. Since its encoder writes no string,
[`Proto.Enum.toName`](Proto-Enum#toName) gives `""` for it; `fromName` and
`fromNumber` read `"NULL_VALUE"` and `0`. Generated descriptors of a field of it
name its descriptor through this value.
-}
nullValue : Enum ()
nullValue =
    enum Proto.Json.encodeNullValue Proto.Json.nullValue () Descriptors.nullValue
