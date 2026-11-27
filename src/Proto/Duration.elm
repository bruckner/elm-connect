module Proto.Duration exposing
    ( Duration
    , fromSeconds, toSeconds
    , fromMillis, toMillis
    , fromString, toString
    , fromSecondsAndNanos, toSecondsAndNanos
    , isValid, normalize
    )

{-| `google.protobuf.Duration`: a signed span of time, exact to the
nanosecond, between -315,576,000,000 and 315,576,000,000 seconds (about
10,000 years either way).

Every duration this module builds, and every one read from proto3 JSON, is
valid and in normal form: whole seconds and nanoseconds of one sign, the
nanoseconds below one second. A duration read from protobuf binary is held
as the peer wrote it, which may not be: its two fields may have opposite
signs, its nanoseconds may be a second or more, or its seconds may be past
the limit. Such a value is written back to binary exactly as it was read.
[`isValid`](#isValid) says whether a duration is valid, and
[`normalize`](#normalize) gives its normal form; a proto3 JSON write of one
that is not valid fails with a `Proto.Error.BadValue`, and
[`toString`](#toString) gives `Nothing` for it.

@docs Duration


# Seconds

@docs fromSeconds, toSeconds


# Milliseconds

@docs fromMillis, toMillis


# proto3 JSON

@docs fromString, toString


# Seconds and nanoseconds

@docs fromSecondsAndNanos, toSecondsAndNanos


# Validity

@docs isValid, normalize

-}

import Proto.Internal.Duration as Internal exposing (maxSeconds, towardZero)


{-| A duration, held as protobuf holds it: whole seconds and nanoseconds.

Two durations this module built, or read from proto3 JSON, are `==` exactly
when they are the same span. Two read from protobuf binary that are the
same span written differently (`1` second and `-500000000` nanoseconds, and
`0` seconds and `500000000` nanoseconds) are not `==`;
[`normalize`](#normalize) makes them `==`.

The package site and compiler errors may show it as
`Proto.Internal.Duration.Duration`, the module that defines it.

-}
type alias Duration =
    Internal.Duration


{-| The duration of so many seconds, rounded to the nanosecond. It clamps: a
value whose whole seconds are past ±315,576,000,000, protobuf's limit, gives
exactly that many seconds, and NaN or an infinity gives zero. Every valid
duration is kept, a fraction of a second past the limit too, which protobuf
allows. Past 2^53 nanoseconds (about 104 days) a `Float` holds fewer than
nine decimal places, so the nanoseconds of a longer duration are only as
exact as the `Float`.

    fromSeconds 1.5 |> toString == Just "1.500s"

    fromSeconds 1.0e12 |> toString == Just "315576000000s"

-}
fromSeconds : Float -> Duration
fromSeconds value =
    if isNaN value || isInfinite value then
        Internal.Duration { seconds = 0, nanos = 0 }

    else
        let
            whole =
                towardZero value
        in
        clamped (Internal.Duration { seconds = whole, nanos = Basics.round ((value - toFloat whole) * 1.0e9) })


{-| The duration in seconds, a lossy view: as exact as a `Float` is, as for
[`fromSeconds`](#fromSeconds). A duration that is not valid is normalised,
then clamped to ±315,576,000,000 seconds.
-}
toSeconds : Duration -> Float
toSeconds duration =
    let
        (Internal.Duration parts) =
            clamped duration
    in
    toFloat parts.seconds + toFloat parts.nanos / 1.0e9


{-| The duration of so many milliseconds, exactly. It clamps: a value whose
whole seconds are past ±315,576,000,000, protobuf's limit, gives exactly that
many seconds. Every valid duration is kept, a fraction of a second past the
limit too.

    fromMillis 1500 == fromSeconds 1.5

-}
fromMillis : Int -> Duration
fromMillis value =
    clamped (Internal.Duration { seconds = towardZero (toFloat value / 1000), nanos = remainderBy 1000 value * 1000000 })


{-| The duration in whole milliseconds, rounded toward zero, as
`Process.sleep` and `Time.posixToMillis` count them: a lossy view. A
duration that is not valid is normalised, then clamped to
±315,576,000,000 seconds.
-}
toMillis : Duration -> Int
toMillis duration =
    let
        (Internal.Duration parts) =
            clamped duration
    in
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
                Maybe.andThen (\s -> inRange (sign s) 0) (digits whole)

            [ whole, fraction ] ->
                if String.length fraction >= 1 && String.length fraction <= 9 then
                    Maybe.map2 (\s n -> inRange (sign s) (sign n))
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
keep every nanosecond. `Nothing` when the duration is not valid, which only
one read from protobuf binary can be; [`normalize`](#normalize) it first to
print one that is in range but not in normal form.

    toString (fromMillis 1500) == Just "1.500s"

    toString (fromSeconds -0.000001) == Just "-0.000001s"

    toString (fromSeconds 0) == Just "0s"

-}
toString : Duration -> Maybe String
toString duration =
    if Internal.isValid duration then
        Just (Internal.print duration)

    else
        Nothing


{-| The duration of so many whole seconds and nanoseconds, normalised: the
nanoseconds carried into the seconds and both given the duration's sign.
`Nothing` when the result is past ±315,576,000,000 seconds, protobuf's
limit; at the limit the nanoseconds are kept, as protobuf keeps them.

    fromSecondsAndNanos 1 500000000 == Just (fromSeconds 1.5)

    fromSecondsAndNanos 2 -500000000 == Just (fromSeconds 1.5)

    fromSecondsAndNanos 315576000001 0 == Nothing

-}
fromSecondsAndNanos : Int -> Int -> Maybe Duration
fromSecondsAndNanos wholeSeconds nanos =
    let
        ((Internal.Duration parts) as normal) =
            Internal.normalize (Internal.Duration { seconds = wholeSeconds, nanos = nanos })
    in
    if abs parts.seconds <= maxSeconds then
        Just normal

    else
        Nothing


{-| The duration's two fields as it holds them, as protobuf's binary form
carries them: for a valid duration, whole seconds and nanoseconds both with
its sign; for one read from binary, whatever the peer wrote.

    toSecondsAndNanos (fromSeconds -1.5) == { seconds = -1, nanos = -500000000 }

-}
toSecondsAndNanos : Duration -> { seconds : Int, nanos : Int }
toSecondsAndNanos (Internal.Duration parts) =
    parts


{-| Whether the duration is valid by protobuf's rule: within
±315,576,000,000 seconds, its nanoseconds below one second either way, and
its seconds and nanoseconds not of opposite signs. Every duration this
module builds, and every one read from proto3 JSON, is; one read from
protobuf binary may not be.
-}
isValid : Duration -> Bool
isValid =
    Internal.isValid


{-| The duration in normal form: the nanoseconds carried into the seconds and
both given one sign. It keeps the seconds however far they end up: it does
not clamp, so a duration past protobuf's limit stays invalid, as
[`isValid`](#isValid) still says. A valid duration is already normal.

    -- d read from binary as 1 second and -500000000 nanoseconds
    toSecondsAndNanos (normalize d) == { seconds = 0, nanos = 500000000 }

Past 2^53 seconds from zero an Elm `Int` holds the seconds only as closely
as a `Float` does, so normalising such a value may round them.

-}
normalize : Duration -> Duration
normalize =
    Internal.normalize



-- INTERNAL


{-| Normalised, then clamped when the seconds are past protobuf's limit, for
the builders that clamp and the lossy views. A valid duration is kept as it
is.
-}
clamped : Duration -> Duration
clamped duration =
    let
        ((Internal.Duration parts) as normal) =
            Internal.normalize duration
    in
    if parts.seconds > maxSeconds then
        Internal.Duration { seconds = maxSeconds, nanos = 0 }

    else if parts.seconds < -maxSeconds then
        Internal.Duration { seconds = -maxSeconds, nanos = 0 }

    else
        normal


{-| Seconds and nanoseconds of the same sign, if within protobuf's range.
-}
inRange : Int -> Int -> Maybe Duration
inRange wholeSeconds nanos =
    if abs wholeSeconds <= maxSeconds then
        Just (Internal.Duration { seconds = wholeSeconds, nanos = nanos })

    else
        Nothing


{-| A string of ASCII digits as a number; anything else is `Nothing`.
-}
digits : String -> Maybe Int
digits text =
    if not (String.isEmpty text) && String.all Char.isDigit text then
        String.toInt text

    else
        Nothing
