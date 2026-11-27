module Proto.Internal.Duration exposing (Duration(..), isValid, maxSeconds, nanos, nearestSeconds, normalize, print, towardZero, withNanos)

{-| The `Duration` type, defined here so that the binary reader can hold the
fields a peer wrote, which `Proto.Duration` exposes only opaquely and whose
builders always give a valid value.
-}


{-| Whole seconds and nanoseconds, as the binary form carries them:
`Duration seconds nanos`.

The seconds are a 64-bit integer, and an `Int` holds one exactly only within
±(2^53 − 1). `Wide high low nanos` holds seconds past that, which only the
binary reader gives, as the upper and the lower 32 bits the wire carries, in
two's complement, each 0 to 2^32 − 1: the reader keeps the two halves it
read. The reader builds `Wide` for no seconds an `Int` holds, so each
duration has one representation and `==` is exact.

-}
type Duration
    = Duration Int Int
    | Wide Int Int Int


{-| The nanoseconds as held.
-}
nanos : Duration -> Int
nanos duration =
    case duration of
        Duration _ held ->
            held

        Wide _ _ held ->
            held


{-| The same seconds with other nanoseconds.
-}
withNanos : Int -> Duration -> Duration
withNanos value duration =
    case duration of
        Duration seconds _ ->
            Duration seconds value

        Wide high low _ ->
            Wide high low value


{-| The seconds as an `Int`: exactly, or for `Wide` the nearest one.
-}
nearestSeconds : Duration -> Int
nearestSeconds duration =
    case duration of
        Duration seconds _ ->
            seconds

        Wide high low _ ->
            if high >= 2147483648 then
                (high - 4294967296) * 4294967296 + low

            else
                high * 4294967296 + low


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
isValid duration =
    case duration of
        Duration seconds held ->
            (abs seconds <= maxSeconds)
                && (abs held < 1000000000)
                && not ((seconds < 0 && held > 0) || (seconds > 0 && held < 0))

        Wide _ _ _ ->
            False


{-| The nanoseconds carried into the seconds and both given one sign, with
`abs nanos` below one second. Nothing is clamped. A duration whose seconds
are, or would end up, past what an `Int` holds exactly is left as it is: it
is far from valid either way, and the carry would not be exact.
-}
normalize : Duration -> Duration
normalize duration =
    case duration of
        Wide _ _ _ ->
            duration

        Duration seconds held ->
            let
                carried =
                    seconds + towardZero (toFloat held / 1.0e9)

                rest =
                    remainderBy 1000000000 held
            in
            if abs carried > maxExact then
                duration

            else if carried > 0 && rest < 0 then
                Duration (carried - 1) (rest + 1000000000)

            else if carried < 0 && rest > 0 then
                Duration (carried + 1) (rest - 1000000000)

            else
                Duration carried rest


{-| 2^53 − 1, the most an `Int` holds exactly.
-}
maxExact : Int
maxExact =
    9007199254740991


{-| The proto3 JSON text of a duration: seconds followed by `s`, with
nothing, three, six or nine fractional digits, whichever is the fewest that
keep every nanosecond. A valid duration is already in normal form; any
other is printed normalised, and one out of range prints seconds a JSON
read refuses. Callers that write JSON check validity first.
-}
print : Duration -> String
print duration =
    case normalize duration of
        (Wide _ _ _) as wide ->
            String.fromInt (nearestSeconds wide) ++ "s"

        Duration seconds held ->
            let
                sign =
                    if seconds < 0 || held < 0 then
                        "-"

                    else
                        ""

                magnitude =
                    abs held

                fraction =
                    if magnitude == 0 then
                        ""

                    else if remainderBy 1000000 magnitude == 0 then
                        "." ++ String.padLeft 3 '0' (String.fromInt (magnitude // 1000000))

                    else if remainderBy 1000 magnitude == 0 then
                        "." ++ String.padLeft 6 '0' (String.fromInt (magnitude // 1000))

                    else
                        "." ++ String.padLeft 9 '0' (String.fromInt magnitude)
            in
            sign ++ String.fromInt (abs seconds) ++ fraction ++ "s"


{-| Elm's `truncate` works in 32 bits; this rounds toward zero at any size.
-}
towardZero : Float -> Int
towardZero value =
    if value < 0 then
        ceiling value

    else
        floor value
