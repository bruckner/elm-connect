module Rpc.Internal.Wire exposing (Settings, invalidPathValue, missingCodec, request, requestBytes, requestTooLarge, withBudget)

{-| The request each transport sends for a call: Connect's POST, or its GET of
a method without side effects, and transcoding's request over a binding,
with the headers, timeout and credentials the config and the call give.
Not exposed; it is what `Rpc.request` stands for, kept out of `Rpc` so that
the public module reads as API. It takes the config as the fields it reads,
since `Rpc`, which defines `Config`, imports it.
-}

import Bytes exposing (Bytes)
import Json.Encode
import Proto.Binary
import Proto.Bytes
import Proto.Internal.Binding exposing (Rule)
import Proto.Method as Method exposing (Idempotency(..))
import Rpc.Body as Body
import Rpc.Call
import Rpc.Error as Error
import Rpc.Internal.Call exposing (Call(..))
import Rpc.Internal.Http as Internal
import Rpc.Internal.Retry as Retry
import Rpc.Internal.Route as Route exposing (Route(..), route)
import Rpc.Internal.Transport as Transport exposing (Transport(..))
import Rpc.Request exposing (Request)


{-| The fields of an `Rpc.Config` a request is built from.
-}
type alias Settings c =
    { c
        | transport : Transport
        , baseUrl : String
        , headers : List ( String, String )
        , timeout : Maybe Float
        , withCredentials : Bool
    }


{-| The request a call sends over the settings' transport.
-}
request : Settings c -> Call req res -> Request
request cfg c =
    case cfg.transport of
        Connect options ->
            connectRequest options (connectMessage options c) cfg c

        Transcode _ ->
            case route cfg.transport c of
                Bound _ rule ->
                    transcodeRequest rule cfg c

                Implicit ->
                    connectRequest { get = False, maxGetUrl = Nothing } (jsonMessage c) cfg c


{-| A request message as Connect sends it: its body as a POST, and as a GET
the query parameters before `message` (`encoding`, and `base64` for binary)
and `message`'s value.
-}
type alias ConnectMessage =
    { body : Body.Body, encoding : String, query : String }


jsonMessage : Call req res -> ConnectMessage
jsonMessage c =
    let
        json =
            Json.Encode.encode 0 (Rpc.Call.requestJson c)
    in
    { body = Body.text json
    , encoding = "encoding=json"
    , query = Internal.percentEncode Internal.unreserved json
    }


{-| The message as the transport's codec writes it: protobuf binary under the
proto codec when the method has a binary encoder, else JSON (a method without
one is refused before it is sent).
-}
connectMessage : { o | proto : Bool } -> Call req res -> ConnectMessage
connectMessage options c =
    case ( options.proto, requestBytes c ) of
        ( True, Just binary ) ->
            { body = Body.bytes binary
            , encoding = "base64=1&encoding=proto"
            , query = base64Url (Proto.Bytes.toBase64 binary)
            }

        _ ->
            jsonMessage c


{-| The call's request as protobuf binary, when its method has a binary
encoder.
-}
requestBytes : Call req res -> Maybe Bytes
requestBytes (Call fields) =
    Method.encodeRequestBytes fields.method
        |> Maybe.map (\encode -> Proto.Binary.encode encode fields.message)


{-| Base64 in the URL-safe alphabet without padding, as Connect's GET takes
binary.
-}
base64Url : String -> String
base64Url =
    String.foldr
        (\char done ->
            case char of
                '+' ->
                    String.cons '-' done

                '/' ->
                    String.cons '_' done

                '=' ->
                    done

                _ ->
                    String.cons char done
        )
        ""


connectRequest : { o | get : Bool, maxGetUrl : Maybe Int } -> ConnectMessage -> Settings c -> Call req res -> Request
connectRequest options message cfg ((Call fields) as c) =
    let
        url =
            Route.connectUrl cfg.baseUrl c

        timeout =
            callTimeout cfg c

        timeoutHeader =
            case timeout of
                Just ms ->
                    [ ( "Connect-Timeout-Ms", timeoutMs ms ) ]

                Nothing ->
                    []

        -- The query parameters in the order the protocol recommends, so a
        -- cache keys one request one way.
        getUrl =
            url
                ++ "?connect=v1&"
                ++ message.encoding
                ++ "&message="
                ++ message.query

        fits =
            case options.maxGetUrl of
                Just limit ->
                    String.length getUrl <= limit

                Nothing ->
                    True
    in
    if options.get && Method.idempotency (Method.toDescriptor fields.method) == IdempotencyNoSideEffects && fits then
        { method = "GET"
        , url = getUrl
        , headers = cfg.headers ++ fields.headers ++ timeoutHeader
        , body = Body.none
        , timeout = timeout
        , withCredentials = cfg.withCredentials
        }

    else
        { method = "POST"
        , url = url
        , headers = cfg.headers ++ fields.headers ++ ( "Connect-Protocol-Version", "1" ) :: timeoutHeader
        , body = message.body
        , timeout = timeout
        , withCredentials = cfg.withCredentials
        }


{-| The request over one binding of a method's rule.
-}
transcodeRequest : Rule -> Settings c -> Call req res -> Request
transcodeRequest rule cfg ((Call fields) as c) =
    let
        json =
            Rpc.Call.requestJson c
    in
    { method = rule.method
    , url = Route.transcodeUrl cfg.baseUrl rule json
    , headers = cfg.headers ++ fields.headers
    , body = Route.bindingBody rule json
    , timeout = callTimeout cfg c
    , withCredentials = cfg.withCredentials
    }


{-| The first path variable of the call's binding whose value its template
cannot match, read from the call's request; `Nothing` over Connect and the
implicit route, which have no path variables.
-}
invalidPathValue : Settings c -> Call req res -> Maybe { field : String, template : String }
invalidPathValue cfg c =
    case route cfg.transport c of
        Bound _ rule ->
            Route.invalidPathValue rule (Rpc.Call.requestJson c)

        Implicit ->
            Nothing


{-| The request an attempt sends with `left` milliseconds of a retry deadline
to go (`Rpc.Internal.Retry.budget`): `sent` with
its timeout bounded by them, and over Connect a `Connect-Timeout-Ms` that
says so in place of any it had. A request whose timeout is already within
the budget, or sent without a deadline, is `sent` as it is.
-}
withBudget : Settings c -> Call req res -> Maybe Float -> Request -> Request
withBudget cfg c left sent =
    let
        timeout =
            usableTimeout sent.timeout
    in
    case Retry.attemptTimeout left timeout of
        Just ms ->
            if timeout == Just ms then
                sent

            else
                { sent
                    | timeout = Just ms
                    , headers =
                        if speaksConnect cfg c then
                            List.filter (\( name, _ ) -> String.toLower name /= "connect-timeout-ms") sent.headers
                                ++ [ ( "Connect-Timeout-Ms", timeoutMs ms ) ]

                        else
                            sent.headers
                }

        Nothing ->
            sent


{-| Whether the call goes over the Connect protocol, which carries its
timeout in a header: over Connect, and over transcoding by the implicit
route of a method without a rule.
-}
speaksConnect : Settings c -> Call req res -> Bool
speaksConnect cfg c =
    case cfg.transport of
        Connect _ ->
            True

        Transcode _ ->
            case route cfg.transport c of
                Bound _ _ ->
                    False

                Implicit ->
                    True


callTimeout : Settings c -> Call req res -> Maybe Float
callTimeout cfg (Call fields) =
    case usableTimeout fields.timeout of
        Just ms ->
            Just ms

        Nothing ->
            usableTimeout cfg.timeout


{-| A timeout only when it is a positive number of milliseconds. elm/http hands
the value to XHR, whose unsigned conversion turns a negative one into weeks and
NaN or `0` into none, while the header would claim 1 ms or the maximum; read as
no timeout instead, the header and the client agree.
-}
usableTimeout : Maybe Float -> Maybe Float
usableTimeout timeout =
    case timeout of
        Just ms ->
            if ms > 0 && not (isInfinite ms) then
                Just ms

            else
                Nothing

        Nothing ->
            Nothing


{-| A positive whole number of milliseconds, at most ten digits, as the
protocol requires.
-}
timeoutMs : Float -> String
timeoutMs ms =
    String.fromInt (clamp 1 9999999999 (ceiling ms))


{-| Why a call cannot be written in the transport's codec: its method has no
binary codecs and the transport sends protobuf binary, or binary codecs alone
and the transport sends JSON.
-}
missingCodec : Settings c -> Call req res -> Maybe Error.Reason
missingCodec cfg (Call fields) =
    let
        missing codecName =
            Just
                (Error.MissingCodec
                    { method = Method.service (Method.toDescriptor fields.method) ++ "/" ++ Method.name (Method.toDescriptor fields.method)
                    , codec = codecName
                    }
                )
    in
    if Transport.proto cfg.transport then
        case Method.encodeRequestBytes fields.method of
            Just _ ->
                Nothing

            Nothing ->
                missing "proto"

    else if Method.hasJson fields.method then
        Nothing

    else
        missing "json"


{-| Why a call's request message is too long to send over the transport: its
JSON, or its protobuf binary under the proto codec, is over the write limit.
The binary is encoded only when there is a limit to measure it against.
-}
requestTooLarge : Settings c -> Call req res -> Maybe Error.Reason
requestTooLarge cfg c =
    if Transport.proto cfg.transport then
        Transport.writeMaxBytes cfg.transport
            |> Maybe.andThen (\_ -> requestBytes c)
            |> Maybe.andThen (\binary -> Internal.requestTooLarge cfg.transport (Err binary))

    else
        Internal.requestTooLarge cfg.transport (Ok (Json.Encode.encode 0 (Rpc.Call.requestJson c)))
