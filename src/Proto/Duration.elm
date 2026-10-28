module Proto.Duration exposing
    ( Duration
    , fromSeconds, toSeconds
    , fromMilliseconds, toMilliseconds
    , fromString, toString
    , fromParts, toParts
    )

{-| `google.protobuf.Duration`: a signed span of time, exact to the
nanosecond, between about -10,000 and 10,000 years.

@docs Duration


# Seconds

@docs fromSeconds, toSeconds


# Milliseconds

@docs fromMilliseconds, toMilliseconds


# proto3 JSON

@docs fromString, toString


# Seconds and nanoseconds

@docs fromParts, toParts

-}


{-| A duration, held as protobuf holds it: whole seconds and nanoseconds, both
with the duration's sign. Two durations are `==` when they are the same span.
-}
type Duration
    = Duration { seconds : Int, nanos : Int }


{-| The duration of so many seconds, rounded to the nanosecond. Past 2^53
nanoseconds (about 104 days) a `Float` holds fewer than nine decimal places, so
the nanoseconds of a longer duration are only as exact as the `Float`. A value
past ±315,576,000,000 seconds, protobuf's limit, gives that limit, and NaN or
an infinity gives zero.

    fromSeconds 1.5 |> toString == "1.500s"

-}
fromSeconds : Float -> Duration
fromSeconds value =
    if isNaN value || isInfinite value then
        Duration { seconds = 0, nanos = 0 }

    else if value >= toFloat maxSeconds then
        Duration { seconds = maxSeconds, nanos = 0 }

    else if value <= toFloat -maxSeconds then
        Duration { seconds = -maxSeconds, nanos = 0 }

    else
        let
            whole =
                towardZero value
        in
        normalize whole (Basics.round ((value - toFloat whole) * 1.0e9))


{-| The duration in seconds. Past 2^53 nanoseconds, as for
[`fromSeconds`](#fromSeconds), the result is the nearest `Float`.
-}
toSeconds : Duration -> Float
toSeconds (Duration parts) =
    toFloat parts.seconds + toFloat parts.nanos / 1.0e9


{-| The duration of so many milliseconds, exactly. A value past
±315,576,000,000 seconds, protobuf's limit, gives that limit.
-}
fromMilliseconds : Int -> Duration
fromMilliseconds value =
    if value >= maxSeconds * 1000 then
        Duration { seconds = maxSeconds, nanos = 0 }

    else if value <= -maxSeconds * 1000 then
        Duration { seconds = -maxSeconds, nanos = 0 }

    else
        normalize (towardZero (toFloat value / 1000)) (remainderBy 1000 value * 1000000)


{-| The duration in whole milliseconds, rounded toward zero, as
`Process.sleep` and `Time.posixToMillis` count them.
-}
toMilliseconds : Duration -> Int
toMilliseconds (Duration parts) =
    parts.seconds * 1000 + towardZero (toFloat parts.nanos / 1.0e6)


{-| Read a duration as proto3 JSON writes one: seconds with an optional
fraction of up to nine digits, followed by `s`, such as `"1.5s"`, `"-0.25s"`
or `"3s"`. Durations beyond ±315,576,000,000 seconds, protobuf's limit, are
`Nothing`.

    fromString "-1.5s" == Just (fromSeconds -1.5)

-}
fromString : String -> Maybe Duration
fromString text =
    let
        ( negative, unsigned ) =
            if String.startsWith "-" text then
                ( True, String.dropLeft 1 text )

            else
                ( False, text )

        sign value =
            if negative then
                negate value

            else
                value
    in
    if String.endsWith "s" unsigned then
        case String.split "." (String.dropRight 1 unsigned) of
            [ whole ] ->
                Maybe.map (\s -> make (sign s) 0) (digits whole)
                    |> Maybe.andThen identity

            [ whole, fraction ] ->
                if String.length fraction >= 1 && String.length fraction <= 9 then
                    Maybe.map2 (\s n -> make (sign s) (sign n))
                        (digits whole)
                        (digits (String.padRight 9 '0' fraction))
                        |> Maybe.andThen identity

                else
                    Nothing

            _ ->
                Nothing

    else
        Nothing


{-| Write a duration as proto3 JSON does: seconds followed by `s`, with
nothing, three, six or nine fractional digits, whichever is the fewest that
keep every nanosecond.

    toString (fromMilliseconds 1500) == "1.500s"

    toString (fromSeconds -0.000001) == "-0.000001s"

    toString (fromSeconds 0) == "0s"

-}
toString : Duration -> String
toString (Duration parts) =
    let
        sign =
            if parts.seconds < 0 || parts.nanos < 0 then
                "-"

            else
                ""

        nanos =
            abs parts.nanos

        fraction =
            if nanos == 0 then
                ""

            else if remainderBy 1000000 nanos == 0 then
                "." ++ String.padLeft 3 '0' (String.fromInt (nanos // 1000000))

            else if remainderBy 1000 nanos == 0 then
                "." ++ String.padLeft 6 '0' (String.fromInt (nanos // 1000))

            else
                "." ++ String.padLeft 9 '0' (String.fromInt nanos)
    in
    sign ++ String.fromInt (abs parts.seconds) ++ fraction ++ "s"


{-| The duration of so many whole seconds and nanoseconds, as protobuf's
binary form carries them: the nanoseconds carried into the seconds and both
given the duration's sign. A duration past ±315,576,000,000 seconds,
protobuf's limit, gives that limit.

    fromParts 1 500000000 == fromSeconds 1.5

    fromParts 2 -500000000 == fromSeconds 1.5

-}
fromParts : Int -> Int -> Duration
fromParts wholeSeconds nanos =
    let
        (Duration parts) =
            normalize wholeSeconds nanos
    in
    if parts.seconds >= maxSeconds then
        Duration { seconds = maxSeconds, nanos = 0 }

    else if parts.seconds <= -maxSeconds then
        Duration { seconds = -maxSeconds, nanos = 0 }

    else
        Duration parts


{-| The duration's whole seconds and nanoseconds, both with its sign, as
protobuf's binary form carries them.

    toParts (fromSeconds -1.5) == { seconds = -1, nanos = -500000000 }

-}
toParts : Duration -> { seconds : Int, nanos : Int }
toParts (Duration parts) =
    parts



-- INTERNAL


{-| The most seconds a duration holds either way, protobuf's limit of about
10,000 years.
-}
maxSeconds : Int
maxSeconds =
    315576000000


{-| Seconds and nanoseconds of the same sign, if within protobuf's range.
-}
make : Int -> Int -> Maybe Duration
make wholeSeconds nanos =
    if abs wholeSeconds <= maxSeconds then
        Just (Duration { seconds = wholeSeconds, nanos = nanos })

    else
        Nothing


{-| Seconds and nanoseconds brought to the same sign, with `abs nanos` below
one second.
-}
normalize : Int -> Int -> Duration
normalize wholeSeconds nanos =
    let
        carried =
            wholeSeconds + towardZero (toFloat nanos / 1.0e9)

        rest =
            remainderBy 1000000000 nanos
    in
    if carried > 0 && rest < 0 then
        Duration { seconds = carried - 1, nanos = rest + 1000000000 }

    else if carried < 0 && rest > 0 then
        Duration { seconds = carried + 1, nanos = rest - 1000000000 }

    else
        Duration { seconds = carried, nanos = rest }


{-| Elm's `truncate` works in 32 bits; this rounds toward zero at any size.
-}
towardZero : Float -> Int
towardZero value =
    if value < 0 then
        ceiling value

    else
        floor value


{-| A string of ASCII digits as a number; anything else is `Nothing`.
-}
digits : String -> Maybe Int
digits text =
    if not (String.isEmpty text) && String.all Char.isDigit text then
        String.toInt text

    else
        Nothing
