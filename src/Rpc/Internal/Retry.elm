module Rpc.Internal.Retry exposing (Policy, delay)

{-| When to try a call again. Not exposed; `Rpc.Retry` is `Policy`.
-}

import Rpc.Code exposing (Code)


{-| The retry policy of a config: `attempts` tries in all, waiting `backoff`
milliseconds before the second and twice as long before each one after, when
an attempt fails with one of `codes`; only for idempotent calls when
`idempotentOnly`.
-}
type alias Policy =
    { attempts : Int
    , backoff : Float
    , codes : List Code
    , idempotentOnly : Bool
    }


{-| How long to wait before trying again, after `tried` attempts of a call
(`idempotent` or not) whose last one failed with `code` (`Nothing` for a
failure with no code, which is never retried), or `Nothing` to stop.
-}
delay : Policy -> Bool -> Int -> Maybe Code -> Maybe Float
delay policy idempotent tried code =
    case code of
        Just c ->
            if
                tried
                    < policy.attempts
                    && List.member c policy.codes
                    && (idempotent || not policy.idempotentOnly)
            then
                Just (policy.backoff * toFloat (2 ^ (tried - 1)))

            else
                Nothing

        Nothing ->
            Nothing
