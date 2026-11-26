module Proto.Timestamp exposing
    ( Timestamp
    , now, fromPosix, toPosix
    , fromString, toString
    , fromSecondsAndNanos, toSecondsAndNanos
    , isValid, normalize
    )

{-| `google.protobuf.Timestamp`: an instant, exact to the nanosecond, between
0001-01-01T00:00:00Z and 9999-12-31T23:59:59.999999999Z, and its proto3 JSON
form: an RFC 3339 date and time such as `"2026-10-10T17:19:45.250Z"`.

Every timestamp this module builds, and every one read from proto3 JSON, is
valid and in normal form: seconds since 1970-01-01T00:00:00Z within years 1
to 9999, and nanoseconds forward from them, 0 to 999,999,999, before 1970
too. A timestamp read from protobuf binary is held as the peer wrote it,
which may not be: its nanoseconds may be negative or a second or more, or
its seconds may lie outside years 1 to 9999, by any amount a 64-bit integer
holds. Such a value is written back to binary exactly as it was read. [`isValid`](#isValid) says whether a
timestamp is valid, and [`normalize`](#normalize) gives its normal form; a
proto3 JSON write of one that is not valid fails with a
`Proto.Error.BadValue`, and [`toString`](#toString) gives `Nothing` for it.

A `Time.Posix` counts milliseconds: [`toPosix`](#toPosix) is a lossy view,
and [`fromPosix`](#fromPosix) is exact.

@docs Timestamp


# Time.Posix

@docs now, fromPosix, toPosix


# proto3 JSON

@docs fromString, toString


# Seconds and nanoseconds

@docs fromSecondsAndNanos, toSecondsAndNanos


# Validity

@docs isValid, normalize

-}

import Proto.Internal.Timestamp as Internal exposing (maxSeconds, minSeconds)
import Task exposing (Task)
import Time


{-| A timestamp, held as protobuf holds it: seconds since
1970-01-01T00:00:00Z and nanoseconds forward from them.

Two timestamps this module built, or read from proto3 JSON, are `==` exactly
when they are the same instant. Two read from protobuf binary that are the
same instant written differently (`1` second and `-500000000` nanoseconds,
and `0` seconds and `500000000` nanoseconds) are not `==`;
[`normalize`](#normalize) makes them `==`.

The package site and compiler errors may show it as
`Proto.Internal.Timestamp.Timestamp`, the module that defines it.

-}
type alias Timestamp =
    Internal.Timestamp


{-| The current time, from `Time.now`, to the millisecond it gives.

    Task.perform GotNow Proto.Timestamp.now

-}
now : Task x Timestamp
now =
    Task.map fromPosix Time.now


{-| The timestamp of a `Time.Posix`, exactly: the same millisecond. It
clamps: a `Time.Posix` before year 1 gives 0001-01-01T00:00:00Z, and one
after year 9999 gives 9999-12-31T23:59:59Z.

    fromPosix (Time.millisToPosix 1500) |> toString == Just "1970-01-01T00:00:01.500Z"

-}
fromPosix : Time.Posix -> Timestamp
fromPosix posix =
    let
        millis =
            Time.posixToMillis posix

        seconds =
            floor (toFloat millis / 1000)
    in
    if seconds < minSeconds then
        Internal.Timestamp { seconds = minSeconds, nanos = 0, wideHigh = 0 }

    else if seconds > maxSeconds then
        Internal.Timestamp { seconds = maxSeconds, nanos = 0, wideHigh = 0 }

    else
        Internal.Timestamp { seconds = seconds, nanos = (millis - seconds * 1000) * 1000000, wideHigh = 0 }


{-| The timestamp as a `Time.Posix`, a lossy view: nanoseconds past the
millisecond are dropped, toward the past (before 1970 too), so an instant
never moves into the next millisecond. A timestamp that is not valid is
normalised, then clamped to years 1 to 9999.

    Proto.Timestamp.fromString "1969-12-31T23:59:59.9999999Z"
        |> Maybe.map (toPosix >> Time.posixToMillis)
        == Just -1

-}
toPosix : Timestamp -> Time.Posix
toPosix timestamp =
    let
        (Internal.Timestamp parts) =
            Internal.clamp (Internal.normalize timestamp)
    in
    Time.millisToPosix (parts.seconds * 1000 + parts.nanos // 1000000)


{-| Read an RFC 3339 timestamp, as proto3 JSON writes one and as a parser must
accept one, keeping every nanosecond:

  - a date and time, `T` between them: `2026-10-10T17:19:45Z`;
  - an optional fraction of a second of one to nine digits:
    `2026-10-10T17:19:45.25Z`;
  - `Z` for UTC, or an offset, which is applied: `2026-10-10T19:19:45+02:00`
    is `2026-10-10T17:19:45Z`.

The time must lie between years 1 and 9999, as protobuf requires. A leap
second (`23:59:60`) is accepted and read as `23:59:59` with the same
fraction, since protobuf's timestamps have no leap seconds. The `T` and the
`Z` must be uppercase: RFC 3339 allows `t` and `z`, proto3 JSON does not.

    fromString "1970-01-01T00:00:01.000000001Z"
        == fromSecondsAndNanos 1 1

-}
fromString : String -> Maybe Timestamp
fromString text =
    let
        digits from to =
            natural (String.slice from to text)

        separator at expected =
            String.slice at (at + 1) text == expected
    in
    if
        separator 4 "-"
            && separator 7 "-"
            && separator 10 "T"
            && separator 13 ":"
            && separator 16 ":"
    then
        Maybe.map3 assemble
            (Maybe.map3 civil (digits 0 4) (digits 5 7) (digits 8 10) |> Maybe.andThen identity)
            (Maybe.map3 clock (digits 11 13) (digits 14 16) (digits 17 19) |> Maybe.andThen identity)
            (fractionAndZone (String.dropLeft 19 text))
            |> Maybe.andThen identity

    else
        Nothing


{-| Write a timestamp as proto3 JSON does: RFC 3339 in UTC with a `Z`, and
nothing, three, six or nine fractional digits, whichever is the fewest that
keep every nanosecond. `Nothing` when the timestamp is not valid, which only
one read from protobuf binary can be; [`normalize`](#normalize) it first to
print one that is within years 1 to 9999 but not in normal form.

    toString (fromPosix (Time.millisToPosix 1500)) == Just "1970-01-01T00:00:01.500Z"

    Maybe.andThen toString (fromSecondsAndNanos 0 1000) == Just "1970-01-01T00:00:00.000001Z"

    toString (fromPosix (Time.millisToPosix 0)) == Just "1970-01-01T00:00:00Z"

-}
toString : Timestamp -> Maybe String
toString ((Internal.Timestamp parts) as timestamp) =
    if Internal.isValid timestamp then
        let
            days =
                floor (toFloat parts.seconds / 86400)

            ofDay =
                parts.seconds - days * 86400

            ( year, month, day ) =
                civilFromDays days

            fraction =
                if parts.nanos == 0 then
                    ""

                else if remainderBy 1000000 parts.nanos == 0 then
                    "." ++ pad 3 (parts.nanos // 1000000)

                else if remainderBy 1000 parts.nanos == 0 then
                    "." ++ pad 6 (parts.nanos // 1000)

                else
                    "." ++ pad 9 parts.nanos
        in
        Just
            (pad 4 year
                ++ "-"
                ++ pad 2 month
                ++ "-"
                ++ pad 2 day
                ++ "T"
                ++ pad 2 (ofDay // 3600)
                ++ ":"
                ++ pad 2 (modBy 60 (ofDay // 60))
                ++ ":"
                ++ pad 2 (modBy 60 ofDay)
                ++ fraction
                ++ "Z"
            )

    else
        Nothing


{-| The timestamp of so many seconds since 1970-01-01T00:00:00Z and
nanoseconds, normalised: the nanoseconds carried into the seconds, leaving
0 to 999,999,999 of them, so `-1` second and `500000000` nanoseconds is
half a second before 1970. `Nothing` when the result lies outside years 1
to 9999.

    fromSecondsAndNanos 1 500000000 == Just (fromPosix (Time.millisToPosix 1500))

    fromSecondsAndNanos 0 -500000000 == fromSecondsAndNanos -1 500000000

    fromSecondsAndNanos 253402300800 0 == Nothing

-}
fromSecondsAndNanos : Int -> Int -> Maybe Timestamp
fromSecondsAndNanos seconds nanos =
    let
        normal =
            Internal.normalize (Internal.Timestamp { seconds = seconds, nanos = nanos, wideHigh = 0 })
    in
    if Internal.isValid normal then
        Just normal

    else
        Nothing


{-| The timestamp's two fields as it holds them, as protobuf's binary form
carries them: for a valid timestamp, seconds since 1970-01-01T00:00:00Z and
0 to 999,999,999 nanoseconds forward from them; for one read from binary,
whatever the peer wrote.

    Maybe.map toSecondsAndNanos (fromString "1969-12-31T23:59:59.250Z")
        == Just { seconds = -1, nanos = 250000000 }

A timestamp read from protobuf binary may hold seconds outside ±(2^53 − 1),
which an Elm `Int` does not hold exactly. The timestamp keeps them exactly
and writes them back to binary as read; this gives the nearest `Int`.

-}
toSecondsAndNanos : Timestamp -> { seconds : Int, nanos : Int }
toSecondsAndNanos ((Internal.Timestamp parts) as timestamp) =
    { seconds = Internal.nearestSeconds timestamp, nanos = parts.nanos }


{-| Whether the timestamp is valid by protobuf's rule: within years 1 to
9999 (0001-01-01T00:00:00Z to 9999-12-31T23:59:59.999999999Z), and its
nanoseconds 0 to 999,999,999. Every timestamp this module builds, and every
one read from proto3 JSON, is; one read from protobuf binary may not be.
-}
isValid : Timestamp -> Bool
isValid =
    Internal.isValid


{-| The timestamp in normal form: the nanoseconds carried into the seconds,
leaving 0 to 999,999,999 of them. It keeps the seconds however far they end
up: it does not clamp, so a timestamp outside years 1 to 9999 stays
invalid, as [`isValid`](#isValid) still says. A valid timestamp is already
normal.

    -- t read from binary as 1 second and -500000000 nanoseconds
    toSecondsAndNanos (normalize t) == { seconds = 0, nanos = 500000000 }

A timestamp whose seconds are outside ±(2^53 − 1), the most an Elm `Int`
holds exactly, or would be once the nanoseconds were carried, is given back
as it is.

-}
normalize : Timestamp -> Timestamp
normalize =
    Internal.normalize



-- PARSING


{-| Year, month and day, if they name a day of years 1 to 9999, as days
since 1970-01-01.
-}
civil : Int -> Int -> Int -> Maybe Int
civil year month day =
    if year >= 1 && month >= 1 && month <= 12 && day >= 1 && day <= daysInMonth year month then
        Just (daysFromCivil year month day)

    else
        Nothing


{-| Hours, minutes and seconds as seconds of the day, a leap second read as
the second before it.
-}
clock : Int -> Int -> Int -> Maybe Int
clock hour minute second =
    if hour <= 23 && minute <= 59 && second <= 60 then
        Just ((hour * 60 + minute) * 60 + min second 59)

    else
        Nothing


{-| The nanoseconds of the fraction and the zone's offset in seconds.
-}
fractionAndZone : String -> Maybe ( Int, Int )
fractionAndZone rest =
    if String.startsWith "." rest then
        let
            places =
                leadingDigits (String.dropLeft 1 rest)

            fraction =
                String.slice 1 (1 + places) rest
        in
        if places >= 1 && places <= 9 then
            Maybe.map2 Tuple.pair
                (natural (String.padRight 9 '0' fraction))
                (zone (String.dropLeft (1 + places) rest))

        else
            Nothing

    else
        Maybe.map (Tuple.pair 0) (zone rest)


zone : String -> Maybe Int
zone text =
    if text == "Z" then
        Just 0

    else if String.length text == 6 && String.slice 3 4 text == ":" then
        let
            sign =
                case String.left 1 text of
                    "+" ->
                        Just 1

                    "-" ->
                        Just -1

                    _ ->
                        Nothing

            offset hours minutes =
                if hours <= 23 && minutes <= 59 then
                    Just ((hours * 60 + minutes) * 60)

                else
                    Nothing
        in
        Maybe.map2 (*)
            sign
            (Maybe.map2 offset (natural (String.slice 1 3 text)) (natural (String.slice 4 6 text))
                |> Maybe.andThen identity
            )

    else
        Nothing


assemble : Int -> Int -> ( Int, Int ) -> Maybe Timestamp
assemble days time ( nanos, offset ) =
    let
        seconds =
            days * 86400 + time - offset
    in
    if seconds >= minSeconds && seconds <= maxSeconds then
        Just (Internal.Timestamp { seconds = seconds, nanos = nanos, wideHigh = 0 })

    else
        Nothing



-- CALENDAR
--
-- Days since 1970-01-01 in the proleptic Gregorian calendar, after Howard
-- Hinnant's `days_from_civil`; its inverse, for printing, is in
-- Proto.Internal.Timestamp. The numbers involved stay well inside 32 bits,
-- where Elm's `//` is exact.


daysFromCivil : Int -> Int -> Int -> Int
daysFromCivil year month day =
    let
        y =
            if month <= 2 then
                year - 1

            else
                year

        era =
            y // 400

        yearOfEra =
            y - era * 400

        dayOfYear =
            (153
                * (if month > 2 then
                    month - 3

                   else
                    month + 9
                  )
                + 2
            )
                // 5
                + day
                - 1

        dayOfEra =
            yearOfEra * 365 + yearOfEra // 4 - yearOfEra // 100 + dayOfYear
    in
    era * 146097 + dayOfEra - 719468


daysInMonth : Int -> Int -> Int
daysInMonth year month =
    if month == 2 then
        if modBy 4 year == 0 && (modBy 100 year /= 0 || modBy 400 year == 0) then
            29

        else
            28

    else if List.member month [ 4, 6, 9, 11 ] then
        30

    else
        31



-- TEXT


{-| A string of ASCII digits as a number; anything else, including an empty
string or a sign, is `Nothing`.
-}
natural : String -> Maybe Int
natural text =
    if not (String.isEmpty text) && String.all Char.isDigit text then
        String.toInt text

    else
        Nothing


pad : Int -> Int -> String
pad width number =
    String.padLeft width '0' (String.fromInt number)


{-| How many ASCII digits `text` starts with. `String.foldl` reads from the
start; `String.toList` reads from the end, and on text starting with a low
surrogate without its high half never returns.
-}
leadingDigits : String -> Int
leadingDigits text =
    String.foldl
        (\char ( count, counting ) ->
            if counting && Char.isDigit char then
                ( count + 1, True )

            else
                ( count, False )
        )
        ( 0, True )
        text
        |> Tuple.first


{-| Year, month and day of a count of days since 1970-01-01 in the proleptic
Gregorian calendar, after Howard Hinnant's `civil_from_days`. The era is
found with `floor` on a `Float`, so any day count an `Int` holds exactly
works; the rest stays inside 32 bits, where Elm's `//` is exact.
-}
civilFromDays : Int -> ( Int, Int, Int )
civilFromDays days =
    let
        z =
            days + 719468

        era =
            floor (toFloat z / 146097)

        dayOfEra =
            z - era * 146097

        yearOfEra =
            (dayOfEra - dayOfEra // 1460 + dayOfEra // 36524 - dayOfEra // 146096) // 365

        dayOfYear =
            dayOfEra - (365 * yearOfEra + yearOfEra // 4 - yearOfEra // 100)

        shiftedMonth =
            (5 * dayOfYear + 2) // 153

        day =
            dayOfYear - (153 * shiftedMonth + 2) // 5 + 1

        month =
            if shiftedMonth < 10 then
                shiftedMonth + 3

            else
                shiftedMonth - 9

        year =
            yearOfEra
                + era
                * 400
                + (if month <= 2 then
                    1

                   else
                    0
                  )
    in
    ( year, month, day )
