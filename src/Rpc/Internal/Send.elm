module Rpc.Internal.Send exposing (Plan, binding, expect, plan, refused, request, requestBase64, resolver, response, responseBytes, withBudget)

{-| How a call goes over a client's protocol: the one place a call's method
meets the protocol's functions. Not exposed; `Rpc` sends through it.

A call's [`plan`](#plan) is what the protocol's kind of wire, text or bytes,
makes of the method's codecs: monomorphic from there on, so the rest of
sending is ordinary functions over it. The only branch every program
carries is that two-way choice.

The codec phantom keeps a protocol from meeting a method without the codec
it speaks, so a plan is always a `TextPlan` or a `BytesPlan`. `Unplannable`
is what the representation still allows: a method value whose half is
`Nothing`. No program can build that pairing, so it is an internal error
naming the invariant, never a public reason.

-}

import Bytes exposing (Bytes)
import Http
import Json.Decode exposing (Decoder)
import Json.Encode exposing (Value)
import Proto.Internal.Method exposing (Method(..))
import Proto.Method exposing (Endpoint)
import Proto.Route exposing (Route)
import Rpc.Body
import Rpc.Error as Error exposing (Error)
import Rpc.Internal.Answer as Answer
import Rpc.Internal.Call exposing (Call(..))
import Rpc.Internal.Client exposing (Client(..))
import Rpc.Internal.Http as Internal
import Rpc.Internal.Protocol exposing (BinaryWire, Options, Protocol(..), Settings, TextWire, Wire(..))
import Rpc.Internal.Retry as Retry
import Rpc.Internal.Wire as Wire
import Rpc.Request exposing (Request)


type Plan res
    = TextPlan
        { wire : TextWire
        , options : Options
        , settings : Settings
        , endpoint : Endpoint
        , route : Maybe Route
        , binding : Maybe Int
        , json : () -> Value
        , decoder : Decoder res
        }
    | BytesPlan
        { wire : BinaryWire
        , options : Options
        , settings : Settings
        , endpoint : Endpoint
        , binary : () -> Bytes
        , decode : Bytes -> Maybe res
        }
    | Unplannable String


{-| A call's plan over a client. The route is built only over a protocol
that reads routes, once, and shared by the request and the answer.
-}
plan : Client codec -> Call codec req res -> Plan res
plan (Client cl) (Call c) =
    let
        (Protocol p) =
            cl.protocol

        (Method m) =
            c.method

        settings =
            { baseUrl = cl.baseUrl
            , headers = cl.headers ++ c.headers
            , timeout =
                case Wire.usableTimeout c.timeout of
                    Just ms ->
                        Just ms

                    Nothing ->
                        Wire.usableTimeout cl.timeout
            , withCredentials = cl.withCredentials
            }
    in
    case p.wire of
        Text wire ->
            case m.json of
                Just half ->
                    let
                        route =
                            if wire.routed then
                                List.head (List.drop c.binding m.routes)
                                    |> Maybe.map (\routeOf -> routeOf c.message)

                            else
                                Nothing
                    in
                    TextPlan
                        { wire = wire
                        , options = p.options
                        , settings = settings
                        , endpoint = m.endpoint
                        , route = route
                        , binding = Maybe.map (\_ -> c.binding) route
                        , json = \() -> half.encode c.message
                        , decoder = half.decoder
                        }

                Nothing ->
                    Unplannable "a protocol speaking JSON met a method without JSON codecs"

        Binary wire ->
            case m.binary of
                Just half ->
                    BytesPlan
                        { wire = wire
                        , options = p.options
                        , settings = settings
                        , endpoint = m.endpoint
                        , binary = \() -> half.encode c.message
                        , decode = half.decode
                        }

                Nothing ->
                    Unplannable "a protocol speaking protobuf binary met a method without binary codecs"


{-| The request a plan sends.
-}
request : Plan res -> Request
request p =
    case p of
        TextPlan t ->
            t.wire.build t.options t.settings t.endpoint t.route (t.json ())

        BytesPlan b ->
            b.wire.build b.wire.base64 b.options b.settings b.endpoint (b.binary ())

        Unplannable _ ->
            { method = "POST", url = "", headers = [], body = Rpc.Body.none, timeout = Nothing, withCredentials = False }


{-| Why `sent`, the plan's request or one an application rewrote, must not
reach elm/http: a base URL holding a query or a fragment; a path value its
variable's template cannot match, which no server can route to the method; a
header a browser refuses, on which XHR's `setRequestHeader` throws outside
elm/http's handler and stops the program for good; or a request message over
the protocol's write limit. The path values and the message are the call's,
whatever a rewritten request carries.
-}
refused : String -> Plan res -> Request -> Maybe Error
refused baseUrl p sent =
    if Internal.badBaseUrl baseUrl then
        Just (Error.NoAnswer (Error.BadUrl sent.url))

    else
        case p of
            TextPlan t ->
                case ( Maybe.andThen .invalid t.route, Internal.invalidHeader sent.headers ) of
                    ( Just path, _ ) ->
                        Just (Error.NoAnswer (Error.InvalidPathValue path))

                    ( Nothing, Just name ) ->
                        Just (Error.NoAnswer (Error.InvalidHeader name))

                    ( Nothing, Nothing ) ->
                        t.wire.tooLarge t.options (t.json ()) |> Maybe.map Error.NoAnswer

            BytesPlan b ->
                case Internal.invalidHeader sent.headers of
                    Just name ->
                        Just (Error.NoAnswer (Error.InvalidHeader name))

                    Nothing ->
                        b.wire.tooLarge b.options (b.binary ()) |> Maybe.map Error.NoAnswer

            Unplannable invariant ->
                Just (Answer.unreachable invariant)


{-| How elm/http reads a plan's answer, for a command.
-}
expect : (Result Error res -> msg) -> Plan res -> Http.Expect msg
expect toMsg p =
    case p of
        TextPlan t ->
            Http.expectStringResponse toMsg (Answer.textResult t.wire t.options t.route t.decoder)

        BytesPlan b ->
            Http.expectBytesResponse toMsg (Answer.bytesResult b.wire b.options b.endpoint b.decode >> Tuple.second)

        Unplannable invariant ->
            Http.expectStringResponse toMsg (\_ -> Err (Answer.unreachable invariant))


{-| How elm/http reads a plan's answer, for a task, with its metadata.
-}
resolver : Plan res -> Http.Resolver Never ( Maybe Http.Metadata, Result Error res )
resolver p =
    case p of
        TextPlan t ->
            Http.stringResolver (\answer -> Ok ( Internal.metadataOf answer, Answer.textResult t.wire t.options t.route t.decoder answer ))

        BytesPlan b ->
            Http.bytesResolver (\answer -> Ok (Answer.bytesResult b.wire b.options b.endpoint b.decode answer))

        Unplannable invariant ->
            Http.stringResolver (\_ -> Ok ( Nothing, Err (Answer.unreachable invariant) ))


{-| A text answer read for a client speaking JSON.
-}
response : Plan res -> Http.Response String -> Result Error res
response p answer =
    case p of
        TextPlan t ->
            Answer.textResult t.wire t.options t.route t.decoder answer

        _ ->
            Err (Answer.unreachable "a text answer read for a protocol that is not speaking JSON")


{-| A bytes answer read for a client speaking protobuf binary.
-}
responseBytes : Plan res -> Http.Response Bytes -> Result Error res
responseBytes p answer =
    case p of
        BytesPlan b ->
            Tuple.second (Answer.bytesResult b.wire b.options b.endpoint b.decode answer)

        _ ->
            Err (Answer.unreachable "a bytes answer read for a protocol that is not speaking protobuf binary")


{-| The request an attempt sends with `left` milliseconds of a retry deadline
to go: `sent` with its timeout bounded by them, and the protocol's timeout
header saying so in place of any it had. A request whose timeout is already
within the budget, or sent without a deadline, is `sent` as it is.
-}
withBudget : Plan res -> Maybe Float -> Request -> Request
withBudget p left sent =
    let
        timeout =
            Wire.usableTimeout sent.timeout
    in
    case Retry.attemptTimeout left timeout of
        Just ms ->
            if timeout == Just ms then
                sent

            else
                { sent
                    | timeout = Just ms
                    , headers =
                        case timeoutHeader p of
                            Just ( name, format ) ->
                                List.filter (\( key, _ ) -> String.toLower key /= String.toLower name) sent.headers
                                    ++ [ ( name, format ms ) ]

                            Nothing ->
                                sent.headers
                }

        Nothing ->
            sent


timeoutHeader : Plan res -> Maybe ( String, Float -> String )
timeoutHeader p =
    case p of
        TextPlan t ->
            t.wire.timeoutHeader t.route

        BytesPlan b ->
            b.wire.timeoutHeader

        Unplannable _ ->
            Nothing


{-| The binding a call went over, for a trace: its number when the protocol
took one of its method's routes.
-}
binding : Plan res -> Maybe Int
binding p =
    case p of
        TextPlan t ->
            t.binding

        _ ->
            Nothing


{-| A request's binary body as base64, for a trace, written by the protocol's
own encoder so that a program speaking JSON carries none.
-}
requestBase64 : Plan res -> Request -> Maybe String
requestBase64 p sent =
    case p of
        BytesPlan b ->
            Maybe.map b.wire.base64 (Rpc.Body.toBytes sent.body)

        _ ->
            Nothing
