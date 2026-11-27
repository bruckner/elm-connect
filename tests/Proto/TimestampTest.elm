module Proto.TimestampTest exposing (suite)

import Bytes exposing (Bytes)
import Bytes.Decode
import Bytes.Encode
import Expect
import Fuzz
import Fuzzers
import Proto.Binary as B
import Proto.Error
import Proto.Internal.Timestamp
import Proto.Json
import Proto.Timestamp as Timestamp exposing (Timestamp)
import Test exposing (Test, describe, fuzz, fuzz2, test)
import Time


suite : Test
suite =
    describe "Proto.Timestamp"
        [ parsing
        , printing
        , roundTrips
        , posix
        , exact
        , fromBinary
        ]


{-| `fromString` gives this many seconds and nanoseconds.
-}
parses : String -> Int -> Int -> Expect.Expectation
parses text seconds nanos =
    Timestamp.fromString text
        |> Maybe.map Timestamp.toSecondsAndNanos
        |> Expect.equal (Just { seconds = seconds, nanos = nanos })


rejects : String -> Expect.Expectation
rejects text =
    Timestamp.fromString text
        |> Expect.equal Nothing


{-| A valid timestamp; the epoch for fields out of range, which the tests
calling it never give.
-}
instant : Int -> Int -> Timestamp
instant seconds nanos =
    Timestamp.fromSecondsAndNanos seconds nanos |> Maybe.withDefault epoch


{-| The fields as held, which for valid timestamps order as the instants do.
-}
fields : Timestamp -> ( Int, Int )
fields t =
    let
        parts =
            Timestamp.toSecondsAndNanos t
    in
    ( parts.seconds, parts.nanos )


epoch : Timestamp
epoch =
    Timestamp.fromPosix (Time.millisToPosix 0)


prints : Int -> Int -> String -> Expect.Expectation
prints seconds nanos text =
    Timestamp.toString (instant seconds nanos)
        |> Expect.equal (Just text)


parsing : Test
parsing =
    describe "fromString"
        [ test "a fraction of 100,000 digits is rejected without exhausting the stack" <|
            \_ -> rejects ("1970-01-01T00:00:00." ++ String.repeat 100000 "1" ++ "Z")
        , test "the epoch" <|
            \_ -> parses "1970-01-01T00:00:00Z" 0 0
        , test "a date and time" <|
            \_ -> parses "2026-10-10T17:19:45Z" 1791652785 0
        , test "milliseconds" <|
            \_ -> parses "1970-01-01T00:00:01.500Z" 1 500000000
        , test "one fractional digit" <|
            \_ -> parses "1970-01-01T00:00:01.5Z" 1 500000000
        , test "microseconds" <|
            \_ -> parses "1970-01-01T00:00:00.000001Z" 0 1000
        , test "every nanosecond is kept" <|
            \_ -> parses "1970-01-01T00:00:00.123456789Z" 0 123456789
        , test "seven digits are kept, never rounded" <|
            \_ -> parses "1970-01-01T00:00:00.9999999Z" 0 999999900
        , test "before the epoch, the nanoseconds count forward from the second" <|
            \_ -> parses "1969-12-31T23:59:59.9999999Z" -1 999999900
        , test "before the epoch, a fraction counts forward" <|
            \_ -> parses "1969-12-31T23:59:59.250Z" -1 250000000
        , test "a positive offset is applied" <|
            \_ -> parses "1970-01-01T02:00:00+02:00" 0 0
        , test "a negative offset is applied" <|
            \_ -> parses "1969-12-31T19:30:00-04:30" 0 0
        , test "an offset keeps the fraction" <|
            \_ -> parses "1970-01-01T02:00:00.000000001+02:00" 0 1
        , test "an offset can cross a day" <|
            \_ -> parses "1970-01-02T00:30:00+01:00" (23 * 3600 + 30 * 60) 0
        , test "a lowercase t is rejected" <|
            \_ -> rejects "1970-01-01t00:00:00Z"
        , test "a lowercase z is rejected" <|
            \_ -> rejects "1970-01-01T00:00:00z"
        , test "a lowercase z after a fraction is rejected" <|
            \_ -> rejects "1970-01-01T00:00:00.5z"
        , test "a leap second is read as the second before it" <|
            \_ -> parses "1972-06-30T23:59:60Z" 78796799 0
        , test "a leap second keeps its fraction" <|
            \_ -> parses "1972-06-30T23:59:60.5Z" 78796799 500000000
        , test "29 February of a leap year" <|
            \_ -> parses "2000-02-29T00:00:00Z" 951782400 0
        , test "the last nanosecond of 29 February" <|
            \_ -> parses "2000-02-29T23:59:59.999999999Z" 951868799 999999999
        , test "the last nanosecond of February of a century" <|
            \_ -> parses "1900-02-28T23:59:59.999999999Z" -2203891201 999999999
        , test "the last nanosecond of a year" <|
            \_ -> parses "1999-12-31T23:59:59.999999999Z" 946684799 999999999
        , test "the earliest timestamp" <|
            \_ -> parses "0001-01-01T00:00:00Z" -62135596800 0
        , test "the latest timestamp" <|
            \_ -> parses "9999-12-31T23:59:59.999999999Z" 253402300799 999999999
        , test "year 0 is out of range" <|
            \_ -> rejects "0000-12-31T23:59:59Z"
        , test "an offset that moves past year 9999 is out of range" <|
            \_ -> rejects "9999-12-31T23:59:59-01:00"
        , test "an offset that moves before year 1 is out of range" <|
            \_ -> rejects "0001-01-01T00:00:00.999999999+00:01"
        , test "29 February of a common year" <|
            \_ -> rejects "2001-02-29T00:00:00Z"
        , test "29 February of a century" <|
            \_ -> rejects "1900-02-29T00:00:00Z"
        , test "month 13" <|
            \_ -> rejects "2026-13-01T00:00:00Z"
        , test "hour 24" <|
            \_ -> rejects "2026-01-01T24:00:00Z"
        , test "second 61" <|
            \_ -> rejects "2026-01-01T00:00:61Z"
        , test "no zone" <|
            \_ -> rejects "2026-01-01T00:00:00"
        , test "a space instead of T" <|
            \_ -> rejects "2026-01-01 00:00:00Z"
        , test "an empty fraction" <|
            \_ -> rejects "2026-01-01T00:00:00.Z"
        , test "ten fractional digits" <|
            \_ -> rejects "2026-01-01T00:00:00.1234567890Z"
        , test "an offset without a colon" <|
            \_ -> rejects "2026-01-01T00:00:00+0100"
        , test "a signed year" <|
            \_ -> rejects "+026-01-01T00:00:00Z"
        , test "trailing text" <|
            \_ -> rejects "2026-01-01T00:00:00Zx"
        , test "an empty string" <|
            \_ -> rejects ""
        ]


printing : Test
printing =
    describe "toString"
        [ test "a whole second has no fraction" <|
            \_ -> prints 0 0 "1970-01-01T00:00:00Z"
        , test "milliseconds print three digits" <|
            \_ -> prints 1 500000000 "1970-01-01T00:00:01.500Z"
        , test "microseconds print six digits" <|
            \_ -> prints 1 500000 "1970-01-01T00:00:01.000500Z"
        , test "nanoseconds print nine digits" <|
            \_ -> prints 1 5 "1970-01-01T00:00:01.000000005Z"
        , test "before the epoch" <|
            \_ -> prints -1 250000000 "1969-12-31T23:59:59.250Z"
        , test "a nanosecond before the epoch" <|
            \_ -> prints -1 999999999 "1969-12-31T23:59:59.999999999Z"
        , test "the earliest timestamp" <|
            \_ -> prints -62135596800 0 "0001-01-01T00:00:00Z"
        , test "the earliest timestamp's first nanosecond" <|
            \_ -> prints -62135596800 1 "0001-01-01T00:00:00.000000001Z"
        , test "the latest timestamp" <|
            \_ -> prints 253402300799 999999999 "9999-12-31T23:59:59.999999999Z"
        , test "a leap day" <|
            \_ -> prints 951782400 0 "2000-02-29T00:00:00Z"
        , test "the last nanosecond of a leap day" <|
            \_ -> prints 951868799 999999999 "2000-02-29T23:59:59.999999999Z"
        , test "the first nanosecond after a century's February" <|
            \_ -> prints -2203891200 1 "1900-03-01T00:00:00.000000001Z"
        ]


roundTrips : Test
roundTrips =
    describe "round trips"
        [ test "text of 0, 3, 6 and 9 digits, and both ends of the range" <|
            \_ ->
                let
                    texts =
                        [ "2026-10-10T17:19:45Z"
                        , "2026-10-10T17:19:45.250Z"
                        , "2026-10-10T17:19:45.000250Z"
                        , "2026-10-10T17:19:45.000000250Z"
                        , "1969-12-31T23:59:59.999999999Z"
                        , "0001-01-01T00:00:00Z"
                        , "0001-01-01T00:00:00.000000001Z"
                        , "9999-12-31T23:59:59Z"
                        , "9999-12-31T23:59:59.999999999Z"
                        ]
                in
                List.map (Timestamp.fromString >> Maybe.andThen Timestamp.toString) texts
                    |> Expect.equal (List.map Just texts)
        , fuzz Fuzzers.timestamp "toString then fromString" <|
            \t ->
                Timestamp.toString t
                    |> Maybe.andThen Timestamp.fromString
                    |> Expect.equal (Just t)
        , fuzz Fuzzers.timestamp "toSecondsAndNanos then fromSecondsAndNanos" <|
            \t ->
                let
                    parts =
                        Timestamp.toSecondsAndNanos t
                in
                Timestamp.fromSecondsAndNanos parts.seconds parts.nanos
                    |> Expect.equal (Just t)
        ]



-- TIME.POSIX


posix : Test
posix =
    describe "fromPosix and toPosix"
        [ fuzz Fuzzers.posix "fromPosix is exact: toPosix gives the same Time.Posix back" <|
            \p -> Timestamp.toPosix (Timestamp.fromPosix p) |> Expect.equal p
        , fuzz Fuzzers.posix "fromPosix keeps the millisecond as nanoseconds" <|
            \p ->
                Timestamp.fromPosix p
                    |> Timestamp.toSecondsAndNanos
                    |> (\parts -> parts.seconds * 1000 + parts.nanos // 1000000)
                    |> Expect.equal (Time.posixToMillis p)
        , fuzz Fuzzers.timestamp "toPosix truncates toward the past, before 1970 too" <|
            \t ->
                let
                    parts =
                        Timestamp.toSecondsAndNanos t

                    millis =
                        Time.posixToMillis (Timestamp.toPosix t)
                in
                Expect.all
                    [ \_ -> millis |> Expect.equal (parts.seconds * 1000 + parts.nanos // 1000000)
                    , \_ -> Basics.compare (fields (Timestamp.fromPosix (Time.millisToPosix millis))) (fields t) |> Expect.notEqual GT
                    , \_ ->
                        case Timestamp.fromSecondsAndNanos parts.seconds ((parts.nanos // 1000000 + 1) * 1000000) of
                            Just nextMillisecond ->
                                Basics.compare (fields nextMillisecond) (fields t) |> Expect.equal GT

                            Nothing ->
                                Expect.pass
                    ]
                    ()
        , test "a nanosecond before 1970 is the millisecond before it" <|
            \_ -> Time.posixToMillis (Timestamp.toPosix (instant -1 999999999)) |> Expect.equal -1
        , test "fromPosix before year 1 clamps to its first second" <|
            \_ ->
                Timestamp.fromPosix (Time.millisToPosix -62135596800001)
                    |> Timestamp.toSecondsAndNanos
                    |> Expect.equal { seconds = -62135596800, nanos = 0 }
        , test "fromPosix after year 9999 clamps to its last second, with no nanoseconds" <|
            \_ ->
                Timestamp.fromPosix (Time.millisToPosix 253402300800000)
                    |> Timestamp.toSecondsAndNanos
                    |> Expect.equal { seconds = 253402300799, nanos = 0 }
        , test "fromPosix keeps the last millisecond of year 9999" <|
            \_ ->
                Timestamp.fromPosix (Time.millisToPosix 253402300799999)
                    |> Timestamp.toString
                    |> Expect.equal (Just "9999-12-31T23:59:59.999Z")
        , fuzz Fuzz.int "fromPosix of any Int is valid" <|
            \millis -> Timestamp.isValid (Timestamp.fromPosix (Time.millisToPosix (millis * 1000000))) |> Expect.equal True
        ]



-- THE EXACT BUILDER


exact : Test
exact =
    describe "fromSecondsAndNanos"
        [ test "carries the nanoseconds, leaving 0 to 999,999,999" <|
            \_ ->
                [ Timestamp.fromSecondsAndNanos 1 500000000
                , Timestamp.fromSecondsAndNanos 0 -500000000
                , Timestamp.fromSecondsAndNanos 1 1500000000
                , Timestamp.fromSecondsAndNanos -1 -2000000000
                , Timestamp.fromSecondsAndNanos 0 -1
                ]
                    |> List.map (Maybe.map Timestamp.toSecondsAndNanos)
                    |> Expect.equal
                        [ Just { seconds = 1, nanos = 500000000 }
                        , Just { seconds = -1, nanos = 500000000 }
                        , Just { seconds = 2, nanos = 500000000 }
                        , Just { seconds = -3, nanos = 0 }
                        , Just { seconds = -1, nanos = 999999999 }
                        ]
        , test "outside years 1 to 9999 is Nothing, after carrying" <|
            \_ ->
                [ Timestamp.fromSecondsAndNanos 253402300800 0
                , Timestamp.fromSecondsAndNanos 253402300799 1000000000
                , Timestamp.fromSecondsAndNanos -62135596801 999999999
                , Timestamp.fromSecondsAndNanos -62135596800 -1
                ]
                    |> Expect.equal [ Nothing, Nothing, Nothing, Nothing ]
        , test "the ends of the range are kept, to the nanosecond" <|
            \_ ->
                [ Timestamp.fromSecondsAndNanos 253402300799 999999999, Timestamp.fromSecondsAndNanos -62135596800 0 ]
                    |> Expect.equal (List.map Timestamp.fromString [ "9999-12-31T23:59:59.999999999Z", "0001-01-01T00:00:00Z" ])
        , test "a value carried back into range is kept" <|
            \_ ->
                Timestamp.fromSecondsAndNanos 253402300800 -1
                    |> Maybe.andThen Timestamp.toString
                    |> Expect.equal (Just "9999-12-31T23:59:59.999999999Z")
        , fuzz2 (Fuzz.intRange -62135596800 253402300798) (Fuzz.intRange -999999999 999999999) "what it builds is valid and normal" <|
            \seconds nanos ->
                case Timestamp.fromSecondsAndNanos (seconds + 1) nanos of
                    Just t ->
                        Expect.all
                            [ Timestamp.isValid >> Expect.equal True
                            , \x -> Expect.equal x (Timestamp.normalize x)
                            ]
                            t

                    Nothing ->
                        Expect.fail "within the range, it gives a timestamp"
        ]



-- READ FROM BINARY


{-| The binary of a Timestamp with these fields, written as a peer may.
-}
written : Int -> Int -> Bytes
written seconds nanos =
    B.encode (\() -> Bytes.Encode.sequence [ B.implicit B.int64AsInt 1 seconds, B.implicit B.int32 2 nanos ]) ()


{-| The binary of a Timestamp whose seconds are this decimal text, which an
`Int` may not hold, written as a peer may.
-}
wideBytes : String -> Int -> Bytes
wideBytes seconds nanos =
    B.encode (\() -> Bytes.Encode.sequence [ B.implicit B.int64 1 seconds, B.implicit B.int32 2 nanos ]) ()


read : Int -> Int -> Result Proto.Error.Binary Timestamp
read seconds nanos =
    B.decode (B.messageDecoder B.timestamp) (written seconds nanos)


octets : Bytes -> List Int
octets bytes =
    Bytes.Decode.decode
        (Bytes.Decode.loop ( Bytes.width bytes, [] )
            (\( left, acc ) ->
                if left == 0 then
                    Bytes.Decode.succeed (Bytes.Decode.Done (List.reverse acc))

                else
                    Bytes.Decode.map (\b -> Bytes.Decode.Loop ( left - 1, b :: acc )) Bytes.Decode.unsignedInt8
            )
        )
        bytes
        |> Maybe.withDefault []


jsonRefusal : Timestamp -> Result String String
jsonRefusal t =
    Proto.Json.encode (Proto.Json.writeTimestamp t)
        |> Result.map (\_ -> "written")
        |> Result.mapError Proto.Error.toString


refusedFor : String -> String
refusedFor reason =
    "A google.protobuf.Timestamp holds a value proto3 JSON has no form for: " ++ reason ++ "."


{-| A timestamp a peer wrote that is not valid: its fields, its normal form,
whether that is valid, and the JSON write's reason.
-}
type alias Invalid =
    { name : String
    , seconds : Int
    , nanos : Int
    , normal : { seconds : Int, nanos : Int }
    , normalValid : Bool
    , reason : String
    }


invalids : List Invalid
invalids =
    [ { name = "negative nanoseconds"
      , seconds = 1
      , nanos = -500000000
      , normal = { seconds = 0, nanos = 500000000 }
      , normalValid = True
      , reason = "the nanoseconds are outside 0 to 999,999,999"
      }
    , { name = "negative nanoseconds before 1970"
      , seconds = -1
      , nanos = -1
      , normal = { seconds = -2, nanos = 999999999 }
      , normalValid = True
      , reason = "the nanoseconds are outside 0 to 999,999,999"
      }
    , { name = "nanoseconds past a second"
      , seconds = 1
      , nanos = 1500000000
      , normal = { seconds = 2, nanos = 500000000 }
      , normalValid = True
      , reason = "the nanoseconds are outside 0 to 999,999,999"
      }
    , { name = "seconds past year 9999"
      , seconds = 253402300800
      , nanos = 0
      , normal = { seconds = 253402300800, nanos = 0 }
      , normalValid = False
      , reason = "the time is outside years 1 to 9999"
      }
    , { name = "seconds before year 1"
      , seconds = -62135596801
      , nanos = 999999999
      , normal = { seconds = -62135596801, nanos = 999999999 }
      , normalValid = False
      , reason = "the time is outside years 1 to 9999"
      }
    , { name = "seconds past year 9999, nanoseconds carrying back into it"
      , seconds = 253402300800
      , nanos = -1
      , normal = { seconds = 253402300799, nanos = 999999999 }
      , normalValid = True
      , reason = "the time is outside years 1 to 9999"
      }
    , { name = "nanoseconds that carry past year 9999"
      , seconds = 253402300799
      , nanos = 1000000000
      , normal = { seconds = 253402300800, nanos = 0 }
      , normalValid = False
      , reason = "the nanoseconds are outside 0 to 999,999,999"
      }
    ]


fromBinary : Test
fromBinary =
    describe "a timestamp read from binary that is not valid"
        (List.map
            (\case_ ->
                test case_.name <|
                    \_ ->
                        case read case_.seconds case_.nanos of
                            Err _ ->
                                Expect.fail "the read failed"

                            Ok t ->
                                let
                                    normal =
                                        Timestamp.normalize t
                                in
                                Expect.all
                                    [ \_ ->
                                        Timestamp.toSecondsAndNanos t
                                            |> Expect.equal { seconds = case_.seconds, nanos = case_.nanos }
                                    , \_ ->
                                        octets (B.encode (B.messageEncoder B.timestamp) t)
                                            |> Expect.equal (octets (written case_.seconds case_.nanos))
                                    , \_ -> Timestamp.isValid t |> Expect.equal False
                                    , \_ -> Timestamp.toString t |> Expect.equal Nothing
                                    , \_ -> jsonRefusal t |> Expect.equal (Err (refusedFor case_.reason))
                                    , \_ -> Timestamp.toSecondsAndNanos normal |> Expect.equal case_.normal
                                    , \_ -> Timestamp.isValid normal |> Expect.equal case_.normalValid
                                    , \_ -> (t == normal) |> Expect.equal ({ seconds = case_.seconds, nanos = case_.nanos } == case_.normal)
                                    ]
                                    ()
            )
            invalids
            ++ [ test "a valid one is held as read and is valid" <|
                    \_ ->
                        read -1 250000000
                            |> Result.map (\t -> ( Timestamp.isValid t, Timestamp.toString t, t == instant -1 250000000 ))
                            |> Expect.equal (Ok ( True, Just "1969-12-31T23:59:59.250Z", True ))
               , test "normalize makes two writings of one instant ==" <|
                    \_ ->
                        Result.map2 (\a b -> ( a == b, Timestamp.normalize a == Timestamp.normalize b ))
                            (read 1 -500000000)
                            (read 0 500000000)
                            |> Expect.equal (Ok ( False, True ))
               , test "the most seconds an Int holds exactly, 2^53 - 1 either way, are held, not valid, refused in JSON and kept through binary" <|
                    \_ ->
                        [ 2 ^ 53 - 1, -(2 ^ 53 - 1) ]
                            |> List.map
                                (\seconds ->
                                    case read seconds 0 of
                                        Err _ ->
                                            Err "the read failed"

                                        Ok t ->
                                            let
                                                again =
                                                    B.encode (B.messageEncoder B.timestamp) t
                                            in
                                            Ok
                                                { held = Timestamp.toSecondsAndNanos t == { seconds = seconds, nanos = 0 }
                                                , valid = Timestamp.isValid t
                                                , text = Timestamp.toString t
                                                , json = jsonRefusal t
                                                , sameBytes = octets again == octets (written seconds 0)
                                                , readAgain =
                                                    B.decode (B.messageDecoder B.timestamp) again
                                                        |> Result.map (\u -> ( u == t, Timestamp.isValid u ))
                                                        |> Result.toMaybe
                                                }
                                )
                            |> Expect.equal
                                (List.repeat 2
                                    (Ok
                                        { held = True
                                        , valid = False
                                        , text = Nothing
                                        , json = Err (refusedFor "the time is outside years 1 to 9999")
                                        , sameBytes = True
                                        , readAgain = Just ( True, False )
                                        }
                                    )
                                )
               , test "seconds of 2^53 - 1 either way are not wide: the seconds field holds them whole, and they go back to binary as the same bytes" <|
                    \_ ->
                        [ 2 ^ 53 - 1, -(2 ^ 53 - 1) ]
                            |> List.map
                                (\seconds ->
                                    read seconds 7
                                        |> Result.map
                                            (\held ->
                                                { ordinary = held == Proto.Internal.Timestamp.Timestamp { seconds = seconds, nanos = 7, wideHigh = 0 }
                                                , fields = Timestamp.toSecondsAndNanos held
                                                , sameBytes = octets (B.encode (B.messageEncoder B.timestamp) held) == octets (written seconds 7)
                                                , readAgain =
                                                    B.decode (B.messageDecoder B.timestamp) (B.encode (B.messageEncoder B.timestamp) held)
                                                        |> Result.map ((==) held)
                                                        |> Result.toMaybe
                                                }
                                            )
                                        |> Result.toMaybe
                                )
                            |> Expect.equal
                                [ Just { ordinary = True, fields = { seconds = 2 ^ 53 - 1, nanos = 7 }, sameBytes = True, readAgain = Just True }
                                , Just { ordinary = True, fields = { seconds = -(2 ^ 53 - 1), nanos = 7 }, sameBytes = True, readAgain = Just True }
                                ]
               , test "seconds of 2^53 either way, one past that, are wide: held as the two halves the wire carries" <|
                    \_ ->
                        [ wideBytes "9007199254740992" 7, wideBytes "-9007199254740992" 7 ]
                            |> List.map (B.decode (B.messageDecoder B.timestamp) >> Result.toMaybe)
                            |> Expect.equal
                                [ Just (Proto.Internal.Timestamp.Timestamp { seconds = 0, nanos = 7, wideHigh = 0x00200000 })
                                , Just (Proto.Internal.Timestamp.Timestamp { seconds = 0, nanos = 7, wideHigh = 0xFFE00000 })
                                ]
               , test "seconds past what an Int holds exactly are held exactly: not valid, refused in JSON, and the same bytes back" <|
                    \_ ->
                        [ wideBytes "4611686018427387904" 0, wideBytes "-4611686018427387904" 0, wideBytes "9007199254740992" 0, wideBytes "9223372036854775807" 7, wideBytes "-9223372036854775807" 7 ]
                            |> List.map
                                (\bytes ->
                                    case B.decode (B.messageDecoder B.timestamp) bytes of
                                        Err _ ->
                                            Err "the read failed"

                                        Ok t ->
                                            let
                                                again =
                                                    B.encode (B.messageEncoder B.timestamp) t
                                            in
                                            Ok
                                                { valid = Timestamp.isValid t
                                                , text = Timestamp.toString t
                                                , json = jsonRefusal t
                                                , sameBytes = octets again == octets bytes
                                                , readAgain =
                                                    B.decode (B.messageDecoder B.timestamp) again
                                                        |> Result.map (\u -> u == t)
                                                        |> Result.toMaybe
                                                , normal = Timestamp.normalize t == t
                                                }
                                )
                            |> Expect.equal
                                (List.repeat 5
                                    (Ok
                                        { valid = False
                                        , text = Nothing
                                        , json = Err (refusedFor "the time is outside years 1 to 9999")
                                        , sameBytes = True
                                        , readAgain = Just True
                                        , normal = True
                                        }
                                    )
                                )
               , test "toSecondsAndNanos gives the nearest Int for seconds an Int does not hold, and toPosix clamps by sign" <|
                    \_ ->
                        [ wideBytes "4611686018427387904" 5, wideBytes "-4611686018427387904" 5, wideBytes "9223372036854775807" 0 ]
                            |> List.map
                                (\bytes ->
                                    B.decode (B.messageDecoder B.timestamp) bytes
                                        |> Result.map (\t -> ( Timestamp.toSecondsAndNanos t, Time.posixToMillis (Timestamp.toPosix t) ))
                                        |> Result.toMaybe
                                )
                            |> Expect.equal
                                [ Just ( { seconds = 2 ^ 62, nanos = 5 }, 253402300799000 )
                                , Just ( { seconds = -(2 ^ 62), nanos = 5 }, -62135596800000 )
                                , Just ( { seconds = 2 ^ 63, nanos = 0 }, 253402300799000 )
                                ]
               , test "normalize gives back a timestamp whose seconds the carry would take past what an Int holds" <|
                    \_ ->
                        [ read (2 ^ 53 - 1) 1500000000, read -(2 ^ 53 - 1) -1500000000, read (2 ^ 53 - 2) 1500000000 ]
                            |> List.map (Result.map (\t -> ( Timestamp.normalize t == t, Timestamp.toSecondsAndNanos (Timestamp.normalize t) )) >> Result.toMaybe)
                            |> Expect.equal
                                [ Just ( True, { seconds = 2 ^ 53 - 1, nanos = 1500000000 } )
                                , Just ( True, { seconds = -(2 ^ 53 - 1), nanos = -1500000000 } )
                                , Just ( False, { seconds = 2 ^ 53 - 1, nanos = 500000000 } )
                                ]
               , test "two wide timestamps one second apart are not ==, though their nearest Ints are" <|
                    \_ ->
                        Result.map2 (\a b -> ( a == b, Timestamp.toSecondsAndNanos a == Timestamp.toSecondsAndNanos b ))
                            (B.decode (B.messageDecoder B.timestamp) (wideBytes "4611686018427387904" 0))
                            (B.decode (B.messageDecoder B.timestamp) (wideBytes "4611686018427387905" 0))
                            |> Result.toMaybe
                            |> Expect.equal (Just ( False, True ))
               , test "toPosix normalises, then clamps" <|
                    \_ ->
                        [ read 1 -500000000, read 253402300800 0, read -62135596801 999999999, read 253402300799 1000000000, read 0 -1 ]
                            |> List.map (Result.map (Timestamp.toPosix >> Time.posixToMillis))
                            |> Expect.equal
                                [ Ok 500
                                , Ok 253402300799000
                                , Ok -62135596800000
                                , Ok 253402300799000
                                , Ok -1
                                ]
               ]
        )
