module Proto.Json.Decode exposing
    ( string
    , int32, uint32
    , int64, uint64, int64AsInt, uint64AsInt
    , float, float32
    , bytes, bytesAsBytes
    , timestamp, duration, fieldMask, empty, nullValue
    , struct, listValue, value
    , anyWith
    )

{-| Reading proto3 JSON's scalar and well-known values. Generated code gives
each message its decoder, such as `Notes.V1.decodeNote`, built from these;
they are for the values a program reads by hand, mirroring elm/json:

    type alias Stats =
        { count : String, updated : Time.Posix }

    decodeStats : Json.Decode.Decoder Stats
    decodeStats =
        Json.Decode.map2 Stats
            (Json.Decode.field "count" Proto.Json.Decode.int64)
            (Json.Decode.field "updated" Proto.Json.Decode.timestamp)

proto3 JSON leaves out a field at its default, so read a message with its
generated decoder, which reads a missing field as its default.

Each decoder accepts every form proto3 JSON admits for its type, as
protobuf's own parsers do: a 32-bit integer as a number or a string, a
`float` as `"NaN"` or `"Infinity"` too, and so on.


# Strings

@docs string


# 32-bit integers

@docs int32, uint32


# 64-bit integers

By default a 64-bit integer is held as its decimal string. Code generated with
the `int64=int` option, and fields marked `[jstype = JS_NUMBER]`, hold it as an
`Int` instead.

@docs int64, uint64, int64AsInt, uint64AsInt


# Floating point

@docs float, float32


# Bytes

By default a `bytes` field is held as its base64 text. Code generated with the
`bytes=bytes` option holds it as elm/bytes' `Bytes` instead; see
[`Proto.Bytes`](Proto-Bytes) for what `==` does with those.

@docs bytes, bytesAsBytes


# Well-known types

`Value` is any JSON, held as a [`Proto.Value.Value`](Proto-Value#Value). The
wrapper types (`Int32Value` and the rest) use their scalar's decoder.

@docs timestamp, duration, fieldMask, empty, nullValue
@docs struct, listValue, value
@docs anyWith

-}

import Bytes exposing (Bytes)
import Dict
import Json.Decode exposing (Decoder)
import Json.Encode exposing (Value)
import Proto.Any exposing (Any)
import Proto.Bytes
import Proto.Duration exposing (Duration)
import Proto.Error exposing (Error)
import Proto.Int64
import Proto.Internal.Any as InternalAny
import Proto.Internal.FieldMask as FieldMask
import Proto.Internal.JsonRead as JsonRead
import Proto.Internal.Registry as InternalRegistry
import Proto.Registry exposing (Registry)
import Proto.Timestamp
import Proto.Value
import Time


{-| Decode a `string`. JavaScript's JSON parser reads an escaped UTF-16
surrogate without its pair, such as `"\udc00"`, into the string as it is,
though such a string is not Unicode text and has no UTF-8 form; this fails on
one, as protobuf's parsers do.
-}
string : Decoder String
string =
    Json.Decode.string
        |> Json.Decode.andThen
            (\text ->
                if JsonRead.isScalarText text then
                    Json.Decode.succeed text

                else
                    Json.Decode.fail "Expecting Unicode text, but got a string with a UTF-16 surrogate without its pair"
            )


{-| Decode a signed 32-bit integer (`int32`, `sint32`, `sfixed32`).

proto3 JSON writes these as numbers, and a parser must also accept a string
and exponent notation: `42`, `"42"`, `1e2` and `"1e2"` all decode, as does
`4.0`. A string takes the forms [`int64`](#int64) reads one in, so `"007"` is
7 and `"+5"` fails. A value with a fractional part fails, and so does one
outside the type's range, -2147483648 to 2147483647.

-}
int32 : Decoder Int
int32 =
    boundedInt "an int32 (-2147483648 to 2147483647)" -2147483648 2147483647


{-| Decode an unsigned 32-bit integer (`uint32`, `fixed32`): the forms
[`int32`](#int32) accepts, within 0 to 4294967295.
-}
uint32 : Decoder Int
uint32 =
    boundedInt "a uint32 (0 to 4294967295)" 0 4294967295


{-| A JSON number, or a JSON string that should hold one.
-}
type Numeric
    = NumberForm Float
    | StringForm String


numeric : Decoder Numeric
numeric =
    Json.Decode.oneOf
        [ Json.Decode.map NumberForm Json.Decode.float
        , Json.Decode.map StringForm Json.Decode.string
        ]


{-| An integer in any form proto3 JSON allows for one, within `low` to
`high`: a number compared as a `Float`, which holds the bounds exactly, and a
string read as [`int64`](#int64) reads one.
-}
boundedInt : String -> Int -> Int -> Decoder Int
boundedInt what low high =
    let
        outOfRange form =
            Json.Decode.fail ("Expecting " ++ what)
    in
    numeric
        |> Json.Decode.andThen
            (\form ->
                case form of
                    NumberForm _ ->
                        case integral form of
                            Err problem ->
                                Json.Decode.fail problem

                            Ok number ->
                                if number < toFloat low || number > toFloat high then
                                    outOfRange form

                                else
                                    Json.Decode.succeed (round number)

                    StringForm text ->
                        case JsonRead.narrowInteger low high text of
                            Ok int ->
                                Json.Decode.succeed int

                            Err JsonRead.OutOfRange ->
                                outOfRange form

                            Err _ ->
                                Json.Decode.fail "Expecting an integer"
            )


{-| The integral value of a number, or of a string holding one in decimal or
exponent notation.
-}
integral : Numeric -> Result String Float
integral form =
    let
        number =
            case form of
                NumberForm given ->
                    Just given

                StringForm text ->
                    String.toFloat text

        notInteger =
            Err "Expecting an integer"
    in
    case number of
        Just given ->
            if isNaN given || isInfinite given || toFloat (round given) /= given then
                notInteger

            else
                Ok given

        Nothing ->
            notInteger


{-| Decode a 64-bit integer (`int64`, `uint64`, `sint64`, `fixed64`,
`sfixed64`) as its decimal string, since Elm's `Int` is exact only up to
2^53.

proto3 JSON writes these as strings, and a parser must accept either a string
or a number, in exponent notation too. The result is always the canonical
decimal string, with no leading zeros:

    "42", 42           --> "42"
    "1e3", "1.5e3"     --> "1000", "1500"
    1E2, "-2e0"        --> "100", "-2"
    "007", "-0"        --> "7", "0"

A value that is not an integer fails (`"4.2"`, `"1.5e0"`), and so does one
outside the type's range, -9223372036854775808 to 9223372036854775807
(`"9223372036854775808"`). Exponent notation is read as text, by moving the
decimal point, so a string keeps every digit. A number is read as the exact
value of the double JavaScript's JSON parser made of it, as a runtime with
big integers reads it: `-9223372036854775808` and `9223372036854774784` keep
every digit. A number no double holds was rounded by that parser before this
decoder saw it, and reads as the rounded value: `9223372036854775807` as
2^63, which is out of range. Write such a value as a string.

-}
int64 : Decoder String
int64 =
    wide JsonRead.Signed


{-| A 64-bit integer as its canonical decimal string, within the range of
`width`.
-}
wide : JsonRead.Width -> Decoder String
wide width =
    Json.Decode.oneOf
        [ Json.Decode.string
        , Json.Decode.map exactDecimal Json.Decode.int
        ]
        |> Json.Decode.andThen
            (\text ->
                case JsonRead.wideInteger width text of
                    Ok decimal ->
                        Json.Decode.succeed decimal

                    Err JsonRead.NotDecimal ->
                        Json.Decode.fail "Expecting a decimal integer"

                    Err JsonRead.NotInteger ->
                        Json.Decode.fail "Expecting an integer"

                    Err JsonRead.OutOfRange ->
                        Json.Decode.fail ("Expecting " ++ widthName width ++ " " ++ JsonRead.widthRange width)
            )


{-| The exact decimal value of an integral JSON number. `String.fromInt`
writes JavaScript's shortest form, which past 2^53 can end in zeros the
value does not have (9223372036854774784 as `"9223372036854775000"`). From
2^53 to 2^64 the magnitude is split into 32-bit halves and then into a count
of millions and a remainder, every step exact in a double since each value
stays below 2^53; 2^64 and past, out of every 64-bit type's range, keep the
shortest form, which the range check refuses.
-}
exactDecimal : Int -> String
exactDecimal number =
    let
        magnitude =
            abs number
    in
    if magnitude <= 9007199254740992 || toFloat magnitude >= 1.8446744073709552e19 then
        String.fromInt number

    else
        let
            high =
                floor (toFloat magnitude / 4294967296)

            low =
                magnitude - high * 4294967296

            -- 4294967296 is 4294 millions and 967296.
            belowMillions =
                high * 967296 + low

            ones =
                modBy 1000000 belowMillions

            millions =
                high * 4294 + round (toFloat (belowMillions - ones) / 1000000)

            sign =
                if number < 0 then
                    "-"

                else
                    ""
        in
        sign ++ String.fromInt millions ++ String.padLeft 6 '0' (String.fromInt ones)


widthName : JsonRead.Width -> String
widthName width =
    case width of
        JsonRead.Signed ->
            "an int64"

        JsonRead.Unsigned ->
            "a uint64"


{-| Decode a 64-bit integer as an `Int`, for code generated with the
`int64=int` option or for a field marked `[jstype = JS_NUMBER]`.

It accepts a JSON number or a string, in decimal or exponent notation, as
proto3 JSON requires (`42`, `"42"`, `"4.2e1"`), and fails on a value that is not an integer or lies outside ±9007199254740991,
where Elm's `Int` stops being exact; see
[`Proto.Int64.toInt`](Proto-Int64#toInt). A number outside that range
fails too, whether a double holds it exactly or JavaScript's JSON parser
rounded it.

-}
int64AsInt : Decoder Int
int64AsInt =
    numeric |> Json.Decode.andThen int64Form


{-| Decode an unsigned 64-bit integer (`uint64`, `fixed64`) as its decimal
string: the forms [`int64`](#int64) accepts, within 0 to 18446744073709551615
(2^64 - 1).
-}
uint64 : Decoder String
uint64 =
    wide JsonRead.Unsigned


{-| Decode an unsigned 64-bit integer as an `Int`, under the `int64=int`
option: the forms [`int64AsInt`](#int64AsInt) accepts, from 0 up to
the largest `Int` that is exact, 9007199254740991.
-}
uint64AsInt : Decoder Int
uint64AsInt =
    int64AsInt
        |> Json.Decode.andThen
            (\number ->
                if number < 0 then
                    Json.Decode.fail "Expecting a uint64 (0 or more)"

                else
                    Json.Decode.succeed number
            )


int64Form : Numeric -> Decoder Int
int64Form form =
    let
        outOfRange =
            Json.Decode.fail
                "Expecting an integer from -9007199254740991 to 9007199254740991, the 64-bit integers an Elm Int holds exactly"
    in
    case form of
        NumberForm number ->
            case integral form of
                Err problem ->
                    Json.Decode.fail problem

                Ok _ ->
                    if abs number > 9007199254740991 then
                        outOfRange

                    else
                        Json.Decode.succeed (round number)

        StringForm text ->
            case JsonRead.canonicalInteger text of
                Err JsonRead.NotDecimal ->
                    Json.Decode.fail "Expecting a decimal integer"

                Err JsonRead.NotInteger ->
                    Json.Decode.fail "Expecting an integer"

                Err JsonRead.OutOfRange ->
                    outOfRange

                Ok decimal ->
                    case Proto.Int64.toInt decimal of
                        Just int ->
                            Json.Decode.succeed int

                        Nothing ->
                            outOfRange


{-| Decode a `double`. proto3 JSON writes a finite value as a number and the
others as the strings `"NaN"`, `"Infinity"` and `"-Infinity"`; a parser must
also accept a finite value written as a string, such as `"1.5"`.

A number past a double's range, such as `1e999`, fails: JavaScript's JSON
parser reads it as an infinity, which proto3 JSON writes only as a string.

-}
float : Decoder Float
float =
    Json.Decode.oneOf
        [ Json.Decode.map Ok Json.Decode.float
        , Json.Decode.map Err Json.Decode.string
        ]
        |> Json.Decode.andThen (floatIn "a double" (\_ -> True))


{-| Decode a `float`, as [`float`](#float) decodes a `double`, and fail on a
finite value whose magnitude is past the largest `float`,
3.4028234663852886e38. A value within it is kept as it arrived, not rounded to
the nearest `float`.
-}
float32 : Decoder Float
float32 =
    Json.Decode.oneOf
        [ Json.Decode.map Ok Json.Decode.float
        , Json.Decode.map Err Json.Decode.string
        ]
        |> Json.Decode.andThen (floatIn "a float" (\number -> abs number <= maxFloat32))


maxFloat32 : Float
maxFloat32 =
    3.4028234663852886e38


{-| A number, or the string it was written as, if it is finite and `fits`, or
the string is one of the names of the values a number cannot write.
-}
floatIn : String -> (Float -> Bool) -> Result String Float -> Decoder Float
floatIn kind fits written =
    let
        checked number =
            if isInfinite number || not (fits number) then
                Json.Decode.fail ("Expecting " ++ kind ++ ", but got a number past its range")

            else
                Json.Decode.succeed number
    in
    case written of
        Ok number ->
            checked number

        Err "NaN" ->
            Json.Decode.succeed (0 / 0)

        Err "Infinity" ->
            Json.Decode.succeed (1 / 0)

        Err "-Infinity" ->
            Json.Decode.succeed -(1 / 0)

        Err text ->
            case String.toFloat text of
                Just number ->
                    if isNaN number then
                        Json.Decode.fail "Expecting a number"

                    else
                        checked number

                Nothing ->
                    Json.Decode.fail "Expecting a number"


{-| Decode `bytes`, which proto3 JSON writes as a base64 string, as that
string, kept exactly as it arrived (not normalised to one alphabet or
padding).

The string must be base64, as proto3 JSON parsers accept it: the standard
alphabet (`A`–`Z`, `a`–`z`, `0`–`9`, `+`, `/`) or the URL-safe one (`-` and
`_` in place of `+` and `/`), not both in one string, with or without `=`
padding. Anything else fails: another character, a length no base64 text has,
or padding that does not fit the length.

    Json.Decode.decodeString bytes "\"aGk=\"" -- Ok "aGk="

    Json.Decode.decodeString bytes "\"aGk\"" -- Ok "aGk"

    Json.Decode.decodeString bytes "\"a\"" -- Err ...

-}
bytes : Decoder String
bytes =
    Json.Decode.string
        |> Json.Decode.andThen
            (\text ->
                if isBase64 text then
                    Json.Decode.succeed text

                else
                    Json.Decode.fail "Expecting base64 (standard or URL-safe, padding optional)"
            )


isBase64 : String -> Bool
isBase64 text =
    let
        padding =
            trailingPadding text

        body =
            String.dropRight padding text

        partial =
            modBy 4 (String.length body)
    in
    -- The padding is counted and dropped natively; `String.all` then reads
    -- the body from its end, which `isBase64Char` makes safe (see there).
    (padding == 0 || (partial /= 0 && padding == 4 - partial))
        && (partial /= 1)
        && String.all isBase64Char body
        && not (bothAlphabets body)


{-| How many `=` end `text`, up to 3: more than 2 is never base64.
-}
trailingPadding : String -> Int
trailingPadding text =
    if String.endsWith "==" text then
        if String.endsWith "===" text then
            3

        else
            2

    else if String.endsWith "=" text then
        1

    else
        0


{-| Whether base64 text mixes the standard alphabet's `+` or `/` with the
URL-safe one's `-` or `_`.
-}
bothAlphabets : String -> Bool
bothAlphabets body =
    (String.contains "+" body || String.contains "/" body) && (String.contains "-" body || String.contains "_" body)


{-| A character of either base64 alphabet. elm/core's `String.all` reads a
string from its end and takes a low surrogate without its high half together
with the code unit before it, a letter perhaps, as one character two units
long; at the start of the text, with what lies before the string, where
reading on would never return. Its length refuses it.
-}
isBase64Char : Char -> Bool
isBase64Char char =
    let
        code =
            Char.toCode char
    in
    String.length (String.fromChar char) == 1 && ((code >= 0x61 && code <= 0x7A) || (code >= 0x41 && code <= 0x5A) || (code >= 0x30 && code <= 0x39) || char == '+' || char == '/' || char == '-' || char == '_')


{-| Decode `bytes`, which proto3 JSON writes as a base64 string, as the bytes
it holds. It accepts what [`bytes`](#bytes) accepts.

    Json.Decode.decodeString bytesAsBytes "\"aGk=\"" |> Result.map Bytes.width -- Ok 2

    Json.Decode.decodeString bytesAsBytes "\"a\"" -- Err ...

-}
bytesAsBytes : Decoder Bytes
bytesAsBytes =
    Json.Decode.string
        |> Json.Decode.andThen
            (\text ->
                case Proto.Bytes.fromBase64 text of
                    Just decoded ->
                        Json.Decode.succeed decoded

                    Nothing ->
                        Json.Decode.fail "Expecting base64 (standard or URL-safe, padding optional)"
            )


{-| Decode a `google.protobuf.Timestamp`, an RFC 3339 string; see
[`Proto.Timestamp.fromString`](Proto-Timestamp#fromString).
-}
timestamp : Decoder Time.Posix
timestamp =
    Json.Decode.string
        |> Json.Decode.andThen
            (\text ->
                case Proto.Timestamp.fromString text of
                    Just posix ->
                        Json.Decode.succeed posix

                    Nothing ->
                        Json.Decode.fail "Expecting an RFC 3339 timestamp"
            )


{-| Decode a `google.protobuf.Duration`, such as `"1.5s"`; see
[`Proto.Duration.fromString`](Proto-Duration#fromString).
-}
duration : Decoder Duration
duration =
    Json.Decode.string
        |> Json.Decode.andThen
            (\text ->
                case Proto.Duration.fromString text of
                    Just decoded ->
                        Json.Decode.succeed decoded

                    Nothing ->
                        Json.Decode.fail "Expecting a duration such as \"1.5s\""
            )


{-| Decode a `google.protobuf.FieldMask` into its paths. proto3 JSON writes a
mask as one string, the paths joined by commas, each field name in
lowerCamelCase; the paths come back with proto field names, as a server
expects them:

    Json.Decode.decodeString fieldMask "\"displayName,author.emailAddress\""
    -- Ok [ "display_name", "author.email_address" ]

The empty string is the empty mask. A path with an `_` fails: lowerCamelCase
has none, so it can only be a proto field name, which proto3 JSON does not
write here.

-}
fieldMask : Decoder (List String)
fieldMask =
    Json.Decode.string
        |> Json.Decode.andThen
            (\text ->
                if String.isEmpty text then
                    Json.Decode.succeed []

                else if String.contains "_" text then
                    Json.Decode.fail "Expecting a FieldMask of lowerCamelCase paths"

                else
                    String.split "," text
                        |> List.map FieldMask.fromJsonPath
                        |> Json.Decode.succeed
            )


{-| Decode a `google.protobuf.Empty`: any JSON object, usually `{}`. A field
of it reads as `()` when absent or `null` too, so its presence is not kept.
-}
empty : Decoder ()
empty =
    Json.Decode.value
        |> Json.Decode.andThen
            (\json ->
                if JsonRead.isObject json then
                    Json.Decode.succeed ()

                else
                    JsonRead.notAnObject
            )


{-| Decode the enum `google.protobuf.NullValue`, held as `()`: its one value,
`NULL_VALUE`, is written `null`, and a parser also accepts its name and number,
as it does for any enum ([`Proto.Json.enum`](Proto-Json#enum)).
-}
nullValue : Decoder ()
nullValue =
    Json.Decode.nullable (JsonRead.enumWith (\_ -> Json.Decode.fail ("Expecting a value of enum " ++ JsonRead.quote "NullValue")) () [ ( "NULL_VALUE", 0, () ) ])
        |> Json.Decode.map (\_ -> ())


{-| Decode a `google.protobuf.Struct`, a JSON object, into its members. Any
other JSON, such as an array, fails with elm/json's `Expecting an OBJECT`,
and an object nested more than 100 deep with "Expecting messages nested at
most 100 deep", which does not say where inside it the limit was passed.

    Json.Decode.decodeString struct """{"a":1}"""
    -- Ok (Dict.fromList [ ( "a", ValueNumber 1 ) ])

-}
struct : Decoder (Dict.Dict String Proto.Value.Value)
struct =
    JsonRead.nestedStruct 0


{-| Decode a `google.protobuf.ListValue`, a JSON array, into its elements. Any
other JSON, such as an object, fails with elm/json's `Expecting a LIST`, and
an array nested more than 100 deep as [`struct`](#struct) says.
-}
listValue : Decoder (List Proto.Value.Value)
listValue =
    JsonRead.nestedListValue 0


{-| Decode a `google.protobuf.Value`: any JSON, its arrays and objects
nested at most 100 deep. Deeper JSON fails with "Expecting messages nested at
most 100 deep", the failure of messages nested too deeply, since the levels
of both count against one limit (design section 3.5). The same decoder as
[`Proto.Value.decoder`](Proto-Value#decoder).

    Json.Decode.decodeString value """{"a":[1,"x",null]}"""
    -- Ok (ValueStruct (Dict.fromList [ ( "a", ValueList [ ValueNumber 1, ValueString "x", ValueNull ] ) ]))

-}
value : Decoder Proto.Value.Value
value =
    JsonRead.nestedValue 0


{-| Decode a `google.protobuf.Any` into one holding its message's protobuf
binary, which the registry's entry for its type converts the JSON to: an
object with `"@type"`, holding the message's fields or, for a well-known type
with a JSON form of its own, `"value"`. An object without `"@type"` fails, but
for `{}`, the empty `Any`, and so does one whose `"@type"` is not a type URL:
it must hold a `/` with a type name after the last one. As protobuf's own
JSON readers do, it fails for a type the registry has no entry for, naming
its type URL (register the type, see [`Proto.Registry`](Proto-Registry)),
unless the registry is [lenient](Proto-Registry#lenient): then the `Any`
holds the JSON alone. It fails for JSON that is not its message, lenient
or not.
-}
anyWith : Registry -> Decoder Any
anyWith (InternalRegistry.Registry leniency depth entries) =
    anyParts
        |> Json.Decode.andThen
            (\parts ->
                case parts of
                    Just ( url, messageJson ) ->
                        let
                            read readLeniency =
                                InternalRegistry.toBytes (InternalRegistry.Registry readLeniency depth entries) (InternalAny.nameOf url) messageJson

                            json =
                                Json.Decode.succeed (InternalAny.Any url (InternalAny.Json messageJson))
                        in
                        if leniency == InternalRegistry.Checking then
                            -- Only whether the read succeeds is kept, and held as
                            -- JSON this `Any` adds nothing to the binary around it.
                            case read InternalRegistry.Checking of
                                Just (Err problem) ->
                                    notItsMessage url problem

                                _ ->
                                    json

                        else
                            case read InternalRegistry.Strict of
                                Just (Ok base64) ->
                                    Json.Decode.succeed (InternalAny.Any url (InternalAny.Binary base64))

                                Just (Err problem) ->
                                    if leniency == InternalRegistry.Lenient then
                                        -- Read leniently, it may hold an `Any` its binary
                                        -- would lose: it is held as JSON alone. That read
                                        -- is a check, its binary dropped.
                                        case read InternalRegistry.Checking of
                                            Just (Ok _) ->
                                                json

                                            _ ->
                                                notItsMessage url problem

                                    else
                                        notItsMessage url problem

                                Nothing ->
                                    if leniency == InternalRegistry.Lenient then
                                        json

                                    else
                                        Json.Decode.fail "Expecting an Any of a type the registry has"

                    Nothing ->
                        Json.Decode.succeed InternalAny.empty
            )


{-| The failure of an `Any` whose JSON is not the message its type URL names.
A JSON failure is failed again where it happened, under the `Any`, so that its
path and its own text stand as any other failure's do; anything else says
which type it was.
-}
notItsMessage : String -> Error -> Decoder a
notItsMessage url problem =
    case problem of
        Proto.Error.BadJson inner ->
            if InternalAny.hasJsonForm url then
                Json.Decode.field "value" (failAgain inner)

            else
                failAgain inner

        _ ->
            Json.Decode.fail ("Expecting an Any of " ++ JsonRead.quote url ++ " to hold that message")


{-| A decoder that fails as `error` did, on the same JSON.
-}
failAgain : Json.Decode.Error -> Decoder a
failAgain error =
    case error of
        Json.Decode.Field name inner ->
            Json.Decode.field name (failAgain inner)

        Json.Decode.Index index inner ->
            Json.Decode.index index (failAgain inner)

        Json.Decode.OneOf ways ->
            Json.Decode.oneOf (List.map failAgain ways)

        Json.Decode.Failure text _ ->
            Json.Decode.fail text


{-| An `Any` object's type URL and its message's JSON, or `Nothing` for `{}`.
-}
anyParts : Decoder (Maybe ( String, Value ))
anyParts =
    Json.Decode.keyValuePairs Json.Decode.value
        |> Json.Decode.andThen anyFromPairs


anyFromPairs : List ( String, Value ) -> Decoder (Maybe ( String, Value ))
anyFromPairs pairs =
    case ( pairValue "@type" pairs, pairs ) of
        ( Nothing, [] ) ->
            Json.Decode.succeed Nothing

        ( Nothing, _ ) ->
            Json.Decode.fail "Expecting an Any: an object with \"@type\""

        ( Just found, _ ) ->
            case Json.Decode.decodeValue Json.Decode.string found of
                Err _ ->
                    Json.Decode.fail "Expecting an Any whose \"@type\" is a string"

                Ok url ->
                    if not (isTypeUrl url) then
                        Json.Decode.fail "Expecting an Any whose \"@type\" is a type URL, such as \"type.googleapis.com/notes.v1.Note\""

                    else if InternalAny.hasJsonForm url then
                        case pairValue "value" pairs of
                            Just json ->
                                Json.Decode.succeed (Just ( url, json ))

                            Nothing ->
                                Json.Decode.fail ("Expecting an Any of " ++ InternalAny.nameOf url ++ " to hold \"value\"")

                    else
                        pairs
                            |> List.filter (\( key, _ ) -> key /= "@type")
                            |> Json.Encode.object
                            |> Tuple.pair url
                            |> Just
                            |> Json.Decode.succeed


{-| A type URL, as proto3 JSON requires `"@type"` to hold one: a `/` with a
type name after the last one.
-}
isTypeUrl : String -> Bool
isTypeUrl url =
    String.contains "/" url && not (String.endsWith "/" url)


{-| The value under `key` among a JSON object's pairs.
-}
pairValue : String -> List ( String, a ) -> Maybe a
pairValue key pairs =
    case pairs of
        [] ->
            Nothing

        ( k, v ) :: rest ->
            if k == key then
                Just v

            else
                pairValue key rest
