module Rpc.Transport exposing
    ( Transport, connect, connectGet, transcode, grpcWeb
    , withMaxGetUrl, withReadMaxBytes, withWriteMaxBytes
    , Codec(..), withCodec
    , name, codec
    )

{-| The protocol calls are sent over: the `transport` of a
[`Config`](Rpc#Config).

    { config | transport = Rpc.Transport.transcode }

It is data, like the rest of a config: transports built alike are `==`.

@docs Transport, connect, connectGet, transcode, grpcWeb


# Options

@docs withMaxGetUrl, withReadMaxBytes, withWriteMaxBytes


# Codecs

@docs Codec, withCodec


# Reading

@docs name, codec

-}

import Rpc.Internal.Transport as Internal


{-| A transport. It is opaque: pick one of the values below and give it to a
[`Rpc.Config`](Rpc#Config). The package site and compiler errors may show it
as `Rpc.Internal.Transport.Transport`, its name inside the package; that
module is not exposed.
-}
type alias Transport =
    Internal.Transport


{-| The [Connect protocol](https://connectrpc.com/docs/protocol/), every call
POSTed, as connect-es does by default.
-}
connect : Transport
connect =
    Internal.Connect { get = False, maxGetUrl = Nothing, readMaxBytes = Nothing, writeMaxBytes = Nothing, proto = False }


{-| Connect, with a call of a method without side effects
(`IdempotencyNoSideEffects`) sent as a GET with the request in the query, which
caches can serve; any other call is POSTed.

The request then appears in URLs, so in browser history and in server and
proxy logs. Servers and proxies cap URL length too;
[`withMaxGetUrl`](#withMaxGetUrl) POSTs a call whose URL would be longer.

-}
connectGet : Transport
connectGet =
    Internal.Connect { get = True, maxGetUrl = Nothing, readMaxBytes = Nothing, writeMaxBytes = Nothing, proto = False }


{-| HTTP transcoding, by the method's `google.api.http` rule. A method without
one is called over the implicit route `POST /<service>/<method>`, which
grpc-gateway (`generate_unbound_methods`), Envoy (`auto_mapping`) and Vanguard
serve: the request Connect would POST.
-}
transcode : Transport
transcode =
    Internal.Transcode { readMaxBytes = Nothing, writeMaxBytes = Nothing }


{-| [gRPC-Web](https://github.com/grpc/grpc/blob/master/doc/PROTOCOL-WEB.md),
unary calls, as connect-go, Envoy's gRPC-Web filter and grpcwebproxy serve
it: every call POSTed to `baseUrl/service/method` as
`application/grpc-web+proto`, its request's protobuf binary in one framed
message, a timeout as `grpc-timeout`. The answer's status comes from the
`grpc-status` trailer in its body, or from its headers when the server sent
no message; an error's details from `grpc-status-details-bin`.

Messages always travel as protobuf binary, so only methods generated with
binary codecs (`codec=both` or `codec=binary`) can be called; a call of any
other fails with [`NoAnswer (MissingCodec { method, codec })`](Rpc-Error#Reason),
nothing sent. [`withCodec`](#withCodec) leaves it as it is. A browser reads
`grpc-status` from the headers of a cross-origin answer only when the server
exposes it (`Access-Control-Expose-Headers`); trailers in the body need
nothing. A traced call ([`Rpc.sendTraced`](Rpc#sendTraced)) gives the body's
trailers in [`Rpc.Trace.trailers`](Rpc-Trace#trailers).

-}
grpcWeb : Transport
grpcWeb =
    Internal.GrpcWeb { readMaxBytes = Nothing, writeMaxBytes = Nothing }


{-| POST a call whose GET URL, the whole of it with its query, would be longer
than this many characters, for servers and proxies that cap URL length (2048
is a common safe value). Only [`connectGet`](#connectGet) sends a GET, so the
others are unchanged.

    Rpc.Transport.connectGet
        |> Rpc.Transport.withMaxGetUrl 2048

-}
withMaxGetUrl : Int -> Transport -> Transport
withMaxGetUrl limit transport =
    case transport of
        Internal.Connect options ->
            Internal.Connect { options | maxGetUrl = Just limit }

        Internal.Transcode options ->
            Internal.Transcode options

        Internal.GrpcWeb options ->
            Internal.GrpcWeb options


{-| Refuse a successful answer whose body is longer than this many bytes,
before decoding it: the call fails with
[`NoAnswer (ResponseTooLarge { limit, size })`](Rpc-Error#Reason), whose code is
`ResourceExhausted`, as connect-go's `WithReadMaxBytes` and connect-node's
`readMaxBytes` fail it. Every transport starts with no limit. An answer that
is an error is read whatever its size, for the status it states.

    Rpc.Transport.connect
        |> Rpc.Transport.withReadMaxBytes 1000000

The size is that of the body as the browser decoded it, written back as
UTF-8, so it is the bytes on the wire for any body that is UTF-8; under
[`withCodec Proto`](#withCodec) it is the body's bytes as they came. The
browser has already received the body by then: the limit keeps an
oversized response from being decoded and held, not from being downloaded.
A limit below 1 refuses every body that is not empty, and
[`Rpc.checkConfig`](Rpc#checkConfig) reports it.

-}
withReadMaxBytes : Int -> Transport -> Transport
withReadMaxBytes limit transport =
    case transport of
        Internal.Connect options ->
            Internal.Connect { options | readMaxBytes = Just limit }

        Internal.Transcode options ->
            Internal.Transcode { options | readMaxBytes = Just limit }

        Internal.GrpcWeb options ->
            Internal.GrpcWeb { options | readMaxBytes = Just limit }


{-| Refuse to send a call whose request message is longer than this many bytes
of UTF-8, as its JSON: the body of a POST, or for a GET the JSON before it is
percent-encoded into the query; under [`withCodec Proto`](#withCodec), its
protobuf binary, before any base64. The call fails with
[`NoAnswer (RequestTooLarge { limit, size })`](Rpc-Error#Reason), whose code
is `ResourceExhausted`, as connect-go's `WithSendMaxBytes` and connect-node's
`writeMaxBytes` fail it, and nothing is sent. Every transport starts with no
limit. Over transcoding the whole message is measured, whichever of its fields
the binding puts in the path, the query or the body.

A limit below 1 refuses every call, and
[`Rpc.checkConfig`](Rpc#checkConfig) reports it.

-}
withWriteMaxBytes : Int -> Transport -> Transport
withWriteMaxBytes limit transport =
    case transport of
        Internal.Connect options ->
            Internal.Connect { options | writeMaxBytes = Just limit }

        Internal.Transcode options ->
            Internal.Transcode { options | writeMaxBytes = Just limit }

        Internal.GrpcWeb options ->
            Internal.GrpcWeb { options | writeMaxBytes = Just limit }


{-| How request and response messages travel over Connect: as proto3 JSON
(`application/json`, every transport's default), or as protobuf binary
(`application/proto`), which needs the binary codecs that code generated with
`codec=both` or `codec=binary` carries.
-}
type Codec
    = Json
    | Proto


{-| Send and read messages with this codec over Connect.

    Rpc.Transport.connect
        |> Rpc.Transport.withCodec Rpc.Transport.Proto

Under `Proto` a POST carries the request's protobuf binary as
`application/proto`, and a GET ([`connectGet`](#connectGet)) the query
`connect=v1&base64=1&encoding=proto&message=…`, the binary as unpadded
URL-safe base64. A successful answer is read as protobuf binary; an error
answer is JSON whatever the codec, as the Connect protocol sends it, and is
read as it is under `Json`. Sent with [`Rpc.request`](Rpc#request) and
elm/http directly, such an answer is read with
[`Rpc.responseBytes`](Rpc#responseBytes).

A call of a method without binary codecs under `Proto`, or of one with binary
codecs alone (`codec=binary`) under `Json`, is not sent: it fails with
[`NoAnswer (MissingCodec { method, codec })`](Rpc-Error#Reason).

HTTP transcoding is JSON by definition, so [`transcode`](#transcode) is
unchanged, and a method with binary codecs alone cannot be transcoded.

-}
withCodec : Codec -> Transport -> Transport
withCodec chosen transport =
    case transport of
        Internal.Connect options ->
            Internal.Connect { options | proto = chosen == Proto }

        Internal.Transcode options ->
            Internal.Transcode options

        Internal.GrpcWeb options ->
            Internal.GrpcWeb options


{-| The codec messages travel in: `Json` unless
[`withCodec`](#withCodec) chose `Proto` for a Connect transport; `Proto`
over [`grpcWeb`](#grpcWeb).
-}
codec : Transport -> Codec
codec transport =
    if Internal.proto transport then
        Proto

    else
        Json


{-| The protocol's name, for traces and logs: `"connect"` (with GET or
without), `"transcode"` or `"grpc-web"`.
-}
name : Transport -> String
name transport =
    case transport of
        Internal.Connect _ ->
            "connect"

        Internal.Transcode _ ->
            "transcode"

        Internal.GrpcWeb _ ->
            "grpc-web"
