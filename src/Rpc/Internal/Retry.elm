module Rpc.Internal.Retry exposing (Moment, Outcome, Policy, Retry(..), attemptTimeout, budget, delay, jitter, maxDelay, run, step, wait)

{-| When to try a call again. Not exposed. Two public modules need the
constructor: `Rpc.Retry` builds and modifies a policy and aliases the type,
and `Rpc` reads it through `run`, the attempt loop. The loop decides each
wait with [`step`](#step), which is [`wait`](#wait), the policy math
(`delay`, `jitter` and the deadline), applied to a failed attempt; the math
is kept pure and here so it can be tested without sending anything. A knob
can be added without breaking code that builds a policy.
-}

import Bitwise
import Http
import Process
import Proto.Method exposing (Idempotency(..))
import Rpc.Code exposing (Code)
import Task exposing (Task)
import Time


{-| A retry policy.
-}
type Retry
    = Retry Policy


{-| What a policy holds: `attempts` tries in all, when an attempt fails with
one of `codes`; before the second, a wait of up to `backoff` milliseconds,
doubling before each one after and never longer than `maxBackoff`; with
`jitter`, a wait drawn uniformly from zero to that bound; with
`idempotentOnly`, only for a method declared `IdempotencyNoSideEffects` or
`IdempotencyIdempotent`, whose repeat changes nothing more; with `deadline`,
all attempts and waits within that many milliseconds of the first attempt.
-}
type alias Policy =
    { attempts : Int
    , backoff : Float
    , maxBackoff : Float
    , jitter : Bool
    , codes : List Code
    , idempotentOnly : Bool
    , deadline : Maybe Float
    }


{-| What sending a call came to: the attempts made, the last answer's status
and headers (`Nothing` when there was none), and the result.
-}
type alias Outcome e a =
    { attempts : Int
    , metadata : Maybe Http.Metadata
    , result : Result e a
    }


{-| Where a call stands after a failed attempt: `tried` attempts made, the
last failing with `code`, of a method of `idempotency`, at `now`, `elapsed`
milliseconds after the first began.
-}
type alias Moment =
    { tried : Int
    , code : Code
    , idempotency : Idempotency
    , now : Time.Posix
    , elapsed : Float
    }


{-| Run `once` until it succeeds or the policy, if there is one, says to
stop. `once` is given the milliseconds left of the policy's deadline when the
attempt begins, or `Nothing` without one, to bound its timeout by
([`attemptTimeout`](#attemptTimeout)). `retryCode` gives the code a failure is
retried by, or `Nothing` when trying again cannot help. The clock is read
before the first attempt, after each failure and after each wait; without a
policy, `once` runs alone.
-}
run : Maybe Retry -> Idempotency -> (e -> Maybe Code) -> (Maybe Float -> Task Never ( Maybe Http.Metadata, Result e a )) -> Task Never (Outcome e a)
run retry idempotency retryCode once =
    case retry of
        Nothing ->
            once Nothing
                |> Task.map (\( metadata, result ) -> { attempts = 1, metadata = metadata, result = result })

        Just policy ->
            Time.now
                |> Task.andThen
                    (\start ->
                        let
                            since time =
                                toFloat (Time.posixToMillis time - Time.posixToMillis start)

                            loop tried elapsed =
                                once (budget policy elapsed)
                                    |> Task.andThen
                                        (\( metadata, result ) ->
                                            Time.now
                                                |> Task.andThen
                                                    (\now ->
                                                        case step retry idempotency retryCode { tried = tried, now = now, elapsed = since now } result of
                                                            Just ms ->
                                                                Process.sleep ms
                                                                    |> Task.andThen (\_ -> Time.now)
                                                                    |> Task.andThen (\woke -> loop (tried + 1) (since woke))

                                                            Nothing ->
                                                                Task.succeed { attempts = tried, metadata = metadata, result = result }
                                                    )
                                        )
                        in
                        loop 1 0
                    )


{-| The loop's decision after an attempt: the wait before the next, or
`Nothing` to stop, which a success, a missing policy or a failure trying again
cannot help (`retryCode` gives `Nothing`) always is.
-}
step : Maybe Retry -> Idempotency -> (e -> Maybe Code) -> { tried : Int, now : Time.Posix, elapsed : Float } -> Result e a -> Maybe Float
step retry idempotency retryCode at result =
    case ( retry, result ) of
        ( Just policy, Err error ) ->
            retryCode error
                |> Maybe.andThen
                    (\code ->
                        wait policy
                            { tried = at.tried
                            , code = code
                            , idempotency = idempotency
                            , now = at.now
                            , elapsed = at.elapsed
                            }
                    )

        _ ->
            Nothing


{-| The wait in milliseconds before the next attempt, or `Nothing` to stop:
the bound [`delay`](#delay) gives, drawn below by [`jitter`](#jitter), seeded
from `now`; and `Nothing` when that wait would end at or past the deadline.
-}
wait : Retry -> Moment -> Maybe Float
wait retry moment =
    delay retry moment.idempotency moment.tried moment.code
        |> Maybe.map (jitter retry (Time.posixToMillis moment.now) moment.tried)
        |> Maybe.andThen
            (\ms ->
                case deadline retry of
                    Just limit ->
                        if moment.elapsed + ms < limit then
                            Just ms

                        else
                            Nothing

                    Nothing ->
                        Just ms
            )


{-| The policy's deadline, when it is a positive finite number of
milliseconds; any other value means none, as for a timeout.
-}
deadline : Retry -> Maybe Float
deadline (Retry policy) =
    case policy.deadline of
        Just ms ->
            if ms > 0 && not (isInfinite ms) then
                Just ms

            else
                Nothing

        Nothing ->
            Nothing


{-| What is left of the deadline `elapsed` milliseconds after the first
attempt began, or `Nothing` without a deadline. It is at least 1 ms: a
timeout below that would read as none, and the wait that came before was
already kept short of the deadline, so only a late timer gets here.
-}
budget : Retry -> Float -> Maybe Float
budget retry elapsed =
    deadline retry
        |> Maybe.map (\limit -> max 1 (limit - elapsed))


{-| An attempt's timeout under what is left of a deadline: with no budget the
timeout as it is, with no timeout the budget, and otherwise the smaller of
the two. The timeout is a usable one, a positive number, or `Nothing`.
-}
attemptTimeout : Maybe Float -> Maybe Float -> Maybe Float
attemptTimeout left timeout =
    case ( left, timeout ) of
        ( Just ms, Just t ) ->
            Just (min ms t)

        ( Just ms, Nothing ) ->
            Just ms

        ( Nothing, _ ) ->
            timeout


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
