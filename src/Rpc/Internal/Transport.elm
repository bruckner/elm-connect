module Rpc.Internal.Transport exposing (StreamFraming(..), Transport(..), readMaxBytes, writeMaxBytes)

{-| The protocol calls are sent over. Not exposed. Two public modules need
the constructors: `Rpc.Transport` builds a transport and aliases the type,
and `Rpc` matches it to route and send a call. A protocol or an option can be
added without breaking code that builds one.
-}


{-| Connect, with whether an `IdempotencyNoSideEffects` method's call is a GET,
the longest GET URL before it is POSTed instead, and the largest response
body read and request message sent; or HTTP transcoding, with the largest
response body read and request message sent.
-}
type Transport
    = Connect { get : Bool, maxGetUrl : Maybe Int, readMaxBytes : Maybe Int, writeMaxBytes : Maybe Int }
    | Transcode { readMaxBytes : Maybe Int, writeMaxBytes : Maybe Int, streamFraming : StreamFraming }


{-| How a transcoder frames a server stream's messages.
-}
type StreamFraming
    = GatewayNdjson
    | EnvoyArray
    | EnvoyNdjson
    | EnvoySse


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


{-| The largest request message, in UTF-8 bytes of its JSON, a transport
sends, or `Nothing` for no limit.
-}
writeMaxBytes : Transport -> Maybe Int
writeMaxBytes transport =
    case transport of
        Connect options ->
            options.writeMaxBytes

        Transcode options ->
            options.writeMaxBytes
