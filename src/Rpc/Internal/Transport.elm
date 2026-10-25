module Rpc.Internal.Transport exposing (Transcoder, Transport(..), readMaxBytes, writeMaxBytes)

{-| The protocol calls are sent over. Not exposed. Two public modules need
the constructors: `Rpc.Transport` builds a transport and aliases the type,
and `Rpc` matches it to route and send a call. A protocol or an option can be
added without breaking code that builds one.
-}

import Json.Encode exposing (Value)
import Proto.Internal.Binding exposing (Rule)
import Rpc.Body exposing (Body)


{-| Connect, with whether an `IdempotencyNoSideEffects` method's call is a GET,
the longest GET URL before it is POSTed instead, and the largest response
body read and request message sent; or HTTP transcoding, with the largest
response body read and request message sent, and the code that fills a
binding's URL and body.
-}
type Transport
    = Connect { get : Bool, maxGetUrl : Maybe Int, readMaxBytes : Maybe Int, writeMaxBytes : Maybe Int }
    | Transcode { readMaxBytes : Maybe Int, writeMaxBytes : Maybe Int, transcoder : Transcoder }


{-| How a call goes over one binding of its rule: the URL from the base URL and
the request's JSON, the body, and the first path value its template cannot
match. `Rpc.Transport.transcode` holds `Rpc.Internal.Route`'s functions here,
rather than `Rpc.Internal.Wire` calling them by name, so a program that never
builds a transcoding transport does not reach them and the compiler leaves
them out. Every transcoding transport holds the same functions, and elm/core's
`==` compares values by reference before it looks inside them, so two
transports built alike are still `==`, and comparing them never reaches a
function.
-}
type alias Transcoder =
    { url : String -> Rule -> Value -> String
    , body : Rule -> Value -> Body
    , invalidPathValue : Rule -> Value -> Maybe { field : String, template : String }
    }


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
