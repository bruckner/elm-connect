module Proto.Json.Encode exposing
    ( Encoder, encode, encodeWith, encodeTotal, succeed
    , timestamp, duration, fieldMask, struct, listValue, value
    )

{-| Writing proto3 JSON. Generated code gives each message an encoder, such as
`Notes.V1.encodeNote : Note -> Encoder Proto.Error.Error`, and this module
writes it: [`encode`](#encode) gives its JSON, or refuses a value proto3 JSON
has no form for (a `Timestamp` outside years 1 to 9999, a `FieldMask` path
with no lowerCamelCase form, a number in a `Value` that is not finite) with
[`BadValue`](Proto-Error#Error).

    Proto.Json.Encode.encode (Notes.V1.encodeNote note)
    -- Ok <the JSON>, or Err (BadValue { typeName = "google.protobuf.Timestamp", path = [ "createTime" ], message = "the time is outside years 1 to 9999" })

A message holding an `Any` is written with [`encodeWith`](#encodeWith) and the
registry the `Any` converts through.

The encoder of a message that holds nothing a write can refuse works for any
`x`, so [`encodeTotal`](#encodeTotal) writes it with no `Result`:

    Json.Encode.encode 0 (Proto.Json.Encode.encodeTotal (Notes.V1.encodeGetNoteRequest request))

@docs Encoder, encode, encodeWith, encodeTotal, succeed


# Well-known types

A well-known value written alone, outside a message, has an encoder here,
named for its type as elm/json names its encoders:

    Proto.Json.Encode.encode (Proto.Json.Encode.timestamp posix)
    -- Ok (Json.Encode.string "2026-10-10T17:19:45.250Z")

A lone `Any` is written with [`Proto.Any.encode`](Proto-Any#encode).

@docs timestamp, duration, fieldMask, struct, listValue, value

-}

import Dict
import Json.Encode exposing (Value)
import Proto.Duration exposing (Duration)
import Proto.Error exposing (Error)
import Proto.Internal.FieldMask as FieldMask
import Proto.Internal.Registry as InternalRegistry
import Proto.Internal.Writer as Writer
import Proto.Registry exposing (Registry)
import Proto.Timestamp
import Proto.Value
import Time


{-| A proto3 JSON encoder: what a generated `encodeNote : Note -> Encoder x`
gives, written by [`encode`](#encode). It is opaque. The package site and
compiler errors may show it as `Proto.Internal.Writer.Encoder`, its name
inside the package.

`x` is what it can refuse with. The encoder of a message that holds nothing a
write can refuse works for any `x`, and [`encodeTotal`](#encodeTotal) writes it
with `x` as `Never`; the others are `Encoder Proto.Error.Error`.

-}
type alias Encoder x =
    Writer.Encoder x


{-| Write an encoder's JSON, or refuse the first value it holds that proto3
JSON has no form for, with [`BadValue`](Proto-Error#Error). An `Any` is
converted through an empty, strict registry, so one that holds a message fails
with [`UnregisteredType`](Proto-Error#Error): write a message holding one with
[`encodeWith`](#encodeWith).

A value is not refused for its depth. One the program builds deeper than the
JavaScript stack allows throws while it is written, as it would through
`Json.Encode`; the calling guide's "Nesting depth" says where.

-}
encode : Encoder Error -> Result Error Value
encode =
    Writer.run (InternalRegistry.Registry InternalRegistry.Strict 0 Dict.empty)


{-| [`encode`](#encode), converting each `Any` through the registry, as
[`Proto.Any.toJson`](Proto-Any#toJson) does. An `Any` nested more than 100
levels deep, counting `Any`s and the messages that nest around them, is
refused with [`TooDeep`](Proto-Error#Reason), as a read refuses it.
-}
encodeWith : Registry -> Encoder Error -> Result Error Value
encodeWith =
    Writer.run


{-| The JSON of an encoder that cannot refuse, such as a generated
`encodeNote : Note -> Encoder x` of a message that holds nothing a write can
refuse:

    Json.Encode.encode 0 (encodeTotal (Notes.V1.encodeGetNoteRequest request))

The compiler rejects an encoder that can refuse, so this never fails.

-}
encodeTotal : Encoder Never -> Value
encodeTotal =
    Writer.total


{-| An encoder of JSON already written, which it gives as it is: for a value
written by hand, such as a [`Proto.Message`](Proto-Message)'s.

    Proto.Json.Encode.succeed << Json.Encode.string

-}
succeed : Value -> Encoder x
succeed =
    Writer.succeed


{-| A `google.protobuf.Timestamp`, refused outside years 1 to 9999.
-}
timestamp : Time.Posix -> Encoder Error
timestamp posix =
    let
        millis =
            Time.posixToMillis posix
    in
    -- 0001-01-01T00:00:00Z and 9999-12-31T23:59:59.999Z.
    if millis < -62135596800000 || millis > 253402300799999 then
        Writer.refuse "google.protobuf.Timestamp" "the time is outside years 1 to 9999"

    else
        Writer.succeed (encodeTimestamp posix)


{-| A `google.protobuf.Duration`, refused past protobuf's range.
-}
duration : Duration -> Encoder Error
duration held =
    -- Protobuf's range, ±315,576,000,000 seconds, which only
    -- Proto.Duration.fromParts can pass.
    if abs (Proto.Duration.toParts held).seconds <= 315576000000 then
        Writer.succeed (encodeDuration held)

    else
        Writer.refuse "google.protobuf.Duration" "the duration is outside -315,576,000,000 to 315,576,000,000 seconds"


{-| A `google.protobuf.FieldMask`, refused when a path's lowerCamelCase form
reads back as another path.
-}
fieldMask : List String -> Encoder Error
fieldMask paths =
    if List.all FieldMask.roundTrips paths then
        Writer.succeed (encodeFieldMask paths)

    else
        Writer.refuse "google.protobuf.FieldMask" "a path's JSON form does not read back as the same path"


{-| A `google.protobuf.Struct`, refused when it holds a number that is NaN or
infinite.
-}
struct : Dict.Dict String Proto.Value.Value -> Encoder Error
struct fields =
    checkedValue "google.protobuf.Struct" (Proto.Value.ValueStruct fields) (\() -> encodeStruct fields)


{-| A `google.protobuf.ListValue`, refused as [`struct`](#struct) is.
-}
listValue : List Proto.Value.Value -> Encoder Error
listValue items =
    checkedValue "google.protobuf.ListValue" (Proto.Value.ValueList items) (\() -> encodeListValue items)


{-| A `google.protobuf.Value`, refused as [`struct`](#struct) is.
-}
value : Proto.Value.Value -> Encoder Error
value held =
    checkedValue "google.protobuf.Value" held (\() -> encodeValue held)


checkedValue : String -> Proto.Value.Value -> (() -> Value) -> Encoder Error
checkedValue typeName held write =
    if finite held then
        Writer.succeed (write ())

    else
        Writer.refuse typeName "a number is NaN or infinite"


{-| Whether every number the value holds is finite. It walks the whole value,
however deeply it nests.
-}
finite : Proto.Value.Value -> Bool
finite held =
    case held of
        Proto.Value.ValueNumber number ->
            not (isNaN number || isInfinite number)

        Proto.Value.ValueStruct structMembers ->
            Dict.foldl (\_ item ok -> ok && finite item) True structMembers

        Proto.Value.ValueList items ->
            List.all finite items

        _ ->
            True


{-| Encode a `google.protobuf.Timestamp`; see
[`Proto.Timestamp.toString`](Proto-Timestamp#toString).
-}
encodeTimestamp : Time.Posix -> Value
encodeTimestamp posix =
    Json.Encode.string (Proto.Timestamp.toString posix)


{-| Encode a `google.protobuf.Duration`; see
[`Proto.Duration.toString`](Proto-Duration#toString).
-}
encodeDuration : Duration -> Value
encodeDuration span =
    Json.Encode.string (Proto.Duration.toString span)


{-| Encode a `google.protobuf.FieldMask` from its paths, written with proto
field names (`"author.email_address"`): each field name in lowerCamelCase, the
paths joined by commas.
-}
encodeFieldMask : List String -> Value
encodeFieldMask paths =
    Json.Encode.string (FieldMask.toText paths)


{-| Encode a `google.protobuf.Struct` from its members, as a JSON object.
-}
encodeStruct : Dict.Dict String Proto.Value.Value -> Value
encodeStruct fields =
    Proto.Value.toJson (Proto.Value.ValueStruct fields)


{-| Encode a `google.protobuf.ListValue` from its elements, as a JSON array.
-}
encodeListValue : List Proto.Value.Value -> Value
encodeListValue =
    Json.Encode.list Proto.Value.toJson


{-| Encode a `google.protobuf.Value` as its JSON.
-}
encodeValue : Proto.Value.Value -> Value
encodeValue =
    Proto.Value.toJson
