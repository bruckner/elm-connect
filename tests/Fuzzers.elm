module Fuzzers exposing
    ( awkwardString
    , base64
    , deep
    , duration
    , everything
    , fieldMaskPath
    , float
    , getMessageRequest
    , inner
    , int64Text
    , json
    , kind
    , nonNegativeZeroFloat
    , percentDecode
    , posix
    , resource
    , safeInt
    , uint64Text
    , unsafeInt64Text
    )

{-| Fuzzers for the property tests: values across the whole range a proto type
allows, strings with the characters a URL must escape, and the generated
messages of `Routes.V1`, plus an independent percent-decoder.
-}

import Bitwise
import Dict
import Fuzz exposing (Fuzzer)
import Json.Encode
import Proto.Duration
import Routes.V1
import Time



-- STRINGS


{-| A short string mixing ASCII with what a URL must escape: reserved and
delimiting characters, space, `%`, `+`, and characters of two, three and four
UTF-8 bytes; now and then `__proto__`, the one map key a JavaScript object
cannot hold as a property. Never a lone surrogate, which no proto3 string
holds.
-}
awkwardString : Fuzzer String
awkwardString =
    Fuzz.frequency
        [ ( 19
          , Fuzz.oneOf
                [ Fuzz.asciiChar
                , Fuzz.oneOfValues
                    [ '/', '?', '#', '&', '=', '%', ' ', '+', ':', '@', '[', ']', '-', '.', '_', '~', 'é', '✓' ]
                , Fuzz.map Char.fromCode (Fuzz.intRange 0x80 0xD7FF)
                , Fuzz.map Char.fromCode (Fuzz.intRange 0x00010000 0x0010FFFF)
                ]
                |> Fuzz.listOfLengthBetween 0 10
                |> Fuzz.map String.fromList
          )
        , ( 1, Fuzz.constant "__proto__" )
        ]



-- INTEGERS


{-| An `Int` anywhere in ±(2^53 − 1), where Elm's `Int` is exact. Fuzz's own
integer fuzzers draw at most 32 bits.
-}
safeInt : Fuzzer Int
safeInt =
    Fuzz.oneOf
        [ Fuzz.int
        , Fuzz.oneOfValues [ 9007199254740991, -9007199254740991, 4294967296, -4294967296 ]
        , Fuzz.map3
            (\negative high low ->
                (high * 134217728 + low)
                    * (if negative then
                        -1

                       else
                        1
                      )
            )
            Fuzz.bool
            (Fuzz.intRange 0 67108863)
            (Fuzz.intRange 0 134217727)
        ]


{-| `count` decimal digits, the first not `0` and at most `top`.
-}
digits : Int -> Int -> Fuzzer String
digits top count =
    Fuzz.map2 (\first rest -> String.fromInt first ++ String.concat (List.map String.fromInt rest))
        (Fuzz.intRange 1 top)
        (Fuzz.listOfLength (count - 1) (Fuzz.intRange 0 9))


{-| The canonical decimal string of an `int64`, across the whole range: every
length of 1 to 19 digits, and the bounds.
-}
int64Text : Fuzzer String
int64Text =
    Fuzz.oneOf
        [ Fuzz.oneOfValues
            [ "0", "9223372036854775807", "-9223372036854775808", "9007199254740992", "-9007199254740993" ]
        , Fuzz.map2
            (\negative text ->
                if negative then
                    "-" ++ text

                else
                    text
            )
            Fuzz.bool
            (Fuzz.intRange 1 19
                |> Fuzz.andThen
                    (\count ->
                        digits
                            (if count == 19 then
                                8

                             else
                                9
                            )
                            count
                    )
            )
        ]


{-| The canonical decimal string of a `uint64`: 1 to 20 digits, and the
bounds.
-}
uint64Text : Fuzzer String
uint64Text =
    Fuzz.oneOf
        [ Fuzz.oneOfValues [ "0", "18446744073709551615", "9223372036854775808" ]
        , Fuzz.intRange 1 20
            |> Fuzz.andThen
                (\count ->
                    digits
                        (if count == 20 then
                            1

                         else
                            9
                        )
                        count
                )
        ]


{-| A 64-bit integer an Elm `Int` cannot hold exactly: magnitude 2^53 or more,
up to 19 digits.
-}
unsafeInt64Text : Fuzzer String
unsafeInt64Text =
    Fuzz.map2
        (\negative text ->
            if negative then
                "-" ++ text

            else
                text
        )
        Fuzz.bool
        (Fuzz.oneOf
            [ Fuzz.oneOfValues [ "9007199254740992", "9007199254740993", "9223372036854775807" ]
            , Fuzz.intRange 17 19 |> Fuzz.andThen (digits 8)
            ]
        )



-- FLOATS


{-| A `double`: Fuzz's floats (NaN and the infinities included), every
magnitude from subnormal to the largest finite value, and the extremes.
-}
float : Fuzzer Float
float =
    Fuzz.oneOf
        [ Fuzz.float
        , Fuzz.map2 (\mantissa exponent -> mantissa * 10 ^ toFloat exponent)
            Fuzz.niceFloat
            (Fuzz.intRange -300 300)
        , Fuzz.oneOfValues
            [ 1.7976931348623157e308, -1.7976931348623157e308, 5.0e-324, 2.2250738585072014e-308, negate 0, 1.0e21, 1.0e-7, 0.1 ]
        ]


{-| [`float`](#float) without `-0`, which the runtime writes as `0` (design
§3.4), so where a law depends on the sign of zero it is tested apart.
-}
nonNegativeZeroFloat : Fuzzer Float
nonNegativeZeroFloat =
    Fuzz.map
        (\x ->
            if x == 0 then
                0

            else
                x
        )
        float



-- BYTES


{-| Bytes as standard base64 with padding, as protobuf writes them.
-}
base64 : List Int -> String
base64 bytes =
    case bytes of
        a :: b :: c :: rest ->
            group a b c ++ base64 rest

        [ a, b ] ->
            String.left 3 (group a b 0) ++ "="

        [ a ] ->
            String.left 2 (group a 0 0) ++ "=="

        [] ->
            ""


group : Int -> Int -> Int -> String
group a b c =
    let
        n =
            a * 65536 + b * 256 + c

        letter shift =
            Bitwise.and 63 (Bitwise.shiftRightBy shift n)
                |> (\i -> String.slice i (i + 1) "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
    in
    String.concat (List.map letter [ 18, 12, 6, 0 ])



-- WELL-KNOWN TYPES


{-| A `Time.Posix` anywhere in proto's range, 0001-01-01T00:00:00Z to
9999-12-31T23:59:59.999Z, to the millisecond. Days since 1970 are drawn
apart from the time of day, since Fuzz draws at most 32 bits at once.
-}
posix : Fuzzer Time.Posix
posix =
    Fuzz.oneOf
        [ Fuzz.map2 (\day ms -> Time.millisToPosix (day * 86400000 + ms))
            (Fuzz.intRange -719162 2932896)
            (Fuzz.oneOf [ Fuzz.intRange 0 86399999, Fuzz.map ((*) 1000) (Fuzz.intRange 0 86399) ])
        , Fuzz.oneOfValues
            [ Time.millisToPosix -62135596800000
            , Time.millisToPosix 253402300799999
            , Time.millisToPosix 0
            , Time.millisToPosix -1
            ]
        ]


{-| A duration as its seconds and nanoseconds, of the same sign, within
protobuf's ±315,576,000,000 s, and the text that writes it with all nine
fractional digits.
-}
duration : Fuzzer { negative : Bool, seconds : Int, nanos : Int, text : String, value : Proto.Duration.Duration }
duration =
    Fuzz.map3
        (\negative seconds nanos ->
            let
                text =
                    (if negative then
                        "-"

                     else
                        ""
                    )
                        ++ String.fromInt seconds
                        ++ "."
                        ++ String.padLeft 9 '0' (String.fromInt nanos)
                        ++ "s"
            in
            { negative = negative
            , seconds = seconds
            , nanos = nanos
            , text = text
            , value =
                Proto.Duration.fromString text
                    |> Maybe.withDefault (Proto.Duration.fromMilliseconds 0)
            }
        )
        Fuzz.bool
        (Fuzz.oneOf
            [ Fuzz.intRange 0 1000
            , Fuzz.map2 (\high low -> high * 1000000 + low) (Fuzz.intRange 0 315575) (Fuzz.intRange 0 999999)
            , Fuzz.oneOfValues [ 315576000000, 0 ]
            ]
        )
        (Fuzz.oneOf
            [ Fuzz.intRange 0 999999999
            , Fuzz.map ((*) 1000000) (Fuzz.intRange 0 999)
            , Fuzz.map ((*) 1000) (Fuzz.intRange 0 999999)
            , Fuzz.constant 0
            ]
        )


{-| A field mask path with proto field names: one to three names of lowercase
words joined by `_`, each word starting with a letter, which is what makes the
lowerCamelCase form reversible.
-}
fieldMaskPath : Fuzzer String
fieldMaskPath =
    let
        word =
            Fuzz.map2 (\first rest -> String.fromList (first :: rest))
                (Fuzz.map Char.fromCode (Fuzz.intRange 97 122))
                (Fuzz.listOfLengthBetween 0
                    4
                    (Fuzz.oneOf [ Fuzz.map Char.fromCode (Fuzz.intRange 97 122), Fuzz.map Char.fromCode (Fuzz.intRange 48 57) ])
                )

        name =
            Fuzz.listOfLengthBetween 1 3 word |> Fuzz.map (String.join "_")
    in
    Fuzz.listOfLengthBetween 1 3 name |> Fuzz.map (String.join ".")


{-| Any JSON value, nested up to `depth` levels, with finite numbers.
-}
json : Int -> Fuzzer Json.Encode.Value
json depth =
    let
        leaves =
            [ Fuzz.constant Json.Encode.null
            , Fuzz.map Json.Encode.bool Fuzz.bool
            , Fuzz.map Json.Encode.float Fuzz.niceFloat
            , Fuzz.map Json.Encode.string awkwardString
            ]
    in
    if depth <= 0 then
        Fuzz.oneOf leaves

    else
        Fuzz.oneOf
            (leaves
                ++ [ Fuzz.map (Json.Encode.list identity) (Fuzz.listOfLengthBetween 0 3 (json (depth - 1)))
                   , Fuzz.map Json.Encode.object
                        (Fuzz.listOfLengthBetween 0 3 (Fuzz.pair awkwardString (json (depth - 1))))
                   ]
            )



-- ROUTES.V1


kind : Fuzzer Routes.V1.Kind
kind =
    Fuzz.oneOfValues [ Routes.V1.KindUnspecified, Routes.V1.KindText, Routes.V1.KindImage ]


short : Fuzzer a -> Fuzzer (List a)
short =
    Fuzz.listOfLengthBetween 0 3


{-| An `Everything`, each field at its default about a third of the time,
its floats from `floats`.
-}
everything : Fuzzer Float -> Fuzzer Routes.V1.Everything
everything floats =
    Fuzz.constant Routes.V1.Everything
        |> Fuzz.andMap (orDefault "" awkwardString)
        |> Fuzz.andMap (orDefault 0 (Fuzz.intRange -2147483648 2147483647))
        |> Fuzz.andMap (orDefault "0" int64Text)
        |> Fuzz.andMap (orDefault "0" uint64Text)
        |> Fuzz.andMap Fuzz.bool
        |> Fuzz.andMap (orDefault 0 floats)
        |> Fuzz.andMap (orDefault 0 floats)
        |> Fuzz.andMap (orDefault "" (Fuzz.map base64 (short (Fuzz.intRange 0 255))))
        |> Fuzz.andMap kind
        |> Fuzz.andMap (short awkwardString)
        |> Fuzz.andMap (short kind)
        |> Fuzz.andMap (short (Fuzz.intRange -2147483648 2147483647))
        |> Fuzz.andMap (Fuzz.maybe (Fuzz.intRange -2147483648 2147483647))
        |> Fuzz.andMap (Fuzz.maybe awkwardString)
        |> Fuzz.andMap (Fuzz.maybe posix)
        |> Fuzz.andMap (Fuzz.maybe (Fuzz.map .value duration))
        |> Fuzz.andMap (Fuzz.maybe (short fieldMaskPath))
        |> Fuzz.andMap (Fuzz.maybe (Fuzz.oneOf [ Fuzz.constant 0, Fuzz.intRange -2147483648 2147483647 ]))
        |> Fuzz.andMap (Fuzz.maybe (Fuzz.oneOf [ Fuzz.constant "", awkwardString ]))
        |> Fuzz.andMap (Fuzz.maybe inner)
        |> Fuzz.andMap
            (Fuzz.oneOf
                [ Fuzz.constant Routes.V1.EverythingChoiceUnset
                , Fuzz.map Routes.V1.EverythingChoiceText (Fuzz.oneOf [ Fuzz.constant "", awkwardString ])
                , Fuzz.map Routes.V1.EverythingChoiceNumber (Fuzz.oneOf [ Fuzz.constant 0, Fuzz.int ])
                ]
            )


orDefault : a -> Fuzzer a -> Fuzzer a
orDefault zero fuzzer =
    Fuzz.frequency [ ( 1, Fuzz.constant zero ), ( 2, fuzzer ) ]


inner : Fuzzer Routes.V1.Inner
inner =
    Fuzz.map2 Routes.V1.Inner (orDefault "" awkwardString) (Fuzz.maybe deep)


deep : Fuzzer Routes.V1.Deep
deep =
    Fuzz.map2 Routes.V1.Deep (orDefault 0 (Fuzz.intRange -2147483648 2147483647)) (short awkwardString)


getMessageRequest : Fuzzer Routes.V1.GetMessageRequest
getMessageRequest =
    Fuzz.map5 Routes.V1.GetMessageRequest
        (orDefault "" awkwardString)
        (orDefault "0" int64Text)
        (Fuzz.maybe (Fuzz.map Routes.V1.GetMessageRequestSubMessage (orDefault "" awkwardString)))
        (orDefault "" awkwardString)
        (orDefault "" awkwardString)


{-| A `Resource`, its map fields holding none to three entries, its weights
from `floats`.
-}
resource : Fuzzer Float -> Fuzzer Routes.V1.Resource
resource floats =
    Fuzz.map5 Routes.V1.Resource
        (orDefault "" awkwardString)
        (orDefault "" awkwardString)
        (short (Fuzz.pair awkwardString awkwardString) |> Fuzz.map Dict.fromList)
        (short (Fuzz.pair int64Text kind) |> Fuzz.map Dict.fromList)
        (Fuzz.map2 (\keys values -> List.map2 Tuple.pair keys values)
            (Fuzz.oneOfValues [ [], [ True ], [ False ], [ True, False ], [ False, True ] ])
            (Fuzz.listOfLength 2 floats)
        )



-- PERCENT-DECODING


{-| Decode `%XX` escapes and the UTF-8 they spell; `Nothing` for a malformed
escape, invalid UTF-8, or a character a percent-encoder should have escaped
(anything outside RFC 3986's unreserved set but `/`). Written apart from the
runtime's own decoder so that the two cannot share a mistake.
-}
percentDecode : String -> Maybe String
percentDecode text =
    toBytes (String.toList text) [] |> Maybe.andThen (\bytes -> fromUtf8 bytes [])


toBytes : List Char -> List Int -> Maybe (List Int)
toBytes chars acc =
    case chars of
        [] ->
            Just (List.reverse acc)

        '%' :: high :: low :: rest ->
            Maybe.map2 (\h l -> h * 16 + l) (hex high) (hex low)
                |> Maybe.andThen (\byte -> toBytes rest (byte :: acc))

        char :: rest ->
            if Char.isAlphaNum char && Char.toCode char < 128 || String.contains (String.fromChar char) "-._~/" then
                toBytes rest (Char.toCode char :: acc)

            else
                Nothing


hex : Char -> Maybe Int
hex char =
    -- Uppercase only: the runtime writes uppercase hex digits (RFC 3986 §2.1).
    String.indexes (String.fromChar char) "0123456789ABCDEF" |> List.head


fromUtf8 : List Int -> List Char -> Maybe String
fromUtf8 bytes acc =
    let
        continue lead count rest =
            let
                tail =
                    List.take count rest
            in
            if List.length tail == count && List.all (\b -> Bitwise.and 0xC0 b == 0x80) tail then
                Just ( List.foldl (\b code -> code * 64 + Bitwise.and 0x3F b) lead tail, List.drop count rest )

            else
                Nothing

        minimal code count =
            -- Overlong forms and surrogates are not UTF-8.
            (code >= (List.drop count [ 0, 0x80, 0x0800, 0x00010000 ] |> List.head |> Maybe.withDefault 0))
                && not (code >= 0xD800 && code <= 0xDFFF)
                && code
                <= 0x0010FFFF
    in
    case bytes of
        [] ->
            Just (String.fromList (List.reverse acc))

        b :: rest ->
            let
                decoded =
                    if b < 0x80 then
                        Just ( b, rest )

                    else if Bitwise.and 0xE0 b == 0xC0 then
                        continue (Bitwise.and 0x1F b) 1 rest |> Maybe.andThen (check 1)

                    else if Bitwise.and 0xF0 b == 0xE0 then
                        continue (Bitwise.and 0x0F b) 2 rest |> Maybe.andThen (check 2)

                    else if Bitwise.and 0xF8 b == 0xF0 then
                        continue (Bitwise.and 0x07 b) 3 rest |> Maybe.andThen (check 3)

                    else
                        Nothing

                check count ( code, after ) =
                    if minimal code count then
                        Just ( code, after )

                    else
                        Nothing
            in
            decoded |> Maybe.andThen (\( code, after ) -> fromUtf8 after (Char.fromCode code :: acc))
