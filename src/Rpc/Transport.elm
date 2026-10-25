module Rpc.Transport exposing
    ( Transport, connect, connectGet, transcode
    , withMaxGetUrl, withReadMaxBytes, withWriteMaxBytes
    , StreamFraming, gatewayNdjson, envoyArray, envoyNdjson, envoySse, withStreamFraming
    , name
    )

{-| The protocol calls are sent over: the `transport` of a
[`Config`](Rpc#Config).

    { config | transport = Rpc.Transport.transcode }

It is data, like the rest of a config: transports built alike are `==`.

@docs Transport, connect, connectGet, transcode


# Options

@docs withMaxGetUrl, withReadMaxBytes, withWriteMaxBytes


# Stream framing

@docs StreamFraming, gatewayNdjson, envoyArray, envoyNdjson, envoySse, withStreamFraming


# Reading

@docs name

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
    Internal.Connect { get = False, maxGetUrl = Nothing, readMaxBytes = Nothing, writeMaxBytes = Nothing }


{-| Connect, with a call of a method without side effects
(`IdempotencyNoSideEffects`) sent as a GET with the request in the query, which
caches can serve; any other call is POSTed.

The request then appears in URLs, so in browser history and in server and
proxy logs. Servers and proxies cap URL length too;
[`withMaxGetUrl`](#withMaxGetUrl) POSTs a call whose URL would be longer.

-}
connectGet : Transport
connectGet =
    Internal.Connect { get = True, maxGetUrl = Nothing, readMaxBytes = Nothing, writeMaxBytes = Nothing }


{-| HTTP transcoding, by the method's `google.api.http` rule. A method without
one is called over the implicit route `POST /<service>/<method>`, which
grpc-gateway (`generate_unbound_methods`), Envoy (`auto_mapping`) and Vanguard
serve: the request Connect would POST.
-}
transcode : Transport
transcode =
    Internal.Transcode { readMaxBytes = Nothing, writeMaxBytes = Nothing, streamFraming = Internal.GatewayNdjson }


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


{-| Refuse a successful answer whose body is longer than this many bytes of
UTF-8, before decoding it: the call fails with
[`NoAnswer (ResponseTooLarge { limit, size })`](Rpc-Error#Reason), whose code is
`ResourceExhausted`, as connect-go's `WithReadMaxBytes` and connect-node's
`readMaxBytes` fail it. Every transport starts with no limit. An answer that
is an error is read whatever its size, for the status it states.

    Rpc.Transport.connect
        |> Rpc.Transport.withReadMaxBytes 1000000

The size is that of the body as the browser decoded it, written back as
UTF-8, so it is the bytes on the wire for any body that is UTF-8. The
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


{-| Refuse to send a call whose request message is longer than this many bytes
of UTF-8, as its JSON: the body of a POST, or for a GET the JSON before it is
percent-encoded into the query. The call fails with
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


{-| The protocol's name, for traces and logs: `"connect"` (with GET or
without) or `"transcode"`.
-}
name : Transport -> String
name transport =
    case transport of
        Internal.Connect _ ->
            "connect"

        Internal.Transcode _ ->
            "transcode"


{-| How a transcoder frames the messages of a server stream
([`Rpc.Stream`](Rpc-Stream)). Connect has one framing, its envelopes, so this
matters over [`transcode`](#transcode) alone.
-}
type alias StreamFraming =
    Internal.StreamFraming


{-| grpc-gateway's: a `{"result": …}` object per line, and an `{"error": …}`
line for a failure. The default.
-}
gatewayNdjson : StreamFraming
gatewayNdjson =
    Internal.GatewayNdjson


{-| Envoy's gRPC-JSON transcoder's default: one JSON array of the messages.
-}
envoyArray : StreamFraming
envoyArray =
    Internal.EnvoyArray


{-| Envoy with `stream_newline_delimited`: a message per line.
-}
envoyNdjson : StreamFraming
envoyNdjson =
    Internal.EnvoyNdjson


{-| Envoy with `stream_sse_style_delimited`: a `data:` event per message.
-}
envoySse : StreamFraming
envoySse =
    Internal.EnvoySse


{-| The framing a transcoder streams in. Over Connect it changes nothing.

    Rpc.Transport.transcode
        |> Rpc.Transport.withStreamFraming Rpc.Transport.envoyArray

-}
withStreamFraming : StreamFraming -> Transport -> Transport
withStreamFraming framing transport =
    case transport of
        Internal.Connect _ ->
            transport

        Internal.Transcode options ->
            Internal.Transcode { options | streamFraming = framing }
