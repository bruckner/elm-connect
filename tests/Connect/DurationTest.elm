module Connect.DurationTest exposing (suite)

import Connect.Duration as Duration
import Expect
import Fuzz
import Test exposing (Test, describe, fuzz, fuzz2, test)


suite : Test
suite =
    describe "Connect.Duration"
        [ parsing
        , printing
        , conversions
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
        [ test "fromSeconds then seconds" <|
            \_ -> Expect.within (Expect.Absolute 1.0e-9) -2.75 (Duration.seconds (Duration.fromSeconds -2.75))
        , test "fromMilliseconds then milliseconds" <|
            \_ -> Expect.equal -1500 (Duration.milliseconds (Duration.fromMilliseconds -1500))
        , test "milliseconds round toward zero" <|
            \_ -> Expect.equal -1 (Duration.milliseconds (Duration.fromSeconds -0.0019))
        , test "equal spans are ==" <|
            \_ -> Expect.equal (Duration.fromMilliseconds 1500) (Duration.fromSeconds 1.5)
        , test "years of seconds" <|
            \_ -> Expect.equal "315576000000s" (Duration.toString (Duration.fromSeconds 315576000000))
        , test "milliseconds past 32 bits" <|
            \_ -> Expect.equal 5000000000000 (Duration.milliseconds (Duration.fromMilliseconds 5000000000000))
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
        , fuzz (Fuzz.intRange -100000000000 100000000000) "milliseconds" <|
            \millis ->
                Duration.fromMilliseconds millis
                    |> Duration.milliseconds
                    |> Expect.equal millis
        ]
