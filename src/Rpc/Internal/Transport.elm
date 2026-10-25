module Rpc.Internal.Transport exposing (Transport(..), proto, readMaxBytes, writeMaxBytes)

{-| The protocol calls are sent over. Not exposed. Two public modules need
the constructors: `Rpc.Transport` builds a transport and aliases the type,
and `Rpc` matches it to route and send a call. A protocol or an option can be
added without breaking code that builds one.
-}


{-| Connect, with whether an `IdempotencyNoSideEffects` method's call is a GET,
the longest GET URL before it is POSTed instead, the largest response body
read and request message sent, and whether messages travel as protobuf
binary (`proto`) rather than JSON; or HTTP transcoding, with the largest
response body read and request message sent, always JSON; or gRPC-Web, with
the largest response message read and request message sent, always
protobuf binary.
-}
type Transport
    = Connect { get : Bool, maxGetUrl : Maybe Int, readMaxBytes : Maybe Int, writeMaxBytes : Maybe Int, proto : Bool }
    | Transcode { readMaxBytes : Maybe Int, writeMaxBytes : Maybe Int }
    | GrpcWeb { readMaxBytes : Maybe Int, writeMaxBytes : Maybe Int }


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

        GrpcWeb options ->
            options.readMaxBytes


{-| The largest request message, in bytes of its JSON or its protobuf
binary, a transport sends, or `Nothing` for no limit.
-}
writeMaxBytes : Transport -> Maybe Int
writeMaxBytes transport =
    case transport of
        Connect options ->
            options.writeMaxBytes

        Transcode options ->
            options.writeMaxBytes

        GrpcWeb options ->
            options.writeMaxBytes


{-| Whether calls go as protobuf binary: over Connect with the proto codec,
and over gRPC-Web.
-}
proto : Transport -> Bool
proto transport =
    case transport of
        Connect options ->
            options.proto

        Transcode _ ->
            False

        GrpcWeb _ ->
            True
