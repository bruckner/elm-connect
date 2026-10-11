module Connect.Timestamp exposing (fromString, toString)

{-| `google.protobuf.Timestamp` as `Time.Posix`, and its proto3 JSON form: an
RFC 3339 date and time such as `"2026-10-10T17:19:45.250Z"`.

`Time.Posix` counts milliseconds, so a timestamp keeps millisecond precision:
finer fractions are read and dropped (rounded toward the past), and none are
ever written.

@docs fromString, toString

-}

import Time


{-| Read an RFC 3339 timestamp, as proto3 JSON writes one and as a parser must
accept one:

  - a date and time, `T` between them: `2026-10-10T17:19:45Z`;
  - an optional fraction of a second of one to nine digits:
    `2026-10-10T17:19:45.25Z`;
  - `Z` for UTC, or an offset, which is applied: `2026-10-10T19:19:45+02:00`
    is `2026-10-10T17:19:45Z`.

The time must lie between years 1 and 9999, as protobuf requires. A leap
second (`23:59:60`) is accepted and read as `23:59:59` with the same fraction,
since `Time.Posix` has no leap seconds. Lowercase `t` and `z` are accepted.

    fromString "1970-01-01T00:00:01.5Z" == Just (Time.millisToPosix 1500)

-}
fromString : String -> Maybe Time.Posix
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
            && List.member (String.slice 10 11 text) [ "T", "t" ]
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


{-| Year, month and day, if they name a day of years 1 to 9999.
-}
civil : Int -> Int -> Int -> Maybe Int
civil year month day =
    if year >= 1 && month >= 1 && month <= 12 && day >= 1 && day <= daysInMonth year month then
        Just (daysFromCivil year month day)

    else
        Nothing


{-| Hours, minutes and seconds as milliseconds of the day, a leap second read
as the second before it.
-}
clock : Int -> Int -> Int -> Maybe Int
clock hour minute second =
    if hour <= 23 && minute <= 59 && second <= 60 then
        Just (((hour * 60 + minute) * 60 + min second 59) * 1000)

    else
        Nothing


{-| The milliseconds of the fraction and the zone's offset in milliseconds.
-}
fractionAndZone : String -> Maybe ( Int, Int )
fractionAndZone rest =
    if String.startsWith "." rest then
        let
            fraction =
                String.dropLeft 1 rest
                    |> String.toList
                    |> takeWhile Char.isDigit
                    |> String.fromList

            places =
                String.length fraction
        in
        if places >= 1 && places <= 9 then
            Maybe.map2 Tuple.pair
                (natural (String.left 3 (fraction ++ "00")))
                (zone (String.dropLeft (1 + places) rest))

        else
            Nothing

    else
        Maybe.map (Tuple.pair 0) (zone rest)


zone : String -> Maybe Int
zone text =
    if text == "Z" || text == "z" then
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
                    Just ((hours * 60 + minutes) * 60000)

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


assemble : Int -> Int -> ( Int, Int ) -> Maybe Time.Posix
assemble days time ( fraction, offset ) =
    let
        millis =
            days * msPerDay + time + fraction - offset
    in
    if millis >= minMillis && millis <= maxMillis then
        Just (Time.millisToPosix millis)

    else
        Nothing


{-| Write a timestamp as proto3 JSON does: RFC 3339 in UTC with a `Z`, and a
fraction of three digits when the time is not a whole second.

    toString (Time.millisToPosix 1500) == "1970-01-01T00:00:01.500Z"

    toString (Time.millisToPosix 0) == "1970-01-01T00:00:00Z"

-}
toString : Time.Posix -> String
toString posix =
    let
        millis =
            Time.posixToMillis posix

        days =
            floor (toFloat millis / toFloat msPerDay)

        ofDay =
            millis - days * msPerDay

        ( year, month, day ) =
            civilFromDays days

        fraction =
            modBy 1000 ofDay

        seconds =
            ofDay // 1000
    in
    pad 4 year
        ++ "-"
        ++ pad 2 month
        ++ "-"
        ++ pad 2 day
        ++ "T"
        ++ pad 2 (seconds // 3600)
        ++ ":"
        ++ pad 2 (modBy 60 (seconds // 60))
        ++ ":"
        ++ pad 2 (modBy 60 seconds)
        ++ (if fraction == 0 then
                ""

            else
                "." ++ pad 3 fraction
           )
        ++ "Z"



-- CALENDAR
--
-- Days since 1970-01-01 in the proleptic Gregorian calendar, after Howard
-- Hinnant's `days_from_civil` and `civil_from_days`. The numbers involved
-- stay well inside 32 bits, where Elm's `//` is exact.


msPerDay : Int
msPerDay =
    86400000


{-| 0001-01-01T00:00:00Z.
-}
minMillis : Int
minMillis =
    daysFromCivil 1 1 1 * msPerDay


{-| 9999-12-31T23:59:59.999Z.
-}
maxMillis : Int
maxMillis =
    daysFromCivil 10000 1 1 * msPerDay - 1


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


takeWhile : (a -> Bool) -> List a -> List a
takeWhile keep items =
    case items of
        first :: rest ->
            if keep first then
                first :: takeWhile keep rest

            else
                []

        [] ->
            []
