module Rpc.Internal.Retry exposing (Policy, Retry(..), delay, jitter, maxDelay)

{-| When to try a call again. Not exposed. Two public modules need the
constructor: `Rpc.Retry` builds and modifies a policy and aliases the type,
and `Rpc`'s retry loop reads it through `delay` and `jitter`, the policy math
kept here. A knob can be added without breaking code that builds a policy.
-}

import Bitwise
import Proto.Method exposing (Idempotency(..))
import Rpc.Code exposing (Code)


{-| A retry policy.
-}
type Retry
    = Retry Policy


{-| What a policy holds: `attempts` tries in all, when an attempt fails with
one of `codes`; before the second, a wait of up to `backoff` milliseconds,
doubling before each one after and never longer than `maxBackoff`; with
`jitter`, a wait drawn uniformly from zero to that bound; with
`idempotentOnly`, only for a method declared `IdempotencyNoSideEffects` or
`IdempotencyIdempotent`, whose repeat changes nothing more.
-}
type alias Policy =
    { attempts : Int
    , backoff : Float
    , maxBackoff : Float
    , jitter : Bool
    , codes : List Code
    , idempotentOnly : Bool
    }


{-| The longest wait, in milliseconds: 2^31 − 1. `Process.sleep` hands its
delay to `setTimeout`, which runs a longer one at once.
-}
maxDelay : Float
maxDelay =
    2147483647


{-| The bound on the wait before trying again, after `tried` attempts of a
call of a method of this idempotency whose last one failed with `code`, or
`Nothing` to stop. Without jitter it is the wait; with it,
[`jitter`](#jitter) draws the wait below it.
-}
delay : Retry -> Idempotency -> Int -> Code -> Maybe Float
delay (Retry policy) idempotency tried code =
    if
        tried
            < policy.attempts
            && List.member code policy.codes
            && (idempotency /= IdempotencyUnknown || not policy.idempotentOnly)
    then
        let
            doubled =
                nonNegative policy.backoff * 2 ^ toFloat (tried - 1)
        in
        -- 0 times an overflowed doubling is NaN.
        if isNaN doubled then
            Just 0

        else
            Just (min doubled (min maxDelay (nonNegative policy.maxBackoff)))

    else
        Nothing


{-| A number of milliseconds as a wait: NaN and anything below zero are zero.
-}
nonNegative : Float -> Float
nonNegative ms =
    if isNaN ms || ms < 0 then
        0

    else
        ms


{-| The wait before the next attempt, from the bound [`delay`](#delay) gave:
the bound itself without jitter, and with it a point drawn uniformly from
zero to the bound ("full jitter"), so clients that failed together do not
retry together. The draw is a hash of `seed`, the time in milliseconds when
the attempt failed, and of `tried`, so it needs no `Random` generator and
consecutive attempts draw differently.
-}
jitter : Retry -> Int -> Int -> Float -> Float
jitter (Retry policy) seed tried bound =
    if policy.jitter then
        fraction (Bitwise.xor seed (tried * 0x9E3779B9)) * bound

    else
        bound


{-| A number in [0, 1) from the low 32 bits of `seed`, by a 32-bit integer
hash (Chris Wellons's `lowbias32`), whose output bits each depend on every
input bit: times a millisecond apart draw unrelated waits.
-}
fraction : Int -> Float
fraction seed =
    let
        x1 =
            Bitwise.xor seed (Bitwise.shiftRightZfBy 16 seed)

        x2 =
            multiply x1 0x7FEB352D

        x3 =
            Bitwise.xor x2 (Bitwise.shiftRightZfBy 15 x2)

        x4 =
            multiply x3 0x846CA68B

        x5 =
            Bitwise.xor x4 (Bitwise.shiftRightZfBy 16 x4)
    in
    toFloat (Bitwise.shiftRightZfBy 0 x5) / 4294967296


{-| The low 32 bits of a product of two 32-bit integers, as `Math.imul`
gives them. Elm's `*` is a JavaScript number product, which past 2^53 drops
exactly the low bits wanted here, so the product is taken in 16-bit halves.
-}
multiply : Int -> Int -> Int
multiply a b =
    let
        aLow =
            Bitwise.and a 0xFFFF

        aHigh =
            Bitwise.shiftRightZfBy 16 a

        bLow =
            Bitwise.and b 0xFFFF

        bHigh =
            Bitwise.shiftRightZfBy 16 b
    in
    Bitwise.or 0 (aLow * bLow + Bitwise.shiftLeftBy 16 (aHigh * bLow + aLow * bHigh))
