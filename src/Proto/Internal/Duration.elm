module Proto.Internal.Duration exposing (Duration(..), fromWireSeconds, isValid, maxSeconds, nearestSeconds, normalize, towardZero, whyInvalid, wireSeconds)

{-| The `Duration` type, defined here so that the binary reader can hold the
fields a peer wrote, which `Proto.Duration` exposes only opaquely and whose
builders always give a valid value.
-}


{-| Whole seconds and nanoseconds, as the binary form carries them.

The seconds are a 64-bit integer, and an `Int` holds one exactly only within
±(2^53 − 1). For every such value `seconds` is the seconds and `wideHigh` is
0: that is every duration built or read from JSON. For seconds past that,
which only the binary reader gives, the duration is wide: `wideHigh` and
`seconds` are the upper and the lower 32 bits as the wire carries them, in
two's complement, each 0 to 2^32 − 1, and `wideHigh` is never 0. Each
duration has one representation either way, so `==` is exact.

Only this module reads `wideHigh` or takes `seconds` for half of a number:
the rest of the package builds the ordinary case, with `wideHigh = 0`, and
goes through `fromWireSeconds`, `wireSeconds` and `nearestSeconds`.

-}
type Duration
    = Duration { seconds : Int, nanos : Int, wideHigh : Int }


{-| Whether the seconds are past what an `Int` holds exactly, and so held as
two halves.
-}
isWide : Duration -> Bool
isWide (Duration parts) =
    parts.wideHigh /= 0


{-| The duration with the seconds a binary read gives: a pair that is
`( 0, seconds )` when an `Int` holds them exactly and their upper and lower
32 bits otherwise, the upper never 0 then. The nanoseconds are kept.
-}
fromWireSeconds : ( Int, Int ) -> Duration -> Duration
fromWireSeconds ( upper, lower ) (Duration parts) =
    Duration { seconds = lower, nanos = parts.nanos, wideHigh = upper }


{-| The seconds as a binary write takes them: the pair `fromWireSeconds`
reads.
-}
wireSeconds : Duration -> ( Int, Int )
wireSeconds (Duration parts) =
    ( parts.wideHigh, parts.seconds )


{-| The seconds as an `Int`: exactly, or for a wide duration the nearest one.
-}
nearestSeconds : Duration -> Int
nearestSeconds ((Duration parts) as duration) =
    if not (isWide duration) then
        parts.seconds

    else if parts.wideHigh >= twoTo31 then
        -- The upper half's top bit is the sign, in two's complement.
        (parts.wideHigh - twoTo32) * twoTo32 + parts.seconds

    else
        parts.wideHigh * twoTo32 + parts.seconds


twoTo31 : Int
twoTo31 =
    2147483648


twoTo32 : Int
twoTo32 =
    4294967296


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
isValid ((Duration parts) as duration) =
    not (isWide duration)
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
    if isWide duration || abs carried > maxExact then
        duration

    else if carried > 0 && rest < 0 then
        Duration { seconds = carried - 1, nanos = rest + 1000000000, wideHigh = 0 }

    else if carried < 0 && rest > 0 then
        Duration { seconds = carried + 1, nanos = rest - 1000000000, wideHigh = 0 }

    else
        Duration { seconds = carried, nanos = rest, wideHigh = 0 }


{-| 2^53 − 1, the most an `Int` holds exactly.
-}
maxExact : Int
maxExact =
    9007199254740991


{-| Why a duration that is not valid is not, as a proto3 JSON write says it
when it refuses one: its range first, then its nanoseconds, then their sign,
the order protojson checks them in.
-}
whyInvalid : Duration -> String
whyInvalid ((Duration parts) as duration) =
    if abs (nearestSeconds duration) > maxSeconds then
        "the duration is outside -315,576,000,000 to 315,576,000,000 seconds"

    else if abs parts.nanos >= 1000000000 then
        "the nanoseconds are outside -999,999,999 to 999,999,999"

    else
        "the seconds and the nanoseconds have opposite signs"


{-| Elm's `truncate` works in 32 bits; this rounds toward zero at any size.
-}
towardZero : Float -> Int
towardZero value =
    if value < 0 then
        ceiling value

    else
        floor value
