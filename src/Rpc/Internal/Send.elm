module Rpc.Internal.Send exposing (Plan, Reader(..), plan, refused, withBudget)

{-| How a call goes over a client's protocol: the one place a call's method
meets the protocol's functions. Not exposed; `Rpc` sends through it.

A call's [`plan`](#plan) is what the protocol's kind of wire, text or bytes,
makes of the method's codecs: monomorphic from there on, so the rest of
sending is ordinary functions over it. The only branches every program
carries are that two-way choice here and the choice of elm/http's reader of
text or of bytes where the answer is read.

The codec phantom keeps a protocol from meeting a method without the codec
it speaks, so the half a wire reads is always there. The representation
still allows a method value whose half is `Nothing`; no program can build
that pairing, so its plan fails with an internal error naming the
invariant, never a public reason.

-}

import Bytes exposing (Bytes)
import Http
import Json.Decode
import Json.Encode exposing (Value)
import Proto.Internal.Method exposing (Method(..))
import Proto.Route exposing (PathError)
import Rpc.Body
import Rpc.Error as Error exposing (Error, Reason)
import Rpc.Internal.Answer as Answer
import Rpc.Internal.Call exposing (Call(..))
import Rpc.Internal.Client exposing (Client(..))
import Rpc.Internal.Http as Internal
import Rpc.Internal.Protocol exposing (Protocol(..), Wire(..))
import Rpc.Internal.Retry as Retry
import Rpc.Internal.Wire as Wire
import Rpc.Request exposing (Request)


{-| A call over a protocol:

  - `request`: the request it sends, built when asked for.
  - `invalid`: the first path value its route's template cannot match.
  - `tooLarge`: whether its message is over the protocol's write limit,
    measured when asked for.
  - `reader`: how its answer is read, as text or as bytes.
  - `binding`: the binding it takes, when the protocol took one of its
    method's routes, for a trace.
  - `timeoutHeader`: the header the protocol carries its timeout in.
  - `base64`: the protocol's base64 writer, for a binary body in a trace.
  - `problem`: the internal error of a pairing the types rule out.

-}
type alias Plan res =
    { request : () -> Request
    , invalid : Maybe PathError
    , tooLarge : () -> Maybe Reason
    , reader : Reader res
    , binding : Maybe Int
    , timeoutHeader : Maybe ( String, Float -> String )
    , base64 : Maybe (Bytes -> String)
    , problem : Maybe Error
    }


{-| An answer's reading: of text, or of bytes with its metadata.
-}
type Reader res
    = TextReader (Http.Response String -> Result Error res)
    | BytesReader (Http.Response Bytes -> ( Maybe Http.Metadata, Result Error res ))


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

                        json () =
                            half.encode c.message
                    in
                    { request = \() -> wire.build p.options settings m.endpoint route (json ())
                    , invalid = Maybe.andThen .invalid route
                    , tooLarge = \() -> wire.tooLarge p.options (json ())
                    , reader =
                        TextReader
                            (\answer ->
                                wire.message wire.overRead p.options route answer
                                    |> Result.andThen
                                        (\read ->
                                            Json.Decode.decodeString (Answer.fieldDecoder read.field half.decoder) read.text
                                                |> Result.mapError (Json.Decode.errorToString >> read.bad)
                                        )
                            )
                    , binding = Maybe.map (\_ -> c.binding) route
                    , timeoutHeader = wire.timeoutHeader route
                    , base64 = Nothing
                    , problem = Nothing
                    }

                Nothing ->
                    unplannable "a protocol speaking JSON met a method without JSON codecs"

        Binary wire ->
            case m.binary of
                Just half ->
                    let
                        binary () =
                            half.encode c.message
                    in
                    { request = \() -> wire.build wire.base64 p.options settings m.endpoint (binary ())
                    , invalid = Nothing
                    , tooLarge = \() -> wire.tooLarge p.options (binary ())
                    , reader =
                        BytesReader
                            (\answer ->
                                let
                                    ( metadata, read ) =
                                        wire.message wire.overRead p.options m.endpoint answer
                                in
                                ( metadata
                                , Result.andThen
                                    (\message ->
                                        case half.decode message.bytes of
                                            Just value ->
                                                Ok value

                                            Nothing ->
                                                Err (message.bad ())
                                    )
                                    read
                                )
                            )
                    , binding = Nothing
                    , timeoutHeader = wire.timeoutHeader
                    , base64 = Just wire.base64
                    , problem = Nothing
                    }

                Nothing ->
                    unplannable "a protocol speaking protobuf binary met a method without binary codecs"


unplannable : String -> Plan res
unplannable invariant =
    let
        error =
            Answer.unreachable invariant
    in
    { request = \() -> { method = "POST", url = "", headers = [], body = Rpc.Body.none, timeout = Nothing, withCredentials = False }
    , invalid = Nothing
    , tooLarge = \() -> Nothing
    , reader = TextReader (\_ -> Err error)
    , binding = Nothing
    , timeoutHeader = Nothing
    , base64 = Nothing
    , problem = Just error
    }


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
        case ( p.problem, p.invalid, Internal.invalidHeader sent.headers ) of
            ( Just problem, _, _ ) ->
                Just problem

            ( Nothing, Just path, _ ) ->
                Just (Error.NoAnswer (Error.InvalidPathValue path))

            ( Nothing, Nothing, Just name ) ->
                Just (Error.NoAnswer (Error.InvalidHeader name))

            ( Nothing, Nothing, Nothing ) ->
                p.tooLarge () |> Maybe.map Error.NoAnswer


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
                        case p.timeoutHeader of
                            Just ( name, format ) ->
                                List.filter (\( key, _ ) -> String.toLower key /= String.toLower name) sent.headers
                                    ++ [ ( name, format ms ) ]

                            Nothing ->
                                sent.headers
                }

        Nothing ->
            sent
