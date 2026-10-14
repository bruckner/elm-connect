module Proto.Int64 exposing (toInt, fromInt)

{-| Conversions between the decimal strings elm-connect holds 64-bit integers
in (`int64`, `uint64`, `sint64`, `fixed64`, `sfixed64`) and Elm's `Int`.

Elm's `Int` is exact only within ±(2^53 − 1), ±9007199254740991, so a 64-bit
integer is held as its decimal string by default. These functions convert
where the value is known to fit, and say so when it does not.

@docs toInt, fromInt

-}


{-| The `Int` a decimal string holds, or `Nothing` when it is not a decimal
integer or lies outside ±9007199254740991, where an `Int` would no longer be
exact.

A decimal integer is an optional `-` followed by one or more ASCII digits and
nothing else: no `+`, no spaces, no exponent, no fraction. Leading zeros are
accepted, as proto3 JSON parsers accept them, so `"007"` is `Just 7`.

    toInt "9007199254740991" -- Just 9007199254740991

    toInt "9007199254740992" -- Nothing

    toInt "-42" -- Just -42

    toInt "1e3" -- Nothing

-}
toInt : String -> Maybe Int
toInt text =
    let
        ( negative, digits ) =
            if String.startsWith "-" text then
                ( True, String.dropLeft 1 text )

            else
                ( False, text )

        significant =
            dropZeros digits

        -- Compared as text: past 2^53 a number is already inexact, so a
        -- numeric comparison could misjudge it.
        fits =
            String.length significant
                < 16
                || (String.length significant == 16 && significant <= maxSafe)
    in
    if String.isEmpty digits || not (String.all Char.isDigit digits) || not fits then
        Nothing

    else
        let
            -- Not String.toInt, which can be off by one near 2^53: it adds
            -- each character's code before subtracting that of '0', so an
            -- intermediate sum passes 2^53 and rounds.
            magnitude =
                String.foldl (\char total -> total * 10 + (Char.toCode char - 48)) 0 significant
        in
        if negative then
            Just (0 - magnitude)

        else
            Just magnitude


maxSafe : String
maxSafe =
    "9007199254740991"


dropZeros : String -> String
dropZeros text =
    if String.startsWith "0" text then
        dropZeros (String.dropLeft 1 text)

    else
        text


{-| The decimal string of an `Int`, the form proto3 JSON writes a 64-bit
integer in.

    fromInt -42 -- "-42"

An `Int` outside ±9007199254740991 was already inexact before it got here, so
its string is too.

-}
fromInt : Int -> String
fromInt =
    String.fromInt
