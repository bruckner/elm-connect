module Proto.JsonFuzzTest exposing (suite)

{-| Properties of the proto3 JSON codecs (`Proto.Json`, and through it
`Proto.Int64`, `Proto.Timestamp` and `Proto.Duration`), fuzzed: each type's
values round-trip through their encoder and decoder across the type's whole
range, the decoder accepts the other forms proto3 JSON allows, and an encoder
leaves out what is at its default. The examples beside it (`JsonTest`) pin
exact forms and errors.
-}

import Dict
import Expect exposing (Expectation)
import Fuzz exposing (Fuzzer)
import Fuzzers
import Json.Decode exposing (Decoder)
import Json.Encode exposing (Value)
import Proto.Duration
import Proto.Int64
import Proto.Json
import Proto.Timestamp
import Routes.V1
import Test exposing (Test, describe, fuzz, fuzz2, test)
import Time


suite : Test
suite =
    describe "Proto.Json, fuzzed"
        [ int32Properties
        , int64Properties
        , int64AsIntProperties
        , floatProperties
        , bytesProperties
        , timestampProperties
        , durationProperties
        , fieldMaskProperties
        , enumProperties
        , mapProperties
        , repeatedProperties
        , jsonValueProperties
        , omitDefaultsProperties
        ]


{-| `value` encoded and decoded back is `value`.
-}
roundTrips : (a -> Value) -> Decoder a -> a -> Expectation
roundTrips encode decoder value =
    Json.Decode.decodeString decoder (Json.Encode.encode 0 (encode value))
        |> Expect.equal (Ok value)


decodes : Decoder a -> Value -> a -> Expectation
decodes decoder json expected =
    Json.Decode.decodeValue decoder json |> Expect.equal (Ok expected)


fails : Decoder a -> Value -> Expectation
fails decoder json =
    case Json.Decode.decodeValue decoder json of
        Ok value ->
            Expect.fail ("decoded " ++ Json.Encode.encode 0 json ++ " as " ++ Debug.toString value)

        Err _ ->
            Expect.pass



-- 32-BIT INTEGERS


int32Properties : Test
int32Properties =
    describe "32-bit integers"
        [ fuzz (Fuzz.intRange -2147483648 2147483647) "an int32 round-trips, and decodes from its string" <|
            \n ->
                Expect.all
                    [ roundTrips Json.Encode.int Proto.Json.int32
                    , \_ -> decodes Proto.Json.int32 (Json.Encode.string (String.fromInt n)) n
                    ]
                    n
        , fuzz (Fuzz.intRange 0 4294967295) "a uint32 round-trips, and decodes from its string" <|
            \n ->
                Expect.all
                    [ roundTrips Json.Encode.int Proto.Json.uint32
                    , \_ -> decodes Proto.Json.uint32 (Json.Encode.string (String.fromInt n)) n
                    ]
                    n
        , fuzz (Fuzz.intRange 1 1099511627776) "an int32 out of range fails" <|
            \n ->
                Expect.all
                    [ \_ -> fails Proto.Json.int32 (Json.Encode.int (2147483647 + n))
                    , \_ -> fails Proto.Json.int32 (Json.Encode.int (-2147483648 - n))
                    ]
                    ()
        , fuzz (Fuzz.intRange 1 1099511627776) "a uint32 out of range fails" <|
            \n ->
                Expect.all
                    [ \_ -> fails Proto.Json.uint32 (Json.Encode.int (4294967295 + n))
                    , \_ -> fails Proto.Json.uint32 (Json.Encode.int -n)
                    ]
                    ()
        ]



-- 64-BIT INTEGERS


{-| `text`, a canonical decimal integer, in exponent notation: the point
after the first digit, trailing zeros moved into the exponent.
-}
scientific : String -> String
scientific text =
    let
        ( sign, unsigned ) =
            if String.startsWith "-" text then
                ( "-", String.dropLeft 1 text )

            else
                ( "", text )

        significant =
            String.reverse (dropZeros (String.reverse unsigned))

        mantissa =
            case String.uncons significant of
                Just ( first, rest ) ->
                    if String.isEmpty rest then
                        String.fromChar first

                    else
                        String.fromChar first ++ "." ++ rest

                Nothing ->
                    "0"
    in
    sign ++ mantissa ++ "e" ++ String.fromInt (String.length unsigned - 1)


dropZeros : String -> String
dropZeros text =
    if String.startsWith "0" text then
        dropZeros (String.dropLeft 1 text)

    else
        text


int64Properties : Test
int64Properties =
    describe "64-bit integers as strings"
        [ fuzz Fuzzers.int64Text "an int64 round-trips with every digit, past 2^53 too" <|
            roundTrips Proto.Json.encodeInt64 Proto.Json.int64
        , fuzz Fuzzers.uint64Text "a uint64 round-trips with every digit" <|
            roundTrips Proto.Json.encodeInt64 Proto.Json.uint64
        , fuzz Fuzzers.int64Text "an int64 in exponent notation reads as its canonical string" <|
            \text ->
                Expect.all
                    [ \_ -> decodes Proto.Json.int64 (Json.Encode.string (scientific text)) text
                    , \_ -> decodes Proto.Json.int64 (Json.Encode.string (text ++ "e0")) text
                    , \_ -> decodes Proto.Json.int64 (Json.Encode.string (text ++ ".0")) text
                    ]
                    ()
        , fuzz Fuzzers.int64Text "leading zeros are dropped" <|
            \text ->
                let
                    padded =
                        if String.startsWith "-" text then
                            "-00" ++ String.dropLeft 1 text

                        else
                            "00" ++ text
                in
                decodes Proto.Json.int64 (Json.Encode.string padded) text
        , fuzz Fuzzers.safeInt "a JSON number within 2^53 reads as its decimal string" <|
            \n -> decodes Proto.Json.int64 (Json.Encode.int n) (String.fromInt n)
        , fuzz Fuzzers.uint64Text "a negative uint64 fails" <|
            \text ->
                if text == "0" then
                    Expect.pass

                else
                    fails Proto.Json.uint64 (Json.Encode.string ("-" ++ text))
        , fuzz Fuzzers.int64Text "a fraction fails" <|
            \text -> fails Proto.Json.int64 (Json.Encode.string (text ++ ".5"))
        ]


int64AsIntProperties : Test
int64AsIntProperties =
    describe "64-bit integers as Int"
        [ fuzz Fuzzers.safeInt "an Int within ±(2^53 − 1) round-trips, and reads from a number" <|
            \n ->
                Expect.all
                    [ roundTrips Proto.Json.encodeInt64AsInt Proto.Json.int64AsInt
                    , \_ -> decodes Proto.Json.int64AsInt (Json.Encode.int n) n
                    , \_ -> Proto.Int64.toInt (Proto.Int64.fromInt n) |> Expect.equal (Just n)
                    ]
                    n
        , fuzz (Fuzz.map abs Fuzzers.safeInt) "a uint64 Int round-trips" <|
            roundTrips Proto.Json.encodeInt64AsInt Proto.Json.uint64AsInt
        , fuzz Fuzzers.unsafeInt64Text "past ±(2^53 − 1) it fails rather than round" <|
            \text ->
                Expect.all
                    [ \_ -> fails Proto.Json.int64AsInt (Json.Encode.string text)
                    , \_ -> fails Proto.Json.uint64AsInt (Json.Encode.string text)
                    , \_ -> Proto.Int64.toInt text |> Expect.equal Nothing
                    ]
                    ()
        ]



-- FLOATS


{-| Equal, NaN equal to itself.
-}
sameFloat : Float -> Result String Float -> Expectation
sameFloat expected actual =
    case actual of
        Ok x ->
            if isNaN expected && isNaN x || x == expected then
                Expect.pass

            else
                Expect.fail (String.fromFloat x ++ " is not " ++ String.fromFloat expected)

        Err problem ->
            Expect.fail problem


floatProperties : Test
floatProperties =
    describe "floats"
        [ fuzz Fuzzers.float "a double round-trips, NaN and the infinities included" <|
            \x ->
                Json.Encode.encode 0 (Proto.Json.encodeFloat x)
                    |> Json.Decode.decodeString Proto.Json.float
                    |> Result.mapError Json.Decode.errorToString
                    |> sameFloat x
        , fuzz Fuzzers.float "a double reads from its string form too" <|
            \x ->
                let
                    text =
                        if isNaN x then
                            "NaN"

                        else if isInfinite x && x > 0 then
                            "Infinity"

                        else if isInfinite x then
                            "-Infinity"

                        else
                            String.fromFloat x
                in
                Json.Decode.decodeValue Proto.Json.float (Json.Encode.string text)
                    |> Result.mapError Json.Decode.errorToString
                    |> sameFloat x
        , fuzz Fuzzers.float "a non-finite double is written as proto3 JSON's string" <|
            \x ->
                if isNaN x || isInfinite x then
                    Json.Decode.decodeValue Json.Decode.string (Proto.Json.encodeFloat x)
                        |> Result.map (\text -> List.member text [ "NaN", "Infinity", "-Infinity" ])
                        |> Expect.equal (Ok True)

                else
                    Json.Decode.decodeValue Json.Decode.float (Proto.Json.encodeFloat x)
                        |> Result.mapError Json.Decode.errorToString
                        |> sameFloat x
        , test "-0 is written as 0, and so reads back as +0 (design §3.4)" <|
            \_ ->
                Json.Encode.encode 0 (Proto.Json.encodeFloat (negate 0))
                    |> Expect.equal "0"
        ]



-- BYTES


bytesProperties : Test
bytesProperties =
    let
        urlSafe =
            String.map
                (\char ->
                    case char of
                        '+' ->
                            '-'

                        '/' ->
                            '_'

                        other ->
                            other
                )

        unpadded =
            String.filter ((/=) '=')
    in
    describe "bytes"
        [ fuzz (Fuzz.list (Fuzz.intRange 0 255)) "base64 in either alphabet, padded or not, round-trips as written" <|
            \bytes ->
                let
                    text =
                        Fuzzers.base64 bytes
                in
                Expect.all
                    (List.map (\form _ -> roundTrips Proto.Json.encodeBytes Proto.Json.bytes form)
                        [ text, urlSafe text, unpadded text, unpadded (urlSafe text) ]
                    )
                    ()
        , fuzz2 (Fuzz.list (Fuzz.intRange 0 255)) (Fuzz.list (Fuzz.intRange 0 255)) "mixing the alphabets fails" <|
            \before after ->
                let
                    text =
                        unpadded (Fuzzers.base64 before) ++ "+-" ++ unpadded (Fuzzers.base64 after)
                in
                fails Proto.Json.bytes (Json.Encode.string text)
        , fuzz (Fuzz.list (Fuzz.intRange 0 255)) "a length no base64 has fails" <|
            \bytes ->
                let
                    text =
                        unpadded (Fuzzers.base64 bytes)
                in
                if modBy 4 (String.length text) == 0 then
                    fails Proto.Json.bytes (Json.Encode.string (text ++ "A"))

                else
                    Expect.pass
        ]



-- TIMESTAMPS


timestampProperties : Test
timestampProperties =
    describe "timestamps"
        [ fuzz Fuzzers.posix "a Time.Posix from 0001 to 9999 round-trips" <|
            roundTrips Proto.Json.encodeTimestamp Proto.Json.timestamp
        , fuzz2 Fuzzers.posix (Fuzz.listOfLengthBetween 1 6 (Fuzz.intRange 0 9)) "finer fractional digits are truncated, not rounded" <|
            \posix extra ->
                let
                    text =
                        Proto.Timestamp.toString posix

                    withFraction =
                        if String.contains "." text then
                            String.dropRight 1 text

                        else
                            String.dropRight 1 text ++ ".000"
                in
                Proto.Timestamp.fromString (withFraction ++ String.concat (List.map String.fromInt extra) ++ "Z")
                    |> Expect.equal (Just posix)
        , fuzz2 Fuzzers.posix (Fuzz.intRange -1439 1439) "a local time with its offset reads as the same instant" <|
            \posix minutes ->
                let
                    local =
                        Time.posixToMillis posix + minutes * 60000

                    offset =
                        (if minutes < 0 then
                            "-"

                         else
                            "+"
                        )
                            ++ String.padLeft 2 '0' (String.fromInt (abs minutes // 60))
                            ++ ":"
                            ++ String.padLeft 2 '0' (String.fromInt (modBy 60 (abs minutes)))
                in
                if local < -62135596800000 || local > 253402300799999 then
                    -- The local date would lie outside years 1 to 9999.
                    Expect.pass

                else
                    Proto.Timestamp.fromString (String.dropRight 1 (Proto.Timestamp.toString (Time.millisToPosix local)) ++ offset)
                        |> Expect.equal (Just posix)
        , fuzz (Fuzz.intRange 1 86400000) "a time outside years 1 to 9999 is refused" <|
            \ms ->
                Expect.all
                    [ \_ -> Proto.Timestamp.fromString (Proto.Timestamp.toString (Time.millisToPosix (-62135596800000 - ms))) |> Expect.equal Nothing
                    , \_ -> Proto.Timestamp.fromString (Proto.Timestamp.toString (Time.millisToPosix (253402300799999 + ms))) |> Expect.equal Nothing
                    ]
                    ()
        ]



-- DURATIONS


durationProperties : Test
durationProperties =
    describe "durations"
        [ fuzz Fuzzers.duration "a duration within ±315,576,000,000 s reads, and round-trips" <|
            \d ->
                Expect.all
                    [ \_ -> Proto.Duration.fromString d.text |> Expect.notEqual Nothing
                    , \_ -> roundTrips Proto.Json.encodeDuration Proto.Json.duration d.value
                    ]
                    ()
        , fuzz Fuzzers.duration "it is written with 0, 3, 6 or 9 fractional digits, the fewest that keep every nanosecond" <|
            \d ->
                let
                    fraction =
                        if d.nanos == 0 then
                            ""

                        else if modBy 1000000 d.nanos == 0 then
                            "." ++ String.padLeft 3 '0' (String.fromInt (d.nanos // 1000000))

                        else if modBy 1000 d.nanos == 0 then
                            "." ++ String.padLeft 6 '0' (String.fromInt (d.nanos // 1000))

                        else
                            "." ++ String.padLeft 9 '0' (String.fromInt d.nanos)

                    sign =
                        if d.negative && (d.seconds /= 0 || d.nanos /= 0) then
                            "-"

                        else
                            ""
                in
                Proto.Duration.toString d.value
                    |> Expect.equal (sign ++ String.fromInt d.seconds ++ fraction ++ "s")
        , fuzz Fuzzers.duration "milliseconds are those of the seconds and nanoseconds, toward zero" <|
            \d ->
                let
                    magnitude =
                        d.seconds * 1000 + d.nanos // 1000000
                in
                Proto.Duration.milliseconds d.value
                    |> Expect.equal
                        (if d.negative then
                            negate magnitude

                         else
                            magnitude
                        )
        , fuzz (Fuzz.map (\ms -> ms // 1000) Fuzzers.safeInt) "fromMilliseconds and milliseconds round-trip" <|
            \ms -> Proto.Duration.milliseconds (Proto.Duration.fromMilliseconds ms) |> Expect.equal ms
        , fuzz2 Fuzz.bool (Fuzz.intRange 1 1000000) "past ±315,576,000,000 s it is refused" <|
            \negative extra ->
                Proto.Duration.fromString
                    ((if negative then
                        "-"

                      else
                        ""
                     )
                        ++ String.fromInt (315576000000 + extra)
                        ++ "s"
                    )
                    |> Expect.equal Nothing
        ]



-- FIELD MASKS


fieldMaskProperties : Test
fieldMaskProperties =
    describe "field masks"
        [ fuzz (Fuzz.list Fuzzers.fieldMaskPath) "paths with proto field names round-trip through lowerCamelCase" <|
            \paths ->
                Expect.all
                    [ roundTrips Proto.Json.encodeFieldMask Proto.Json.fieldMask
                    , \_ ->
                        Json.Decode.decodeValue Json.Decode.string (Proto.Json.encodeFieldMask paths)
                            |> Result.map (String.contains "_")
                            |> Expect.equal (Ok False)
                    ]
                    paths
        ]



-- ENUMS


type Color
    = ColorUnspecified
    | ColorRed
    | ColorGreen


colors : List ( String, Int, Color )
colors =
    [ ( "COLOR_UNSPECIFIED", 0, ColorUnspecified )
    , ( "COLOR_RED", 1, ColorRed )
    , ( "COLOR_GREEN", 2, ColorGreen )
    , ( "COLOR_VERDE", 2, ColorGreen )
    ]


enumProperties : Test
enumProperties =
    let
        row =
            Fuzz.oneOfValues colors

        unknownName =
            Fuzz.map (\s -> "COLOR_" ++ s ++ "_X") Fuzz.string
    in
    describe "enums"
        [ fuzz row "every name and number reads as its value, under enum and enumOrZero" <|
            \( name, number, value ) ->
                Expect.all
                    [ \_ -> decodes (Proto.Json.enum "Color" ColorUnspecified colors) (Json.Encode.string name) value
                    , \_ -> decodes (Proto.Json.enum "Color" ColorUnspecified colors) (Json.Encode.int number) value
                    , \_ -> decodes (Proto.Json.enumOrZero "Color" ColorUnspecified colors) (Json.Encode.string name) value
                    , \_ -> decodes (Proto.Json.enumOrZero "Color" ColorUnspecified colors) (Json.Encode.int number) value
                    ]
                    ()
        , fuzz Fuzzers.kind "a generated enum round-trips by name" <|
            roundTrips Routes.V1.encodeKind Routes.V1.decodeKind
        , fuzz (Fuzz.intRange 3 2147483647) "an unknown number reads as the zero value, under both" <|
            \number ->
                Expect.all
                    [ \_ -> decodes (Proto.Json.enum "Color" ColorUnspecified colors) (Json.Encode.int number) ColorUnspecified
                    , \_ -> decodes (Proto.Json.enumOrZero "Color" ColorUnspecified colors) (Json.Encode.int number) ColorUnspecified
                    ]
                    ()
        , fuzz unknownName "an unknown name fails under enum, and reads as the zero value under enumOrZero" <|
            \name ->
                Expect.all
                    [ \_ -> fails (Proto.Json.enum "Color" ColorUnspecified colors) (Json.Encode.string name)
                    , \_ -> decodes (Proto.Json.enumOrZero "Color" ColorUnspecified colors) (Json.Encode.string name) ColorUnspecified
                    ]
                    ()
        ]



-- MAPS


mapProperties : Test
mapProperties =
    let
        uniqueBools =
            Fuzz.oneOfValues [ [], [ True ], [ False ], [ True, False ], [ False, True ] ]
    in
    describe "maps"
        [ fuzz (Fuzz.list (Fuzz.pair Fuzzers.awkwardString Fuzzers.int64Text)) "a string-keyed map round-trips, and is left out when empty" <|
            \pairs ->
                let
                    entries =
                        Dict.fromList pairs
                in
                case Proto.Json.dictField identity Proto.Json.encodeInt64 entries of
                    Nothing ->
                        Dict.isEmpty entries |> Expect.equal True

                    Just json ->
                        decodes (Json.Decode.dict Proto.Json.int64) json entries
        , fuzz (Fuzz.list (Fuzz.pair (Fuzz.intRange -2147483648 2147483647) Fuzzers.awkwardString)) "an int-keyed map round-trips" <|
            \pairs ->
                let
                    entries =
                        Dict.fromList pairs
                in
                case Proto.Json.dictField String.fromInt Json.Encode.string entries of
                    Nothing ->
                        Dict.isEmpty entries |> Expect.equal True

                    Just json ->
                        decodes (Proto.Json.int32Dict Json.Decode.string) json entries
        , fuzz (Fuzz.list (Fuzz.pair Fuzzers.int64Text Fuzzers.awkwardString)) "an int64-keyed map round-trips, its keys as held" <|
            \pairs ->
                let
                    entries =
                        Dict.fromList pairs
                in
                case Proto.Json.dictField identity Json.Encode.string entries of
                    Nothing ->
                        Dict.isEmpty entries |> Expect.equal True

                    Just json ->
                        decodes (Proto.Json.int64Dict Json.Decode.string) json entries
        , fuzz2 uniqueBools (Fuzz.pair Fuzzers.awkwardString Fuzzers.awkwardString) "a bool-keyed map round-trips in order" <|
            \keys ( first, second ) ->
                let
                    pairs =
                        List.map2 Tuple.pair keys [ first, second ]
                in
                Expect.all
                    [ roundTrips (Proto.Json.encodeBoolMap Json.Encode.string) (Proto.Json.boolMap Json.Decode.string)
                    , \_ ->
                        Proto.Json.boolMapField Json.Encode.string pairs
                            |> Maybe.map (Json.Encode.encode 0)
                            |> Expect.equal
                                (if List.isEmpty pairs then
                                    Nothing

                                 else
                                    Just (Json.Encode.encode 0 (Proto.Json.encodeBoolMap Json.Encode.string pairs))
                                )
                    ]
                    pairs
        ]



-- REPEATED


repeatedProperties : Test
repeatedProperties =
    describe "repeated fields"
        [ fuzz (Fuzz.list Fuzzers.awkwardString) "a list round-trips, and is left out when empty" <|
            \items ->
                case Proto.Json.repeatedField Json.Encode.string items of
                    Nothing ->
                        items |> Expect.equal []

                    Just json ->
                        decodes (Json.Decode.list Json.Decode.string) json items
        ]



-- STRUCT, LISTVALUE, VALUE


jsonValueProperties : Test
jsonValueProperties =
    let
        encoded =
            Result.map (Json.Encode.encode 0)
    in
    describe "Struct, ListValue and Value"
        [ fuzz (Fuzz.list (Fuzz.pair Fuzzers.awkwardString (Fuzzers.json 2))) "a Struct round-trips" <|
            \members ->
                let
                    struct =
                        Dict.fromList members
                in
                Json.Decode.decodeValue Proto.Json.struct (Proto.Json.encodeStruct struct)
                    |> Result.map Proto.Json.encodeStruct
                    |> encoded
                    |> Expect.equal (Ok (Json.Encode.encode 0 (Proto.Json.encodeStruct struct)))
        , fuzz (Fuzz.list (Fuzzers.json 2)) "a ListValue round-trips" <|
            \items ->
                Json.Decode.decodeValue Proto.Json.listValue (Proto.Json.encodeListValue items)
                    |> Result.map Proto.Json.encodeListValue
                    |> encoded
                    |> Expect.equal (Ok (Json.Encode.encode 0 (Proto.Json.encodeListValue items)))
        , fuzz (Fuzzers.json 3) "a Value passes through as it is" <|
            \value ->
                Json.Decode.decodeString Json.Decode.value (Json.Encode.encode 0 value)
                    |> encoded
                    |> Expect.equal (Ok (Json.Encode.encode 0 value))
        , fuzz (Fuzz.list (Fuzzers.json 1)) "Struct refuses an array and ListValue an object" <|
            \items ->
                Expect.all
                    [ \_ -> fails Proto.Json.struct (Json.Encode.list identity items)
                    , \_ -> fails Proto.Json.listValue (Json.Encode.object (List.indexedMap (\i v -> ( String.fromInt i, v )) items))
                    ]
                    ()
        ]



-- OMITTING DEFAULTS


{-| The generated codecs of `Routes.V1`'s messages: each message's default
encodes to `{}`, and `{}` decodes to it.
-}
defaultsTest : String -> (a -> Value) -> Decoder a -> a -> Test
defaultsTest name encode decoder zero =
    test (name ++ ": the default encodes to {}, and {} decodes to the default") <|
        \_ ->
            Expect.all
                [ \_ -> Json.Encode.encode 0 (encode zero) |> Expect.equal "{}"
                , \_ -> Json.Decode.decodeString decoder "{}" |> Expect.equal (Ok zero)
                ]
                ()


{-| The keys of `Everything`'s fields without presence, with the JSON each
holds at its default.
-}
implicitDefaults : List ( String, String )
implicitDefaults =
    [ ( "name", "\"\"" )
    , ( "count", "0" )
    , ( "big", "\"0\"" )
    , ( "ubig", "\"0\"" )
    , ( "flag", "false" )
    , ( "ratio", "0" )
    , ( "scale", "0" )
    , ( "data", "\"\"" )
    , ( "kind", "\"KIND_UNSPECIFIED\"" )
    , ( "tags", "[]" )
    , ( "kinds", "[]" )
    , ( "numbers", "[]" )
    ]


omitDefaultsProperties : Test
omitDefaultsProperties =
    let
        encode =
            Routes.V1.encodeEverything >> Json.Encode.encode 0
    in
    describe "the generated codecs omit defaults"
        [ defaultsTest "Everything" Routes.V1.encodeEverything Routes.V1.decodeEverything Routes.V1.defaultEverything
        , defaultsTest "Inner" Routes.V1.encodeInner Routes.V1.decodeInner Routes.V1.defaultInner
        , defaultsTest "Deep" Routes.V1.encodeDeep Routes.V1.decodeDeep Routes.V1.defaultDeep
        , defaultsTest "GetMessageRequest" Routes.V1.encodeGetMessageRequest Routes.V1.decodeGetMessageRequest Routes.V1.defaultGetMessageRequest
        , defaultsTest "Message" Routes.V1.encodeMessage Routes.V1.decodeMessage Routes.V1.defaultMessage
        , defaultsTest "UpdateMessageRequest" Routes.V1.encodeUpdateMessageRequest Routes.V1.decodeUpdateMessageRequest Routes.V1.defaultUpdateMessageRequest
        , defaultsTest "FileRequest" Routes.V1.encodeFileRequest Routes.V1.decodeFileRequest Routes.V1.defaultFileRequest
        , defaultsTest "Resource" Routes.V1.encodeResource Routes.V1.decodeResource Routes.V1.defaultResource
        , defaultsTest "UpdateResourceRequest" Routes.V1.encodeUpdateResourceRequest Routes.V1.decodeUpdateResourceRequest Routes.V1.defaultUpdateResourceRequest
        , fuzz (Fuzzers.everything Fuzzers.nonNegativeZeroFloat) "encode (decode (encode x)) == encode x" <|
            \x ->
                Json.Decode.decodeString Routes.V1.decodeEverything (encode x)
                    |> Result.map encode
                    |> Expect.equal (Ok (encode x))
        , fuzz
            (Fuzzers.everything
                (Fuzz.map
                    (\f ->
                        if isNaN f then
                            0

                        else
                            f
                    )
                    Fuzzers.nonNegativeZeroFloat
                )
            )
            "decode (encode x) == x"
          <|
            \x -> Json.Decode.decodeString Routes.V1.decodeEverything (encode x) |> Expect.equal (Ok x)
        , fuzz
            (Fuzzers.resource
                (Fuzz.map
                    (\f ->
                        if isNaN f then
                            0

                        else
                            f
                    )
                    Fuzzers.nonNegativeZeroFloat
                )
            )
            "a message's map fields round-trip, and are left out when empty"
          <|
            \x ->
                Expect.all
                    [ roundTrips Routes.V1.encodeResource Routes.V1.decodeResource
                    , \_ ->
                        Json.Decode.decodeValue (Json.Decode.keyValuePairs Json.Decode.value) (Routes.V1.encodeResource x)
                            |> Result.map (List.map Tuple.first >> List.filter (\key -> List.member key [ "labels", "kinds", "weights" ]))
                            |> Expect.equal
                                (Ok
                                    (List.filterMap identity
                                        [ if Dict.isEmpty x.labels then
                                            Nothing

                                          else
                                            Just "labels"
                                        , if Dict.isEmpty x.kinds then
                                            Nothing

                                          else
                                            Just "kinds"
                                        , if List.isEmpty x.weights then
                                            Nothing

                                          else
                                            Just "weights"
                                        ]
                                    )
                                )
                    ]
                    x
        , fuzz (Fuzzers.everything Fuzzers.nonNegativeZeroFloat) "no field without presence is written at its default" <|
            \x ->
                Json.Decode.decodeString (Json.Decode.keyValuePairs Json.Decode.value) (encode x)
                    |> Result.map
                        (List.filter
                            (\( key, value ) -> List.member ( key, Json.Encode.encode 0 value ) implicitDefaults)
                            >> List.map Tuple.first
                        )
                    |> Expect.equal (Ok [])
        , fuzz (Fuzzers.everything Fuzzers.float) "a field with presence is written when set, at its default too" <|
            \x ->
                let
                    keys =
                        Json.Decode.decodeString (Json.Decode.keyValuePairs Json.Decode.value) (encode x)
                            |> Result.map (List.map Tuple.first)
                            |> Result.withDefault []

                    present key value =
                        List.member key keys |> Expect.equal (value /= Nothing)
                in
                Expect.all
                    [ \_ -> present "maybeCount" (Maybe.map (\_ -> ()) x.maybeCount)
                    , \_ -> present "maybeName" (Maybe.map (\_ -> ()) x.maybeName)
                    , \_ -> present "at" (Maybe.map (\_ -> ()) x.at)
                    , \_ -> present "wait" (Maybe.map (\_ -> ()) x.wait)
                    , \_ -> present "mask" (Maybe.map (\_ -> ()) x.mask)
                    , \_ -> present "limit" (Maybe.map (\_ -> ()) x.limit)
                    , \_ -> present "label" (Maybe.map (\_ -> ()) x.label)
                    , \_ -> present "inner" (Maybe.map (\_ -> ()) x.inner)
                    ]
                    ()
        ]
