module Proto.WellKnown exposing
    ( empty, timestamp, duration, fieldMask, any
    , struct, value, listValue, nullValue
    , doubleValue, floatValue, int64Value, int64ValueAsInt, uint64Value, uint64ValueAsInt
    , int32Value, uint32Value, boolValue, stringValue, bytesValue
    )

{-| The `google.protobuf` types elm-connect maps, as
[`Message`](Proto-Message#Message) values, each in the Elm form generated code
gives the type. Generated code uses them for a method whose request or response
is a well-known type.

@docs empty, timestamp, duration, fieldMask, any


# JSON

@docs struct, value, listValue, nullValue


# Wrappers

A wrapper's Elm form is its scalar; a field of one is a `Maybe` of it. The
64-bit wrappers come in both forms the `int64` option chooses between.

@docs doubleValue, floatValue, int64Value, int64ValueAsInt, uint64Value, uint64ValueAsInt
@docs int32Value, uint32Value, boolValue, stringValue, bytesValue

-}

import Dict exposing (Dict)
import Json.Decode
import Json.Encode
import Proto.Any exposing (Any)
import Proto.Duration as Duration exposing (Duration)
import Proto.Enum exposing (Enum, enum)
import Proto.Internal.Any
import Proto.Internal.WellKnown as Descriptors
import Proto.Json
import Proto.Message exposing (Message, message)
import Time


{-| `google.protobuf.Empty`: `()`, written `{}`.
-}
empty : Message ()
empty =
    message Proto.Json.encodeEmpty Proto.Json.empty () Descriptors.empty


{-| `google.protobuf.Timestamp`: a `Time.Posix`, written in RFC 3339; the
default is the epoch.
-}
timestamp : Message Time.Posix
timestamp =
    message Proto.Json.encodeTimestamp Proto.Json.timestamp (Time.millisToPosix 0) Descriptors.timestamp


{-| `google.protobuf.Duration`, written as seconds (`"1.5s"`); the default is
zero.
-}
duration : Message Duration
duration =
    message Proto.Json.encodeDuration Proto.Json.duration (Duration.fromMilliseconds 0) Descriptors.duration


{-| `google.protobuf.FieldMask`: its paths, written comma-separated.
-}
fieldMask : Message (List String)
fieldMask =
    message Proto.Json.encodeFieldMask Proto.Json.fieldMask [] Descriptors.fieldMask


{-| `google.protobuf.Any`, a [`Proto.Any.Any`](Proto-Any#Any); the default
is the empty `Any`, with no type URL, written `{}`.
-}
any : Message Any
any =
    message Proto.Json.encodeAny Proto.Json.any (Proto.Internal.Any.Any "" (Proto.Internal.Any.InBinary "")) Descriptors.any


{-| `google.protobuf.Struct`: a JSON object.
-}
struct : Message (Dict String Json.Encode.Value)
struct =
    message Proto.Json.encodeStruct Proto.Json.struct Dict.empty Descriptors.struct


{-| `google.protobuf.Value`: any JSON; the default is `null`.
-}
value : Message Json.Encode.Value
value =
    message identity Json.Decode.value Json.Encode.null Descriptors.value


{-| `google.protobuf.ListValue`: a JSON array.
-}
listValue : Message (List Json.Encode.Value)
listValue =
    message Proto.Json.encodeListValue Proto.Json.listValue [] Descriptors.listValue


{-| The enum `google.protobuf.NullValue`: `()`, its one value `NULL_VALUE`,
written `null`. Since its encoder writes no string,
[`Proto.Enum.toName`](Proto-Enum#toName) gives `""` for it; `fromName` and
`fromNumber` read `"NULL_VALUE"` and `0`. Generated descriptors of a field of it
name its descriptor through this value.
-}
nullValue : Enum ()
nullValue =
    enum Proto.Json.encodeNullValue Proto.Json.nullValue () Descriptors.nullValue


{-| `google.protobuf.DoubleValue`.
-}
doubleValue : Message Float
doubleValue =
    message Proto.Json.encodeFloat Proto.Json.float 0 Descriptors.doubleValue


{-| `google.protobuf.FloatValue`.
-}
floatValue : Message Float
floatValue =
    message Proto.Json.encodeFloat Proto.Json.float32 0 Descriptors.floatValue


{-| `google.protobuf.Int64Value`, its decimal string.
-}
int64Value : Message String
int64Value =
    message Proto.Json.encodeInt64 Proto.Json.int64 "0" Descriptors.int64Value


{-| `google.protobuf.Int64Value` as an `Int`, under the `int64=int` option.
-}
int64ValueAsInt : Message Int
int64ValueAsInt =
    message Proto.Json.encodeInt64AsInt Proto.Json.int64AsInt 0 Descriptors.int64Value


{-| `google.protobuf.UInt64Value`, its decimal string.
-}
uint64Value : Message String
uint64Value =
    message Proto.Json.encodeInt64 Proto.Json.uint64 "0" Descriptors.uint64Value


{-| `google.protobuf.UInt64Value` as an `Int`, under the `int64=int` option.
-}
uint64ValueAsInt : Message Int
uint64ValueAsInt =
    message Proto.Json.encodeInt64AsInt Proto.Json.uint64AsInt 0 Descriptors.uint64Value


{-| `google.protobuf.Int32Value`.
-}
int32Value : Message Int
int32Value =
    message Json.Encode.int Proto.Json.int32 0 Descriptors.int32Value


{-| `google.protobuf.UInt32Value`.
-}
uint32Value : Message Int
uint32Value =
    message Json.Encode.int Proto.Json.uint32 0 Descriptors.uint32Value


{-| `google.protobuf.BoolValue`.
-}
boolValue : Message Bool
boolValue =
    message Json.Encode.bool Json.Decode.bool False Descriptors.boolValue


{-| `google.protobuf.StringValue`.
-}
stringValue : Message String
stringValue =
    message Json.Encode.string Json.Decode.string "" Descriptors.stringValue


{-| `google.protobuf.BytesValue`, its base64 text.
-}
bytesValue : Message String
bytesValue =
    message Proto.Json.encodeBytes Proto.Json.bytes "" Descriptors.bytesValue
