module Proto.Internal.Timestamp exposing (Timestamp(..), clamp, fromWireSeconds, isValid, maxSeconds, minSeconds, nearestSeconds, normalize, whyInvalid, wireSeconds)

{-| The `Timestamp` type, defined here so that the binary reader can hold the
fields a peer wrote, which `Proto.Timestamp` exposes only opaquely and whose
builders always give a valid value.
-}


{-| Seconds since 1970-01-01T00:00:00Z and nanoseconds forward from them, as
the binary form carries them.

The seconds are a 64-bit integer, and an `Int` holds one exactly only within
±(2^53 − 1). For every such value `seconds` is the seconds and `wideHigh` is
0: that is every timestamp built or read from JSON. For seconds past that,
which only the binary reader gives, the timestamp is wide: `wideHigh` and
`seconds` are the upper and the lower 32 bits as the wire carries them, in
two's complement, each 0 to 2^32 − 1, and `wideHigh` is never 0. Each
timestamp has one representation either way, so `==` is exact.

Only this module reads `wideHigh` or takes `seconds` for half of a number:
the rest of the package builds the ordinary case, with `wideHigh = 0`, and
goes through `fromWireSeconds`, `wireSeconds` and `nearestSeconds`.

-}
type Timestamp
    = Timestamp { seconds : Int, nanos : Int, wideHigh : Int }


{-| Whether the seconds are past what an `Int` holds exactly, and so held as
two halves.
-}
isWide : Timestamp -> Bool
isWide (Timestamp parts) =
    parts.wideHigh /= 0


{-| The timestamp with the seconds a binary read gives: a pair that is
`( 0, seconds )` when an `Int` holds them exactly and their upper and lower
32 bits otherwise, the upper never 0 then. The nanoseconds are kept.
-}
fromWireSeconds : ( Int, Int ) -> Timestamp -> Timestamp
fromWireSeconds ( upper, lower ) (Timestamp parts) =
    Timestamp { seconds = lower, nanos = parts.nanos, wideHigh = upper }


{-| The seconds as a binary write takes them: the pair `fromWireSeconds`
reads.
-}
wireSeconds : Timestamp -> ( Int, Int )
wireSeconds (Timestamp parts) =
    ( parts.wideHigh, parts.seconds )


{-| The seconds as an `Int`: exactly, or for a wide timestamp the nearest one.
-}
nearestSeconds : Timestamp -> Int
nearestSeconds ((Timestamp parts) as timestamp) =
    if not (isWide timestamp) then
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


{-| 2^53 − 1, the most an `Int` holds exactly.
-}
maxExact : Int
maxExact =
    9007199254740991


{-| 0001-01-01T00:00:00Z, the earliest second a valid timestamp holds.
-}
minSeconds : Int
minSeconds =
    -62135596800


{-| 9999-12-31T23:59:59Z, the latest second a valid timestamp holds.
-}
maxSeconds : Int
maxSeconds =
    253402300799


{-| Protobuf's rule: seconds within years 1 to 9999, and nanoseconds 0 to
999,999,999, before 1970 too.
-}
isValid : Timestamp -> Bool
isValid ((Timestamp parts) as timestamp) =
    not (isWide timestamp) && parts.seconds >= minSeconds && parts.seconds <= maxSeconds && parts.nanos >= 0 && parts.nanos < 1000000000


{-| The nanoseconds carried into the seconds, leaving 0 to 999,999,999 of
them. Nothing is clamped. A timestamp whose seconds are, or would end up,
past what an `Int` holds exactly is left as it is: it is far from valid
either way, and the carry would not be exact.
-}
normalize : Timestamp -> Timestamp
normalize ((Timestamp parts) as timestamp) =
    let
        rest =
            modBy 1000000000 parts.nanos

        -- The difference is a whole number of seconds, so the division is
        -- exact; `round` does not truncate to 32 bits as `//` does.
        carried =
            parts.seconds + Basics.round (toFloat (parts.nanos - rest) / 1.0e9)
    in
    if isWide timestamp || abs carried > maxExact then
        timestamp

    else
        Timestamp { seconds = carried, nanos = rest, wideHigh = 0 }


{-| A normal timestamp outside years 1 to 9999 as the nearest limit, with no
nanoseconds; any other unchanged.
-}
clamp : Timestamp -> Timestamp
clamp normal =
    let
        seconds =
            nearestSeconds normal
    in
    if seconds < minSeconds then
        Timestamp { seconds = minSeconds, nanos = 0, wideHigh = 0 }

    else if seconds > maxSeconds then
        Timestamp { seconds = maxSeconds, nanos = 0, wideHigh = 0 }

    else
        normal


{-| Why a timestamp that is not valid is not, as a proto3 JSON write says it
when it refuses one: its range first, then its nanoseconds, the order
protojson checks them in.
-}
whyInvalid : Timestamp -> String
whyInvalid timestamp =
    let
        seconds =
            nearestSeconds timestamp
    in
    if seconds < minSeconds || seconds > maxSeconds then
        "the time is outside years 1 to 9999"

    else
        "the nanoseconds are outside 0 to 999,999,999"
