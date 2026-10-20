module Rpc.Internal.Transport exposing (Transport(..), readMaxBytes)

{-| The protocol calls are sent over. Not exposed. Two public modules need
the constructors: `Rpc.Transport` builds a transport and aliases the type,
and `Rpc` matches it to route and send a call. A protocol or an option can be
added without breaking code that builds one.
-}


{-| Connect, with whether an `IdempotencyNoSideEffects` method's call is a GET,
the longest GET URL before it is POSTed instead, and the largest response
body read; or HTTP transcoding, with the largest response body read.
-}
type Transport
    = Connect { get : Bool, maxGetUrl : Maybe Int, readMaxBytes : Maybe Int }
    | Transcode { readMaxBytes : Maybe Int }


{-| The largest successful response body, in UTF-8 bytes, a transport reads,
or `Nothing` for no limit.
-}
readMaxBytes : Transport -> Maybe Int
readMaxBytes transport =
    case transport of
        Connect options ->
            options.readMaxBytes

        Transcode options ->
            options.readMaxBytes
