module Proto.Internal.Duration exposing (Duration(..), isValid, maxSeconds, nearestSeconds, normalize, print, towardZero)

{-| The `Duration` type, defined here so that the binary reader can hold the
fields a peer wrote, which `Proto.Duration` exposes only opaquely and whose
builders always give a valid value.
-}


{-| Whole seconds and nanoseconds, as the binary form carries them.

The seconds are a 64-bit integer, and an `Int` holds one exactly only within
±(2^53 − 1). For every such value `seconds` is the seconds and `high` is 0.
For seconds past that, which only the binary reader gives, `high` and
`seconds` are the upper and the lower 32 bits as the wire carries them, in
two's complement, each 0 to 2^32 − 1: the reader keeps the two halves it
read. `high` is never 0 there. Each duration has one representation either
way, so `==` is exact.

-}
type Duration
    = Duration { seconds : Int, nanos : Int, high : Int }


{-| The seconds as an `Int`: exactly, or the nearest one when `high` is not 0.
-}
nearestSeconds : Duration -> Int
nearestSeconds (Duration parts) =
    if parts.high == 0 then
        parts.seconds

    else if parts.high >= 2147483648 then
        (parts.high - 4294967296) * 4294967296 + parts.seconds

    else
        parts.high * 4294967296 + parts.seconds


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
    (parts.high == 0)
        && (abs parts.seconds <= maxSeconds)
        && (abs parts.nanos < 1000000000)
        && not ((parts.seconds < 0 && parts.nanos > 0) || (parts.seconds > 0 && parts.nanos < 0))


{-| The nanoseconds carried into the seconds and both given one sign, with
`abs nanos` below one second. Nothing is clamped. A duration whose seconds
are, or would end up, past what an `Int` holds exactly is left as it is: it
is far from valid either way, and the carry would not be exact.
-}
normalize : Duration -> Duration
normalize ((Duration parts) as duration) =
    let
        carried =
            parts.seconds + towardZero (toFloat parts.nanos / 1.0e9)

        rest =
            remainderBy 1000000000 parts.nanos
    in
    if parts.high /= 0 || abs carried > maxExact then
        duration

    else if carried > 0 && rest < 0 then
        Duration { seconds = carried - 1, nanos = rest + 1000000000, high = 0 }

    else if carried < 0 && rest > 0 then
        Duration { seconds = carried + 1, nanos = rest - 1000000000, high = 0 }

    else
        Duration { seconds = carried, nanos = rest, high = 0 }


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
    let
        ((Duration parts) as normal) =
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
    if parts.high /= 0 then
        String.fromInt (nearestSeconds normal) ++ "s"

    else
        sign ++ String.fromInt (abs parts.seconds) ++ fraction ++ "s"


{-| Elm's `truncate` works in 32 bits; this rounds toward zero at any size.
-}
towardZero : Float -> Int
towardZero value =
    if value < 0 then
        ceiling value

    else
        floor value
