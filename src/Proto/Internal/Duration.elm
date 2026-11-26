module Proto.Internal.Duration exposing (Duration(..), isValid, maxSeconds, normalize, print, towardZero)

{-| The `Duration` type, defined here so that the binary reader can hold the
fields a peer wrote, which `Proto.Duration` exposes only opaquely and whose
builders always give a valid value.
-}


{-| Whole seconds and nanoseconds, as the binary form carries them.
-}
type Duration
    = Duration { seconds : Int, nanos : Int }


{-| The most seconds a valid duration holds either way, protobuf's limit of
about 10,000 years.
-}
maxSeconds : Int
maxSeconds =
    315576000000


{-| Protobuf's rule: seconds within the limit, nanoseconds below one second
either way, and the two not of opposite signs.
-}
isValid : Duration -> Bool
isValid (Duration parts) =
    (abs parts.seconds <= maxSeconds)
        && (abs parts.nanos < 1000000000)
        && not ((parts.seconds < 0 && parts.nanos > 0) || (parts.seconds > 0 && parts.nanos < 0))


{-| The nanoseconds carried into the seconds and both given one sign, with
`abs nanos` below one second. Nothing is clamped.
-}
normalize : Duration -> Duration
normalize (Duration parts) =
    let
        carried =
            parts.seconds + towardZero (toFloat parts.nanos / 1.0e9)

        rest =
            remainderBy 1000000000 parts.nanos
    in
    if carried > 0 && rest < 0 then
        Duration { seconds = carried - 1, nanos = rest + 1000000000 }

    else if carried < 0 && rest > 0 then
        Duration { seconds = carried + 1, nanos = rest - 1000000000 }

    else
        Duration { seconds = carried, nanos = rest }


{-| The proto3 JSON text of a duration: seconds followed by `s`, with
nothing, three, six or nine fractional digits, whichever is the fewest that
keep every nanosecond. A valid duration is already in normal form; any
other is printed normalised, and one out of range prints seconds a JSON
read refuses. Callers that write JSON check validity first.
-}
print : Duration -> String
print duration =
    let
        (Duration parts) =
            normalize duration

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


{-| Elm's `truncate` works in 32 bits; this rounds toward zero at any size.
-}
towardZero : Float -> Int
towardZero value =
    if value < 0 then
        ceiling value

    else
        floor value
