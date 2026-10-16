module Rpc.Internal.Transport exposing (Transport(..))

{-| The protocol calls are sent over. Not exposed; `Rpc.Transport.Transport`
is this type, its constructors private so that a protocol or an option can be
added without breaking code that builds one.
-}


{-| Connect, with whether an `IdempotencyNoSideEffects` method's call is a GET
and the longest GET URL before it is POSTed instead; or HTTP transcoding.
-}
type Transport
    = Connect { get : Bool, maxGetUrl : Maybe Int }
    | Transcode
