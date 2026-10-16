module Proto.TimestampTest exposing (suite)

import Expect
import Fuzz
import Proto.Timestamp
import Test exposing (Test, describe, fuzz, test)
import Time


suite : Test
suite =
    describe "Proto.Timestamp"
        [ parsing
        , printing
        , roundTrips
        ]


parses : String -> Int -> Expect.Expectation
parses text millis =
    Proto.Timestamp.fromString text
        |> Expect.equal (Just (Time.millisToPosix millis))


rejects : String -> Expect.Expectation
rejects text =
    Proto.Timestamp.fromString text
        |> Expect.equal Nothing


prints : Int -> String -> Expect.Expectation
prints millis text =
    Proto.Timestamp.toString (Time.millisToPosix millis)
        |> Expect.equal text


parsing : Test
parsing =
    describe "fromString"
        [ test "a fraction of 100,000 digits is rejected without exhausting the stack" <|
            \_ -> rejects ("1970-01-01T00:00:00." ++ String.repeat 100000 "1" ++ "Z")
        , test "the epoch" <|
            \_ -> parses "1970-01-01T00:00:00Z" 0
        , test "a date and time" <|
            \_ -> parses "2026-10-10T17:19:45Z" 1791652785000
        , test "milliseconds" <|
            \_ -> parses "1970-01-01T00:00:01.500Z" 1500
        , test "one fractional digit" <|
            \_ -> parses "1970-01-01T00:00:01.5Z" 1500
        , test "nanoseconds are truncated to milliseconds" <|
            \_ -> parses "1970-01-01T00:00:00.123456789Z" 123
        , test "a fraction is truncated, never rounded up" <|
            \_ -> parses "1970-01-01T00:00:00.9999999Z" 999
        , test "before the epoch, truncation is toward the past" <|
            \_ -> parses "1969-12-31T23:59:59.9999999Z" -1
        , test "before the epoch, fractions still count forward" <|
            \_ -> parses "1969-12-31T23:59:59.250Z" -750
        , test "a positive offset is applied" <|
            \_ -> parses "1970-01-01T02:00:00+02:00" 0
        , test "a negative offset is applied" <|
            \_ -> parses "1969-12-31T19:30:00-04:30" 0
        , test "an offset can cross a day" <|
            \_ -> parses "1970-01-02T00:30:00+01:00" (23 * 3600000 + 30 * 60000)
        , test "lowercase t and z" <|
            \_ -> parses "1970-01-01t00:00:00z" 0
        , test "a leap second is clamped to the second before it" <|
            \_ -> parses "1972-06-30T23:59:60Z" 78796799000
        , test "a leap second keeps its fraction" <|
            \_ -> parses "1972-06-30T23:59:60.5Z" 78796799500
        , test "29 February of a leap year" <|
            \_ -> parses "2000-02-29T00:00:00Z" 951782400000
        , test "the earliest timestamp" <|
            \_ -> parses "0001-01-01T00:00:00Z" -62135596800000
        , test "the latest timestamp" <|
            \_ -> parses "9999-12-31T23:59:59.999999999Z" 253402300799999
        , test "year 0 is out of range" <|
            \_ -> rejects "0000-12-31T23:59:59Z"
        , test "an offset that moves past year 9999 is out of range" <|
            \_ -> rejects "9999-12-31T23:59:59-01:00"
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
            \_ -> prints 0 "1970-01-01T00:00:00Z"
        , test "milliseconds print three digits" <|
            \_ -> prints 1500 "1970-01-01T00:00:01.500Z"
        , test "one millisecond" <|
            \_ -> prints 1 "1970-01-01T00:00:00.001Z"
        , test "before the epoch" <|
            \_ -> prints -750 "1969-12-31T23:59:59.250Z"
        , test "the earliest timestamp" <|
            \_ -> prints -62135596800000 "0001-01-01T00:00:00Z"
        , test "the latest timestamp" <|
            \_ -> prints 253402300799999 "9999-12-31T23:59:59.999Z"
        , test "a leap day" <|
            \_ -> prints 951782400000 "2000-02-29T00:00:00Z"
        ]


roundTrips : Test
roundTrips =
    describe "round trips"
        [ fuzz (Fuzz.intRange -62135596800000 253402300799999) "toString then fromString" <|
            \millis ->
                Proto.Timestamp.fromString (Proto.Timestamp.toString (Time.millisToPosix millis))
                    |> Expect.equal (Just (Time.millisToPosix millis))
        ]
