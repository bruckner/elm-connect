module Rpc.Internal.Retry exposing (Policy, delay)

{-| When to try a call again. Not exposed; `Rpc.Retry` is `Policy`.
-}

import Proto.Method exposing (Idempotency(..))
import Rpc.ErrorCode exposing (ErrorCode)


{-| The retry policy of a config: `attempts` tries in all, waiting `backoff`
milliseconds before the second and twice as long before each one after, when
an attempt fails with one of `codes`; when `idempotentOnly`, only for a
method declared `IdempotencyNoSideEffects` or `IdempotencyIdempotent`, whose
repeat changes nothing more.
-}
type alias Policy =
    { attempts : Int
    , backoff : Float
    , codes : List ErrorCode
    , idempotentOnly : Bool
    }


{-| How long to wait before trying again, after `tried` attempts of a call
of a method of this idempotency whose last one failed with `code`, or
`Nothing` to stop.
-}
delay : Policy -> Idempotency -> Int -> ErrorCode -> Maybe Float
delay policy idempotency tried code =
    if
        tried
            < policy.attempts
            && List.member code policy.codes
            && (idempotency /= IdempotencyUnknown || not policy.idempotentOnly)
    then
        Just (policy.backoff * toFloat (2 ^ (tried - 1)))

    else
        Nothing
