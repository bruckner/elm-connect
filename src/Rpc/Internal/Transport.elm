module Rpc.Internal.Transport exposing (Transport(..))

{-| The protocol calls are sent over. Not exposed. Two public modules need
the constructors: `Rpc.Transport` builds a transport and aliases the type,
and `Rpc` matches it to route and send a call. A protocol or an option can be
added without breaking code that builds one.
-}


{-| Connect, with whether an `IdempotencyNoSideEffects` method's call is a GET
and the longest GET URL before it is POSTed instead; or HTTP transcoding.
-}
type Transport
    = Connect { get : Bool, maxGetUrl : Maybe Int }
    | Transcode
