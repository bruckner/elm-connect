module Rpc.Protocol exposing
    ( Protocol, Json, Proto
    , connect, connectProto, transcode, grpcWeb
    , withConnectGet, withMaxGetUrl, withReadMaxBytes, withWriteMaxBytes
    , name, codec, toJson
    )

{-| The protocol calls are sent over, and the codec its messages travel in:
what a [`Client`](Rpc-Client#Client) speaks.

    Rpc.client Rpc.Protocol.connect "https://api.example.com"

A protocol's type says its codec: `Protocol Json` for proto3 JSON,
`Protocol Proto` for protobuf binary. A client of one only sends calls whose
generated code has that codec (`codec=json`, `codec=proto` or `codec=both`),
and the compiler says so where it does not.

Protocols built alike are `==`.

@docs Protocol, Json, Proto
@docs connect, connectProto, transcode, grpcWeb


# Options

@docs withConnectGet, withMaxGetUrl, withReadMaxBytes, withWriteMaxBytes


# Reading

@docs name, codec, toJson

-}

import Json.Encode exposing (Value)
import Proto.Internal.Codec
import Rpc.Internal.Answer as Answer
import Rpc.Internal.Protocol as Internal exposing (Options, Wire(..))
import Rpc.Internal.Wire as Wire


{-| A protocol speaking `codec`. It is opaque: pick one of the values below.
The package site and compiler errors may show it as
`Rpc.Internal.Protocol.Protocol`, its name inside the package.
-}
type alias Protocol codec =
    Internal.Protocol codec


{-| The codec tag of proto3 JSON. It has no values: it is only ever a type.
-}
type alias Json =
    Proto.Internal.Codec.Json


{-| The codec tag of protobuf binary.
-}
type alias Proto =
    Proto.Internal.Codec.Proto



-- A modifier that installs a function (`withConnectGet`, `withReadMaxBytes`,
-- `withWriteMaxBytes`) also writes a field of `options`, which sorts before
-- `wire`. Elm's `==` compares a record's fields in that order and throws on
-- two functions that are not the same one, so two protocols, or two clients,
-- that differ in a modifier compare unequal at `options` before reaching
-- the function it installed; built alike, they hold the same top-level
-- functions, which `==` takes as equal by reference. `Rpc.Retry.on` keeps
-- the same rule: a policy holds its knobs before its math.
--
-- A binary check a modifier installs measures bytes with the wire's own
-- `width`, never `Bytes.width` directly. A modifier names both wires' checks,
-- so a JSON program naming it carries the binary check; only a binary
-- protocol's constructor names `width`, so that program still carries no
-- `Bytes.width`, which would bring elm/bytes' kernel whole.


noOptions : Options
noOptions =
    { get = False, maxGetUrl = Nothing, readMaxBytes = Nothing, writeMaxBytes = Nothing }


{-| The [Connect protocol](https://connectrpc.com/docs/protocol/) over proto3
JSON, every call POSTed, as connect-es does by default.
-}
connect : Protocol Json
connect =
    Internal.Protocol
        { name = "connect"
        , codec = "json"
        , options = noOptions
        , wire =
            Text
                { build = Wire.connectPost
                , routed = False
                , message = Answer.connectMessage
                , tooLarge = Wire.textUnlimited
                , overRead = Wire.textUnlimited
                , timeoutHeader = Wire.connectTimeout
                }
        }


{-| Connect over protobuf binary (`application/proto`). A successful answer is
read as protobuf binary, and must come as `application/proto` or with no
content type; an error answer is JSON, as the protocol sends it.
-}
connectProto : Protocol Proto
connectProto =
    Internal.Protocol
        { name = "connect"
        , codec = "proto"
        , options = noOptions
        , wire =
            Binary
                { build = Wire.connectPostBinary
                , message = Answer.connectProtoMessage
                , tooLarge = Wire.bytesUnlimited
                , overRead = Wire.bytesUnlimited
                , timeoutHeader = Wire.connectTimeout Nothing
                , base64 = Wire.base64
                , width = Wire.width
                }
        }


{-| HTTP transcoding, by the method's `google.api.http` rule. A method without
one is called over the implicit route `POST /<service>/<method>`, which
grpc-gateway (`generate_unbound_methods`), Envoy (`auto_mapping`) and Vanguard
serve: the request Connect would POST.
-}
transcode : Protocol Json
transcode =
    Internal.Protocol
        { name = "transcode"
        , codec = "json"
        , options = noOptions
        , wire =
            Text
                { build = Wire.transcode
                , routed = True
                , message = Answer.transcodeMessage
                , tooLarge = Wire.textUnlimited
                , overRead = Wire.textUnlimited
                , timeoutHeader = Wire.transcodeTimeout
                }
        }


{-| [gRPC-Web](https://github.com/grpc/grpc/blob/master/doc/PROTOCOL-WEB.md),
unary calls, as connect-go, Envoy's gRPC-Web filter and grpcwebproxy serve
it: every call POSTed to `baseUrl/service/method` as
`application/grpc-web+proto`, its request's protobuf binary in one framed
message, a timeout as `grpc-timeout`. The answer's status comes from the
`grpc-status` trailer in its body, or from its headers when the server sent
no message; an error's details from `grpc-status-details-bin`.

Messages travel as protobuf binary only, so it sends the calls of methods
generated with `codec=proto` or `codec=both`. A browser reads `grpc-status`
from the headers of a cross-origin answer only when the server exposes it
(`Access-Control-Expose-Headers`); trailers in the body need nothing. A traced
call ([`Rpc.sendTraced`](Rpc#sendTraced)) gives the body's trailers in
[`Rpc.Trace.trailers`](Rpc-Trace#trailers).

-}
grpcWeb : Protocol Proto
grpcWeb =
    Internal.Protocol
        { name = "grpc-web"
        , codec = "proto"
        , options = noOptions
        , wire =
            Binary
                { build = Wire.grpcWeb
                , message = Answer.grpcWebMessage
                , tooLarge = Wire.bytesUnlimited
                , overRead = Wire.bytesUnlimited
                , timeoutHeader = Wire.grpcWebTimeout
                , base64 = Wire.base64
                , width = Wire.width
                }
        }


{-| Over Connect, send a call of a method without side effects
(`IdempotencyNoSideEffects`) as a GET with the request in the query, which
caches can serve; any other call is POSTed. Other protocols are unchanged.

The request then appears in URLs, so in browser history and in server and
proxy logs. Servers and proxies cap URL length too;
[`withMaxGetUrl`](#withMaxGetUrl) POSTs a call whose URL would be longer.

-}
withConnectGet : Protocol codec -> Protocol codec
withConnectGet (Internal.Protocol p) =
    if p.name == "connect" then
        let
            options =
                p.options
        in
        Internal.Protocol
            { p
                | options = { options | get = True }
                , wire =
                    case p.wire of
                        Text wire ->
                            Text { wire | build = Wire.connectGet }

                        Binary wire ->
                            Binary { wire | build = Wire.connectGetBinary }
            }

    else
        Internal.Protocol p


{-| POST a call whose GET URL, the whole of it with its query, would be longer
than this many characters, for servers and proxies that cap URL length (2048
is a common safe value). Only Connect with
[`withConnectGet`](#withConnectGet) sends a GET, so others are unchanged.
-}
withMaxGetUrl : Int -> Protocol codec -> Protocol codec
withMaxGetUrl limit (Internal.Protocol p) =
    if p.name == "connect" then
        let
            options =
                p.options
        in
        Internal.Protocol { p | options = { options | maxGetUrl = Just limit } }

    else
        Internal.Protocol p


{-| Refuse a successful answer whose body (over gRPC-Web, its response
message) is longer than this many bytes, before decoding it: the call fails
with [`NoAnswer (ResponseTooLarge { limit, size })`](Rpc-Error#Reason), whose code
is `ResourceExhausted`. A protocol starts with no limit.
-}
withReadMaxBytes : Int -> Protocol codec -> Protocol codec
withReadMaxBytes limit (Internal.Protocol p) =
    let
        options =
            p.options
    in
    Internal.Protocol
        { p
            | options = { options | readMaxBytes = Just limit }
            , wire =
                case p.wire of
                    Text wire ->
                        Text { wire | overRead = Answer.textOverRead }

                    Binary wire ->
                        Binary { wire | overRead = Answer.bytesOverRead }
        }


{-| Refuse to send a call whose request message is longer than this many
bytes, as its JSON in UTF-8 or its protobuf binary: the call fails with
[`NoAnswer (RequestTooLarge { limit, size })`](Rpc-Error#Reason), whose code
is `ResourceExhausted`, and nothing is sent. A protocol starts with no limit.
-}
withWriteMaxBytes : Int -> Protocol codec -> Protocol codec
withWriteMaxBytes limit (Internal.Protocol p) =
    let
        options =
            p.options
    in
    Internal.Protocol
        { p
            | options = { options | writeMaxBytes = Just limit }
            , wire =
                case p.wire of
                    Text wire ->
                        Text { wire | tooLarge = Wire.jsonTooLarge }

                    Binary wire ->
                        Binary { wire | tooLarge = Wire.bytesTooLarge }
        }


{-| The protocol's name, for traces and logs: `"connect"`, `"transcode"` or
`"grpc-web"`.
-}
name : Protocol codec -> String
name (Internal.Protocol p) =
    p.name


{-| The codec's name: `"json"` or `"proto"`.
-}
codec : Protocol codec -> String
codec (Internal.Protocol p) =
    p.codec


{-| The protocol as JSON, for logs and tests: its name, codec and options.
-}
toJson : Protocol codec -> Value
toJson (Internal.Protocol p) =
    let
        maybeInt =
            Maybe.map Json.Encode.int >> Maybe.withDefault Json.Encode.null
    in
    Json.Encode.object
        [ ( "name", Json.Encode.string p.name )
        , ( "codec", Json.Encode.string p.codec )
        , ( "get", Json.Encode.bool p.options.get )
        , ( "maxGetUrl", maybeInt p.options.maxGetUrl )
        , ( "readMaxBytes", maybeInt p.options.readMaxBytes )
        , ( "writeMaxBytes", maybeInt p.options.writeMaxBytes )
        ]
