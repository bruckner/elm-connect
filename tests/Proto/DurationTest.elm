module Proto.DurationTest exposing (suite)

import Bytes exposing (Bytes)
import Bytes.Decode
import Bytes.Encode
import Expect
import Fuzz
import Proto.Binary as B
import Proto.Duration as Duration exposing (Duration)
import Proto.Error
import Proto.Json
import Test exposing (Test, describe, fuzz, fuzz2, test)


suite : Test
suite =
    describe "Proto.Duration"
        [ parsing
        , printing
        , conversions
        , range
        , roundTrips
        , exact
        , fromBinary
        ]


parsesAs : String -> String -> Expect.Expectation
parsesAs text printed =
    Duration.fromString text
        |> Maybe.andThen Duration.toString
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
            \_ -> Expect.equal (Just "0s") (Duration.toString (Duration.fromSeconds 0))
        , test "three digits for milliseconds" <|
            \_ -> Expect.equal (Just "0.001s") (Duration.toString (Duration.fromMillis 1))
        , test "six digits for microseconds" <|
            \_ -> Expect.equal (Just "-0.000001s") (Duration.toString (Duration.fromSeconds -0.000001))
        , test "nine digits for nanoseconds" <|
            \_ -> Expect.equal (Just "0.000000001s") (Duration.toString (Duration.fromSeconds 1.0e-9))
        ]


conversions : Test
conversions =
    describe "conversions"
        [ test "fromSeconds then toSeconds" <|
            \_ -> Expect.within (Expect.Absolute 1.0e-9) -2.75 (Duration.toSeconds (Duration.fromSeconds -2.75))
        , test "fromMillis then toMillis" <|
            \_ -> Expect.equal -1500 (Duration.toMillis (Duration.fromMillis -1500))
        , test "toMillis rounds toward zero" <|
            \_ -> Expect.equal -1 (Duration.toMillis (Duration.fromSeconds -0.0019))
        , test "equal spans are ==" <|
            \_ -> Expect.equal (Duration.fromMillis 1500) (Duration.fromSeconds 1.5)
        , test "years of seconds" <|
            \_ -> Expect.equal (Just "315576000000s") (Duration.toString (Duration.fromSeconds 315576000000))
        , test "milliseconds past 32 bits" <|
            \_ -> Expect.equal 5000000000000 (Duration.toMillis (Duration.fromMillis 5000000000000))
        ]


printsAs : String -> Duration.Duration -> Expect.Expectation
printsAs text duration =
    Expect.equal (Just text) (Duration.toString duration)


range : Test
range =
    describe "fromSeconds and fromMillis clamp to the range"
        [ test "the largest second count" <|
            \_ -> printsAs "315576000000s" (Duration.fromSeconds 315576000000)
        , test "the smallest second count" <|
            \_ -> printsAs "-315576000000s" (Duration.fromSeconds -315576000000)
        , test "one second past the largest gives the largest" <|
            \_ -> printsAs "315576000000s" (Duration.fromSeconds 315576000001)
        , test "one second past the smallest gives the smallest" <|
            \_ -> printsAs "-315576000000s" (Duration.fromSeconds -315576000001)
        , test "a fraction past the largest second count is valid, and kept" <|
            \_ -> printsAs "315576000000.500s" (Duration.fromSeconds 315576000000.5)
        , test "a fraction past the smallest second count is valid, and kept" <|
            \_ -> printsAs "-315576000000.500s" (Duration.fromSeconds -315576000000.5)
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
            \_ -> printsAs "315576000000s" (Duration.fromMillis 315576000000000)
        , test "the smallest millisecond count" <|
            \_ -> printsAs "-315576000000s" (Duration.fromMillis -315576000000000)
        , test "milliseconds past the largest second count are valid, and kept" <|
            \_ -> printsAs "315576000000.999s" (Duration.fromMillis 315576000000999)
        , test "milliseconds past the smallest second count are valid, and kept" <|
            \_ -> printsAs "-315576000000.500s" (Duration.fromMillis -315576000000500)
        , test "one second past the largest in milliseconds gives the largest" <|
            \_ -> printsAs "315576000000s" (Duration.fromMillis 315576000001000)
        , test "one second past the smallest in milliseconds gives the smallest" <|
            \_ -> printsAs "-315576000000s" (Duration.fromMillis -315576000001000)
        , test "the builders keep what fromSecondsAndNanos keeps at the limit" <|
            \_ ->
                ( Just (Duration.fromMillis 315576000000500), Just (Duration.fromSeconds -315576000000.5) )
                    |> Expect.equal
                        ( Duration.fromSecondsAndNanos 315576000000 500000000
                        , Duration.fromSecondsAndNanos -315576000000 -500000000
                        )
        , test "one millisecond inside the largest is kept" <|
            \_ -> printsAs "315575999999.999s" (Duration.fromMillis 315575999999999)
        , fuzz Fuzz.float "fromSeconds of any Float is valid" <|
            \value -> Duration.isValid (Duration.fromSeconds value) |> Expect.equal True
        , fuzz Fuzz.int "fromMillis of any Int is valid" <|
            \millis -> Duration.isValid (Duration.fromMillis (millis * 1000000)) |> Expect.equal True
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
                    |> Maybe.andThen (Duration.toString >> Maybe.andThen Duration.fromString)
                    |> Expect.equal (Duration.fromString text)
        , fuzz (Fuzz.floatRange -315576000000 315576000000) "fromSeconds, toString, then fromString" <|
            \value ->
                Duration.fromSeconds value
                    |> Duration.toString
                    |> Maybe.andThen Duration.fromString
                    |> Expect.equal (Just (Duration.fromSeconds value))
        , fuzz Fuzz.float "fromSeconds of any Float prints as a duration fromString reads" <|
            \value ->
                Duration.fromSeconds value
                    |> Duration.toString
                    |> Maybe.andThen Duration.fromString
                    |> Expect.equal (Just (Duration.fromSeconds value))
        , fuzz Fuzz.int "fromMillis of any Int prints as a duration fromString reads" <|
            \millis ->
                Duration.fromMillis (millis * 1000000)
                    |> Duration.toString
                    |> Maybe.andThen Duration.fromString
                    |> Expect.equal (Just (Duration.fromMillis (millis * 1000000)))
        , fuzz (Fuzz.intRange -100000000000 100000000000) "milliseconds" <|
            \millis ->
                Duration.fromMillis millis
                    |> Duration.toMillis
                    |> Expect.equal millis
        ]



-- THE EXACT BUILDER


exact : Test
exact =
    describe "fromSecondsAndNanos"
        [ test "carries the nanoseconds and gives both parts one sign" <|
            \_ ->
                [ Duration.fromSecondsAndNanos 1 500000000
                , Duration.fromSecondsAndNanos 2 -500000000
                , Duration.fromSecondsAndNanos 0 -1500000000
                , Duration.fromSecondsAndNanos -1 2000000000
                , Duration.fromSecondsAndNanos -2 500000000
                ]
                    |> List.map (Maybe.map Duration.toSecondsAndNanos)
                    |> Expect.equal
                        [ Just { seconds = 1, nanos = 500000000 }
                        , Just { seconds = 1, nanos = 500000000 }
                        , Just { seconds = -1, nanos = -500000000 }
                        , Just { seconds = 1, nanos = 0 }
                        , Just { seconds = -1, nanos = -500000000 }
                        ]
        , test "past protobuf's limit is Nothing, after carrying" <|
            \_ ->
                [ Duration.fromSecondsAndNanos 315576000001 0
                , Duration.fromSecondsAndNanos 315576000000 1500000000
                , Duration.fromSecondsAndNanos -400000000000 -1
                , Duration.fromSecondsAndNanos -315576000000 -1000000000
                ]
                    |> Expect.equal [ Nothing, Nothing, Nothing, Nothing ]
        , test "at protobuf's limit keeps the nanoseconds, as fromString does" <|
            \_ ->
                [ Duration.fromSecondsAndNanos 315576000000 5, Duration.fromSecondsAndNanos -315576000000 -578239000 ]
                    |> Expect.equal
                        (List.map Duration.fromString [ "315576000000.000000005s", "-315576000000.578239s" ])
        , test "a value carried back into range is kept" <|
            \_ ->
                Duration.fromSecondsAndNanos 315576000001 -500000000
                    |> Maybe.andThen Duration.toString
                    |> Expect.equal (Just "315576000000.500s")
        , fuzz2 (Fuzz.intRange -315576000000 315576000000) (Fuzz.intRange -999999999 999999999) "what it builds is valid and normal" <|
            \seconds nanos ->
                case Duration.fromSecondsAndNanos seconds nanos of
                    Just duration ->
                        Expect.all
                            [ Duration.isValid >> Expect.equal True
                            , \d -> Expect.equal d (Duration.normalize d)
                            ]
                            duration

                    Nothing ->
                        Expect.fail "within the range, it gives a duration"
        ]



-- READ FROM BINARY


{-| The binary of a Duration with these fields, written as a peer may.
-}
written : Int -> Int -> Bytes
written seconds nanos =
    B.encode (\() -> Bytes.Encode.sequence [ B.implicit B.int64AsInt 1 seconds, B.implicit B.int32 2 nanos ]) ()


read : Int -> Int -> Result Proto.Error.Binary Duration
read seconds nanos =
    B.decode (B.messageDecoder B.duration) (written seconds nanos)


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


jsonRefusal : Duration -> Result String String
jsonRefusal duration =
    Proto.Json.encode (Proto.Json.writeDuration duration)
        |> Result.map (\_ -> "written")
        |> Result.mapError Proto.Error.toString


refusedFor : String -> String
refusedFor reason =
    "A google.protobuf.Duration holds a value proto3 JSON has no form for: " ++ reason ++ "."


{-| A duration a peer wrote that is not valid: its fields, its normal form,
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
    [ { name = "opposite signs"
      , seconds = 1
      , nanos = -500000000
      , normal = { seconds = 0, nanos = 500000000 }
      , normalValid = True
      , reason = "the seconds and the nanoseconds have opposite signs"
      }
    , { name = "opposite signs, negative seconds"
      , seconds = -1
      , nanos = 500000000
      , normal = { seconds = 0, nanos = -500000000 }
      , normalValid = True
      , reason = "the seconds and the nanoseconds have opposite signs"
      }
    , { name = "nanoseconds past a second"
      , seconds = 1
      , nanos = 1500000000
      , normal = { seconds = 2, nanos = 500000000 }
      , normalValid = True
      , reason = "the nanoseconds are outside -999,999,999 to 999,999,999"
      }
    , { name = "seconds past the limit"
      , seconds = 315576000001
      , nanos = 0
      , normal = { seconds = 315576000001, nanos = 0 }
      , normalValid = False
      , reason = "the duration is outside -315,576,000,000 to 315,576,000,000 seconds"
      }
    , { name = "seconds past the negative limit"
      , seconds = -400000000000
      , nanos = -1
      , normal = { seconds = -400000000000, nanos = -1 }
      , normalValid = False
      , reason = "the duration is outside -315,576,000,000 to 315,576,000,000 seconds"
      }
    , { name = "nanoseconds that carry past the limit"
      , seconds = 315576000000
      , nanos = 1500000000
      , normal = { seconds = 315576000001, nanos = 500000000 }
      , normalValid = False
      , reason = "the nanoseconds are outside -999,999,999 to 999,999,999"
      }
    ]


fromBinary : Test
fromBinary =
    describe "a duration read from binary that is not valid"
        (List.map
            (\case_ ->
                test case_.name <|
                    \_ ->
                        case read case_.seconds case_.nanos of
                            Err _ ->
                                Expect.fail "the read failed"

                            Ok duration ->
                                let
                                    normal =
                                        Duration.normalize duration
                                in
                                Expect.all
                                    [ \_ ->
                                        Duration.toSecondsAndNanos duration
                                            |> Expect.equal { seconds = case_.seconds, nanos = case_.nanos }
                                    , \_ ->
                                        octets (B.encode (B.messageEncoder B.duration) duration)
                                            |> Expect.equal (octets (written case_.seconds case_.nanos))
                                    , \_ -> Duration.isValid duration |> Expect.equal False
                                    , \_ -> Duration.toString duration |> Expect.equal Nothing
                                    , \_ -> jsonRefusal duration |> Expect.equal (Err (refusedFor case_.reason))
                                    , \_ -> Duration.toSecondsAndNanos normal |> Expect.equal case_.normal
                                    , \_ -> Duration.isValid normal |> Expect.equal case_.normalValid
                                    , \_ -> (duration == normal) |> Expect.equal ({ seconds = case_.seconds, nanos = case_.nanos } == case_.normal)
                                    ]
                                    ()
            )
            invalids
            ++ [ test "a valid one is held as read and is valid" <|
                    \_ ->
                        read -1 -500000000
                            |> Result.map (\d -> ( Duration.isValid d, Duration.toString d, d == Duration.fromSeconds -1.5 ))
                            |> Expect.equal (Ok ( True, Just "-1.500s", True ))
               , test "normalize makes two writings of one span ==" <|
                    \_ ->
                        Result.map2 (\a b -> ( a == b, Duration.normalize a == Duration.normalize b ))
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

                                        Ok duration ->
                                            let
                                                again =
                                                    B.encode (B.messageEncoder B.duration) duration
                                            in
                                            Ok
                                                { held = Duration.toSecondsAndNanos duration == { seconds = seconds, nanos = 0 }
                                                , valid = Duration.isValid duration
                                                , text = Duration.toString duration
                                                , json = jsonRefusal duration
                                                , sameBytes = octets again == octets (written seconds 0)
                                                , readAgain =
                                                    B.decode (B.messageDecoder B.duration) again
                                                        |> Result.map (\d -> ( d == duration, Duration.isValid d ))
                                                        |> Result.toMaybe
                                                }
                                )
                            |> Expect.equal
                                (List.repeat 2
                                    (Ok
                                        { held = True
                                        , valid = False
                                        , text = Nothing
                                        , json = Err (refusedFor "the duration is outside -315,576,000,000 to 315,576,000,000 seconds")
                                        , sameBytes = True
                                        , readAgain = Just ( True, False )
                                        }
                                    )
                                )
               , test "seconds past what an Int holds exactly, 2^62 either way, fail the read" <|
                    \_ ->
                        Expect.all
                            [ \_ ->
                                octets (written (2 ^ 62) 0)
                                    |> Expect.equal [ 0x08, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x40 ]
                            , \_ ->
                                [ 2 ^ 62, -(2 ^ 62), 2 ^ 53, -(2 ^ 53) ]
                                    |> List.map (\seconds -> read seconds 0 |> Result.map Duration.toSecondsAndNanos |> Result.mapError .reason)
                                    |> Expect.equal (List.repeat 4 (Err Proto.Error.IntOutOfRange))
                            ]
                            ()
               , test "the lossy views normalise, then clamp" <|
                    \_ ->
                        [ read 1 -500000000, read 315576000001 0, read -400000000000 -1, read 315576000000 1500000000 ]
                            |> List.map (Result.map (\d -> ( Duration.toMillis d, Duration.toSeconds d )))
                            |> Expect.equal
                                [ Ok ( 500, 0.5 )
                                , Ok ( 315576000000000, 315576000000 )
                                , Ok ( -315576000000000, -315576000000 )
                                , Ok ( 315576000000000, 315576000000 )
                                ]
               ]
        )
