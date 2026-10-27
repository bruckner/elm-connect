module Rpc.Retry exposing
    ( Retry, on
    , withAttempts, withBackoff, withMaxBackoff, withDeadline, withoutJitter, allowNonIdempotent
    , next
    )

{-| When to try a failed call again: the `retry` of a
[`Config`](Rpc#Config).

    { config | retry = Just (Rpc.Retry.on [ Rpc.Code.Unavailable ]) }

A policy starts from the codes to retry on, with defaults for the rest, and
modifiers change them:

    Rpc.Retry.on [ Rpc.Code.Unavailable, Rpc.Code.ResourceExhausted ]
        |> Rpc.Retry.withAttempts 5
        |> Rpc.Retry.withBackoff 500

It is data, like the rest of a config: two policies built alike are `==`.

@docs Retry, on


# Changing a policy

@docs withAttempts, withBackoff, withMaxBackoff, withDeadline, withoutJitter, allowNonIdempotent


# Running the schedule yourself

@docs next

-}

import Proto.Method exposing (Idempotency)
import Rpc.Code exposing (Code)
import Rpc.Internal.Retry as Internal
import Time


{-| A retry policy. It is opaque: start one with [`on`](#on), adjust it with
the functions below, and give it to a [`Rpc.Config`](Rpc#Config):

    { config
        | retry =
            Rpc.Retry.on [ Rpc.Code.Unavailable ]
                |> Rpc.Retry.withAttempts 4
                |> Just
    }

The package site and compiler errors may show it as
`Rpc.Internal.Retry.Retry`, its name inside the package; that module is not
exposed.

-}
type alias Retry =
    Internal.Retry


{-| Retry an attempt that fails with an error whose
[`code`](Rpc-Error#code) is one of `codes`, up to 3 attempts in all, waiting before
the second up to 200 ms and twice as long before each one after, never more
than 30 seconds, and only calls of a method declared
`IdempotencyNoSideEffects` or `IdempotencyIdempotent`
([`Rpc.Call.idempotency`](Rpc-Call#idempotency)).

Every error is judged by its code, so a network failure reads as
`Unavailable` and a timeout as `DeadlineExceeded`. A request that timed out
may have reached the server, so `DeadlineExceeded` belongs in `codes` only for
calls that are safe to replay, which the idempotent-only default keeps to. A
bad URL or an invalid header is never retried, whatever its code: nothing was
sent, and nothing would change.

Each wait is drawn uniformly from zero to its bound ("full jitter"), so
clients that failed together do not retry together. The application gives no
`Random` seed or command for it.

-}
on : List Code -> Retry
on codes =
    Internal.Retry
        { attempts = 3
        , backoff = 200
        , maxBackoff = 30000
        , jitter = True
        , codes = codes
        , idempotentOnly = True
        , deadline = Nothing
        }
        Internal.math


{-| How many attempts in all, the first included: `1` never retries, and
neither does a number below it.
-}
withAttempts : Int -> Retry -> Retry
withAttempts attempts (Internal.Retry policy m) =
    Internal.Retry { policy | attempts = attempts } m


{-| The bound in milliseconds on the wait before the second attempt, which
doubles before each one after. A value that is not a positive number waits
not at all.
-}
withBackoff : Float -> Retry -> Retry
withBackoff ms (Internal.Retry policy m) =
    Internal.Retry { policy | backoff = ms } m


{-| The longest wait in milliseconds, however many attempts came before. A
wait is never longer than 2^31 − 1 ms (about 24.8 days) whatever this says,
and a value that is not a positive number waits not at all.
-}
withMaxBackoff : Float -> Retry -> Retry
withMaxBackoff ms (Internal.Retry policy m) =
    Internal.Retry { policy | maxBackoff = ms } m


{-| A bound in milliseconds on all of a call's attempts and the waits between
them together, counted from when the first attempt begins. None by default:
a call's timeout ([`Rpc.Call.withTimeout`](Rpc-Call#withTimeout)) applies to
each attempt alone, so a call may take its attempts times its timeout, and
the waits besides.

    Rpc.Retry.on [ Rpc.Code.Unavailable ]
        |> Rpc.Retry.withAttempts 5
        |> Rpc.Retry.withDeadline 10000

No wait is begun that would end at or past the deadline: the call ends with
the last attempt's result instead. Each attempt's timeout is what is left of
the deadline when it begins, or its own timeout if that is shorter, and over
Connect the server is told so in `Connect-Timeout-Ms`. A deadline that is not
a positive number (`0`, a negative number, NaN or infinity) means none.

-}
withDeadline : Float -> Retry -> Retry
withDeadline ms (Internal.Retry policy m) =
    Internal.Retry { policy | deadline = Just ms } m


{-| Wait each bound in full, without jitter: for tests, and for a single
client whose retries no other client shares.
-}
withoutJitter : Retry -> Retry
withoutJitter (Internal.Retry policy m) =
    Internal.Retry { policy | jitter = False } m


{-| Retry calls of every method, not only those declared
`IdempotencyNoSideEffects` or `IdempotencyIdempotent`: for codes that say the
server did nothing, such as `Unavailable` from a proxy that never reached it. A
call with side effects that failed after the server acted is then made again.
-}
allowNonIdempotent : Retry -> Retry
allowNonIdempotent (Internal.Retry policy m) =
    Internal.Retry { policy | idempotentOnly = False } m


{-| The wait in milliseconds before the next attempt, or `Nothing` to stop:
after `tried` attempts of a call of a method of this `idempotency`, the last
failing with `code`, at `now` and `elapsed` milliseconds after the first
attempt began. It is the decision the runtime makes between its own attempts,
the policy's codes, attempt limit, doubling, cap, jitter and deadline
included.

It is for an application that runs the retry loop itself: to show that it is
waiting, to let the user cancel, or to refresh a credential between attempts.
Such an application sends each attempt with
[`Rpc.Call.withoutRetry`](Rpc-Call#withoutRetry), or the runtime retries each
of its attempts too, and the two stack.

    case
        Rpc.Retry.next policy
            { tried = tried
            , code = Rpc.Error.code err
            , idempotency = Rpc.Call.idempotency call
            , now = now
            , elapsed = toFloat (Time.posixToMillis now - Time.posixToMillis started)
            }
    of
        Just ms ->
            ( Waiting ms, Task.perform (\_ -> TryAgain (tried + 1)) (Process.sleep ms) )

        Nothing ->
            ( Failed err, Cmd.none )

The jitter is drawn from `now`, so the same arguments give the same wait.

-}
next : Retry -> { tried : Int, code : Code, idempotency : Idempotency, now : Time.Posix, elapsed : Float } -> Maybe Float
next =
    Internal.wait
