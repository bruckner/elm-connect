module Proto.DurationTest exposing (suite)

import Expect
import Fuzz
import Proto.Duration as Duration
import Test exposing (Test, describe, fuzz, fuzz2, test)


suite : Test
suite =
    describe "Proto.Duration"
        [ parsing
        , printing
        , conversions
        , range
        , roundTrips
        ]


parsesAs : String -> String -> Expect.Expectation
parsesAs text printed =
    Duration.fromString text
        |> Maybe.map Duration.toString
        |> Expect.equal (Just printed)


rejects : String -> Expect.Expectation
rejects text =
    Duration.fromString text
        |> Expect.equal Nothing


parsing : Test
parsing =
    describe "fromString"
        [ test "whole seconds" <|
            \_ -> parsesAs "3s" "3s"
        , test "a fraction" <|
            \_ -> parsesAs "1.5s" "1.500s"
        , test "nanoseconds" <|
            \_ -> parsesAs "1.000000001s" "1.000000001s"
        , test "a negative duration" <|
            \_ -> parsesAs "-1.5s" "-1.500s"
        , test "a negative duration under a second" <|
            \_ -> parsesAs "-0.25s" "-0.250s"
        , test "-0s is zero" <|
            \_ ->
                Duration.fromString "-0s"
                    |> Expect.equal (Just (Duration.fromSeconds 0))
        , test "-0s prints as 0s" <|
            \_ -> parsesAs "-0s" "0s"
        , test "-0.0s prints as 0s" <|
            \_ -> parsesAs "-0.0s" "0s"
        , test "the largest duration" <|
            \_ -> parsesAs "315576000000.999999999s" "315576000000.999999999s"
        , test "the smallest duration" <|
            \_ -> parsesAs "-315576000000.999999999s" "-315576000000.999999999s"
        , test "past the largest duration" <|
            \_ -> rejects "315576000001s"
        , test "no unit" <|
            \_ -> rejects "1.5"
        , test "an uppercase S" <|
            \_ -> rejects "1.5S"
        , test "another unit" <|
            \_ -> rejects "1.5m"
        , test "ten fractional digits" <|
            \_ -> rejects "1.0000000001s"
        , test "an empty fraction" <|
            \_ -> rejects "1.s"
        , test "no whole part" <|
            \_ -> rejects ".5s"
        , test "a plus sign" <|
            \_ -> rejects "+1s"
        , test "exponent notation" <|
            \_ -> rejects "1e3s"
        , test "an empty string" <|
            \_ -> rejects ""
        ]


printing : Test
printing =
    describe "toString"
        [ test "zero" <|
            \_ -> Expect.equal "0s" (Duration.toString (Duration.fromSeconds 0))
        , test "three digits for milliseconds" <|
            \_ -> Expect.equal "0.001s" (Duration.toString (Duration.fromMilliseconds 1))
        , test "six digits for microseconds" <|
            \_ -> Expect.equal "-0.000001s" (Duration.toString (Duration.fromSeconds -0.000001))
        , test "nine digits for nanoseconds" <|
            \_ -> Expect.equal "0.000000001s" (Duration.toString (Duration.fromSeconds 1.0e-9))
        ]


conversions : Test
conversions =
    describe "conversions"
        [ test "fromSeconds then toSeconds" <|
            \_ -> Expect.within (Expect.Absolute 1.0e-9) -2.75 (Duration.toSeconds (Duration.fromSeconds -2.75))
        , test "fromMilliseconds then toMilliseconds" <|
            \_ -> Expect.equal -1500 (Duration.toMilliseconds (Duration.fromMilliseconds -1500))
        , test "toMilliseconds rounds toward zero" <|
            \_ -> Expect.equal -1 (Duration.toMilliseconds (Duration.fromSeconds -0.0019))
        , test "equal spans are ==" <|
            \_ -> Expect.equal (Duration.fromMilliseconds 1500) (Duration.fromSeconds 1.5)
        , test "years of seconds" <|
            \_ -> Expect.equal "315576000000s" (Duration.toString (Duration.fromSeconds 315576000000))
        , test "milliseconds past 32 bits" <|
            \_ -> Expect.equal 5000000000000 (Duration.toMilliseconds (Duration.fromMilliseconds 5000000000000))
        ]


printsAs : String -> Duration.Duration -> Expect.Expectation
printsAs text duration =
    Expect.equal text (Duration.toString duration)


range : Test
range =
    describe "fromSeconds and fromMilliseconds stay in range"
        [ test "the largest second count" <|
            \_ -> printsAs "315576000000s" (Duration.fromSeconds 315576000000)
        , test "the smallest second count" <|
            \_ -> printsAs "-315576000000s" (Duration.fromSeconds -315576000000)
        , test "one second past the largest gives the largest" <|
            \_ -> printsAs "315576000000s" (Duration.fromSeconds 315576000001)
        , test "one second past the smallest gives the smallest" <|
            \_ -> printsAs "-315576000000s" (Duration.fromSeconds -315576000001)
        , test "a fraction past the largest gives the largest" <|
            \_ -> printsAs "315576000000s" (Duration.fromSeconds 315576000000.5)
        , test "far past the largest gives the largest" <|
            \_ -> printsAs "315576000000s" (Duration.fromSeconds 1.0e12)
        , test "just inside the largest is kept" <|
            \_ -> printsAs "315575999999.500s" (Duration.fromSeconds 315575999999.5)
        , test "infinity gives zero" <|
            \_ -> printsAs "0s" (Duration.fromSeconds (1 / 0))
        , test "negative infinity gives zero" <|
            \_ -> printsAs "0s" (Duration.fromSeconds -(1 / 0))
        , test "NaN gives zero" <|
            \_ -> printsAs "0s" (Duration.fromSeconds (0 / 0))
        , test "-0 is zero" <|
            \_ ->
                Expect.all
                    [ printsAs "0s"
                    , Expect.equal (Duration.fromSeconds 0)
                    ]
                    (Duration.fromSeconds 0)
        , test "the largest millisecond count" <|
            \_ -> printsAs "315576000000s" (Duration.fromMilliseconds 315576000000000)
        , test "the smallest millisecond count" <|
            \_ -> printsAs "-315576000000s" (Duration.fromMilliseconds -315576000000000)
        , test "one millisecond past the largest gives the largest" <|
            \_ -> printsAs "315576000000s" (Duration.fromMilliseconds 315576000000001)
        , test "one millisecond past the smallest gives the smallest" <|
            \_ -> printsAs "-315576000000s" (Duration.fromMilliseconds -315576000000001)
        , test "one millisecond inside the largest is kept" <|
            \_ -> printsAs "315575999999.999s" (Duration.fromMilliseconds 315575999999999)
        ]


roundTrips : Test
roundTrips =
    describe "round trips"
        [ fuzz2 (Fuzz.intRange -315576000000 315576000000) (Fuzz.intRange 0 999999999) "toString then fromString" <|
            \seconds nanos ->
                let
                    text =
                        (if seconds < 0 then
                            "-" ++ String.fromInt (abs seconds)

                         else
                            String.fromInt seconds
                        )
                            ++ "."
                            ++ String.padLeft 9 '0' (String.fromInt nanos)
                            ++ "s"
                in
                Duration.fromString text
                    |> Maybe.andThen (Duration.toString >> Duration.fromString)
                    |> Expect.equal (Duration.fromString text)
        , fuzz (Fuzz.floatRange -315576000000 315576000000) "fromSeconds, toString, then fromString" <|
            \value ->
                Duration.fromSeconds value
                    |> Duration.toString
                    |> Duration.fromString
                    |> Expect.equal (Just (Duration.fromSeconds value))
        , fuzz Fuzz.float "fromSeconds of any Float prints as a duration fromString reads" <|
            \value ->
                Duration.fromSeconds value
                    |> Duration.toString
                    |> Duration.fromString
                    |> Expect.equal (Just (Duration.fromSeconds value))
        , fuzz Fuzz.int "fromMilliseconds of any Int prints as a duration fromString reads" <|
            \millis ->
                Duration.fromMilliseconds (millis * 1000000)
                    |> Duration.toString
                    |> Duration.fromString
                    |> Expect.equal (Just (Duration.fromMilliseconds (millis * 1000000)))
        , fuzz (Fuzz.intRange -100000000000 100000000000) "milliseconds" <|
            \millis ->
                Duration.fromMilliseconds millis
                    |> Duration.toMilliseconds
                    |> Expect.equal millis
        ]
