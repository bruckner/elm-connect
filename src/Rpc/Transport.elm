module Rpc.Transport exposing
    ( Transport, connect, connectGet, transcode
    , withMaxGetUrl
    , name
    )

{-| The protocol calls are sent over: the `transport` of a
[`Config`](Rpc#Config).

    { config | transport = Rpc.Transport.transcode }

It is data, like the rest of a config: transports built alike are `==`.

@docs Transport, connect, connectGet, transcode


# Options

@docs withMaxGetUrl


# Reading

@docs name

-}

import Rpc.Internal.Transport as Internal


{-| A transport. Its constructors are private (shown as
`Rpc.Internal.Transport.Transport`, which this module names), so that a
protocol or an option can be added without breaking code that builds one.
-}
type alias Transport =
    Internal.Transport


{-| The [Connect protocol](https://connectrpc.com/docs/protocol/), every call
POSTed, as connect-es does by default.
-}
connect : Transport
connect =
    Internal.Connect { get = False, maxGetUrl = Nothing }


{-| Connect, with a call of a method without side effects
(`IdempotencyNoSideEffects`) sent as a GET with the request in the query, which
caches can serve; any other call is POSTed.

The request then appears in URLs, so in browser history and in server and
proxy logs. Servers and proxies cap URL length too;
[`withMaxGetUrl`](#withMaxGetUrl) POSTs a call whose URL would be longer.

-}
connectGet : Transport
connectGet =
    Internal.Connect { get = True, maxGetUrl = Nothing }


{-| HTTP transcoding, by the method's `google.api.http` rule. A method without
one is called over the implicit route `POST /<service>/<method>`, which
grpc-gateway (`generate_unbound_methods`), Envoy (`auto_mapping`) and Vanguard
serve: the request Connect would POST.
-}
transcode : Transport
transcode =
    Internal.Transcode


{-| POST a call whose GET URL would be longer than this many characters, for
servers and proxies that cap URL length (2048 is a common safe value). Only
[`connectGet`](#connectGet) sends a GET, so the others are unchanged.
-}
withMaxGetUrl : Int -> Transport -> Transport
withMaxGetUrl limit transport =
    case transport of
        Internal.Connect options ->
            Internal.Connect { options | maxGetUrl = Just limit }

        Internal.Transcode ->
            Internal.Transcode


{-| The protocol's name, for traces and logs: `"connect"` (with GET or
without) or `"transcode"`.
-}
name : Transport -> String
name transport =
    case transport of
        Internal.Connect _ ->
            "connect"

        Internal.Transcode ->
            "transcode"
