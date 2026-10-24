module Rpc.Internal.Call exposing (Call(..), RetryOverride(..), retryIn)

{-| A method applied to its request. Not exposed. Two public modules need the
constructor: `Rpc.call` builds a call, `Rpc.Call` reads and modifies it and
aliases the type, so it lives here, out of users' reach, and a per-call
adjustment can be added without breaking code that holds a call.
-}

import Proto.Method exposing (Method)
import Rpc.Internal.Retry exposing (Retry)


{-| A call; `Rpc.Call`'s readers say what each field holds.
-}
type Call req res
    = Call
        { method : Method req res
        , message : req
        , binding : Int
        , headers : List ( String, String )
        , timeout : Maybe Float
        , tracker : Maybe String
        , retry : RetryOverride
        }


{-| What a call says of retrying: nothing, so the config's policy applies
(`InheritRetry`); never, whatever the config says (`NoRetry`); or by a policy
of its own in place of the config's (`OwnRetry`).
-}
type RetryOverride
    = InheritRetry
    | NoRetry
    | OwnRetry Retry


{-| The policy in effect for a call sent with a config whose policy is
`configured`: the call's own when it has one, else the config's.
-}
retryIn : Maybe Retry -> Call req res -> Maybe Retry
retryIn configured (Call fields) =
    case fields.retry of
        InheritRetry ->
            configured

        NoRetry ->
            Nothing

        OwnRetry policy ->
            Just policy
