module Rpc.Retry exposing
    ( Retry, on
    , withAttempts, withBackoff, withMaxBackoff, withoutJitter, allowNonIdempotent
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

@docs withAttempts, withBackoff, withMaxBackoff, withoutJitter, allowNonIdempotent

-}

import Rpc.Code exposing (Code)
import Rpc.Internal.Retry as Internal


{-| A retry policy. It is opaque: start one with [`on`](#on), adjust it with
the functions below, and give it to a [`Rpc.Config`](Rpc#Config).
-}
type alias Retry =
    Internal.Retry


{-| Retry an attempt that fails with an error whose
[`code`](Rpc#code) is one of `codes`, up to 3 attempts in all, waiting before
the second up to 200 ms and twice as long before each one after, never more
than 30 seconds, and only calls of a method declared
`IdempotencyNoSideEffects` or `IdempotencyIdempotent`
([`Rpc.Call.idempotency`](Rpc-Call#idempotency)).

Every error is judged by its code, so a network failure reads as
`Unavailable` and a timeout as `DeadlineExceeded`. A request that timed out
may have reached the server, so `DeadlineExceeded` belongs in `codes` only for
calls that are safe to replay, which the idempotent-only default keeps to.

Each wait is drawn uniformly from zero to its bound ("full jitter"), so
clients that failed together do not retry together; the draw is seeded from
the clock the loop reads, so it needs no `Random` command.

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
        }


{-| How many attempts in all, the first included: `1` never retries.
-}
withAttempts : Int -> Retry -> Retry
withAttempts attempts (Internal.Retry policy) =
    Internal.Retry { policy | attempts = attempts }


{-| The bound in milliseconds on the wait before the second attempt, which
doubles before each one after. A value that is not a positive number waits
not at all.
-}
withBackoff : Float -> Retry -> Retry
withBackoff ms (Internal.Retry policy) =
    Internal.Retry { policy | backoff = ms }


{-| The longest wait in milliseconds, however many attempts came before. A
wait is never longer than 2^31 − 1 ms (about 24.8 days) whatever this says,
since `Process.sleep` runs a longer one at once.
-}
withMaxBackoff : Float -> Retry -> Retry
withMaxBackoff ms (Internal.Retry policy) =
    Internal.Retry { policy | maxBackoff = ms }


{-| Wait each bound in full, without jitter: for tests, and for a single
client whose retries no other client shares.
-}
withoutJitter : Retry -> Retry
withoutJitter (Internal.Retry policy) =
    Internal.Retry { policy | jitter = False }


{-| Retry calls of every method, not only those declared
`IdempotencyNoSideEffects` or `IdempotencyIdempotent`: for codes that say the
server did nothing, such as `Unavailable` from a proxy that never reached it. A
call with side effects that failed after the server acted is then made again.
-}
allowNonIdempotent : Retry -> Retry
allowNonIdempotent (Internal.Retry policy) =
    Internal.Retry { policy | idempotentOnly = False }
