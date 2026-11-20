module Proto.Json.Checked exposing
    ( encodeTimestamp, encodeDuration, encodeFieldMask
    , encodeValue, encodeStruct, encodeListValue
    , binaryDuration
    )

{-| The encoders that code generated with `json_write=checked` calls for the
well-known types whose Elm values can hold what proto3 JSON has no form for.
Each gives what its namesake in [`Proto.Json`](Proto-Json) gives, in `Ok`, or
refuses the value with [`NoJsonForm`](Proto-Error#Error) naming the type:

  - a `Timestamp` before 0001-01-01T00:00:00Z or after
    9999-12-31T23:59:59.999Z;
  - a `Duration` past ±315,576,000,000 seconds, which only
    [`Proto.Duration.fromPartsUnclamped`](Proto-Duration#fromPartsUnclamped)
    builds;
  - a `FieldMask` path whose lowerCamelCase form does not read back as the
    path (`"fooBar"`, `"foo_3_bar"`, `"foo__bar"`);
  - a `Value`, `Struct` or `ListValue` holding a number that is NaN or
    infinite, at any depth.

@docs encodeTimestamp, encodeDuration, encodeFieldMask
@docs encodeValue, encodeStruct, encodeListValue


# Protobuf binary

@docs binaryDuration

-}

import Bytes.Encode
import Dict exposing (Dict)
import Json.Decode
import Json.Encode exposing (Value)
import Proto.Binary
import Proto.Duration exposing (Duration)
import Proto.Error exposing (Error(..))
import Proto.Json
import Time


{-| A `google.protobuf.Timestamp`, refused outside years 1 to 9999.
-}
encodeTimestamp : Time.Posix -> Result Error Value
encodeTimestamp posix =
    let
        millis =
            Time.posixToMillis posix
    in
    -- 0001-01-01T00:00:00Z and 9999-12-31T23:59:59.999Z.
    if millis < -62135596800000 || millis > 253402300799999 then
        Err (NoJsonForm "google.protobuf.Timestamp")

    else
        Ok (Proto.Json.encodeTimestamp posix)


{-| A `google.protobuf.Duration`, refused past protobuf's range.
-}
encodeDuration : Duration -> Result Error Value
encodeDuration duration =
    if Proto.Duration.isInRange duration then
        Ok (Proto.Json.encodeDuration duration)

    else
        Err (NoJsonForm "google.protobuf.Duration")


{-| A `google.protobuf.FieldMask`, refused when a path's lowerCamelCase form
does not read back as the path, since a reader would then get another field.
-}
encodeFieldMask : List String -> Result Error Value
encodeFieldMask paths =
    if List.all roundTrips paths then
        Ok (Proto.Json.encodeFieldMask paths)

    else
        Err (NoJsonForm "google.protobuf.FieldMask")


roundTrips : String -> Bool
roundTrips path =
    List.all (\segment -> snakeCase (camelCase segment) == segment) (String.split "." path)


camelCase : String -> String
camelCase name =
    case String.split "_" name of
        first :: rest ->
            first ++ String.concat (List.map (\word -> String.toUpper (String.left 1 word) ++ String.dropLeft 1 word) rest)

        [] ->
            name


snakeCase : String -> String
snakeCase name =
    String.foldl
        (\char written ->
            if Char.isUpper char then
                Char.toLower char :: '_' :: written

            else
                char :: written
        )
        []
        name
        |> List.reverse
        |> String.fromList


{-| A `google.protobuf.Value`, refused when it holds a number that is NaN or
infinite, which JSON cannot write (`JSON.stringify` writes `null` for one).
-}
encodeValue : Value -> Result Error Value
encodeValue json =
    if finite json then
        Ok json

    else
        Err (NoJsonForm "google.protobuf.Value")


{-| A `google.protobuf.Struct`, refused as [`encodeValue`](#encodeValue)
refuses a member.
-}
encodeStruct : Dict String Value -> Result Error Value
encodeStruct members =
    if List.all finite (Dict.values members) then
        Ok (Proto.Json.encodeStruct members)

    else
        Err (NoJsonForm "google.protobuf.Struct")


{-| A `google.protobuf.ListValue`, refused as [`encodeValue`](#encodeValue)
refuses an element.
-}
encodeListValue : List Value -> Result Error Value
encodeListValue items =
    if List.all finite items then
        Ok (Proto.Json.encodeListValue items)

    else
        Err (NoJsonForm "google.protobuf.ListValue")


finite : Value -> Bool
finite json =
    Json.Decode.decodeValue nonFinite json
        |> Result.withDefault False
        |> not


nonFinite : Json.Decode.Decoder Bool
nonFinite =
    Json.Decode.oneOf
        [ Json.Decode.map (\x -> isNaN x || isInfinite x) Json.Decode.float
        , Json.Decode.map (List.any identity) (Json.Decode.list (Json.Decode.lazy (\_ -> nonFinite)))
        , Json.Decode.map (List.any Tuple.second) (Json.Decode.keyValuePairs (Json.Decode.lazy (\_ -> nonFinite)))
        , Json.Decode.succeed False
        ]


{-| `google.protobuf.Duration` in protobuf binary, as
[`Proto.Binary.duration`](Proto-Binary#duration) reads it but for the clamp:
one past protobuf's range is held as it arrived, so that its JSON write can
refuse it.
-}
binaryDuration : Proto.Binary.Codec Duration
binaryDuration =
    Proto.Binary.embedded writeDuration
        (Proto.Binary.merge "google.protobuf.Duration" durationStep identity)
        (Proto.Duration.fromParts 0 0)


durationStep : Int -> Int -> Duration -> Proto.Binary.Field Duration
durationStep number wire current =
    let
        parts =
            Proto.Duration.toParts current
    in
    case number of
        1 ->
            Proto.Binary.field Proto.Binary.int64AsInt (\v -> Proto.Duration.fromPartsUnclamped v parts.nanos) wire current

        2 ->
            Proto.Binary.field Proto.Binary.int32 (\v -> Proto.Duration.fromPartsUnclamped parts.seconds v) wire current

        _ ->
            Proto.Binary.skip wire current


writeDuration : Duration -> Bytes.Encode.Encoder
writeDuration duration =
    let
        parts =
            Proto.Duration.toParts duration
    in
    Bytes.Encode.sequence
        [ Proto.Binary.implicit Proto.Binary.int64AsInt 1 parts.seconds
        , Proto.Binary.implicit Proto.Binary.int32 2 parts.nanos
        ]
