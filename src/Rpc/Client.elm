module Rpc.Client exposing
    ( Client, client
    , withHeaders, withTimeout, withCredentials, withRetry
    , protocol, baseUrl, headers, timeout, credentials, retry
    , problems, toJson
    )

{-| Where and how to send calls: a [protocol](Rpc-Protocol), the server's
base URL, and the headers, timeout, credentials and retry policy every call
takes.

    client : Rpc.Client Rpc.Json
    client =
        Rpc.client Rpc.Protocol.connect "https://api.example.com"
            |> Rpc.Client.withTimeout 10000

A client holds its protocol's functions, so it belongs in code: a top-level
value, one built in `init`, or one a wrapper builds per call from the
application's state. Clients built alike are `==`; a client never belongs in
a message. [`toJson`](#toJson) gives it as data, for logs and tests.

@docs Client, client


# Options

@docs withHeaders, withTimeout, withCredentials, withRetry


# Reading

@docs protocol, baseUrl, headers, timeout, credentials, retry
@docs problems, toJson

-}

import Json.Encode exposing (Value)
import Rpc.Internal.Client as Internal
import Rpc.Internal.Http
import Rpc.Internal.Protocol as Protocol
import Rpc.Protocol exposing (Protocol)
import Rpc.Retry exposing (Retry)


{-| A client sending calls whose codec is `codec`. It is opaque: built by
[`client`](#client) and the functions below. The package site and compiler
errors may show it as `Rpc.Internal.Client.Client`, its name inside the
package.
-}
type alias Client codec =
    Internal.Client codec


{-| A client of a server over a protocol: no extra headers, no timeout, no
credentials cross-origin and no retries.

The base URL is the server with any routing prefix
(`https://api.example.com`, `/api`); a trailing `/` is dropped. A call's path
is appended to it, so it can hold no query or fragment: a call sent with one
holding `?` or `#` is not sent, and fails with `NoAnswer (BadUrl url)`.
[`problems`](#problems) finds that where the client is built.

-}
client : Protocol codec -> String -> Client codec
client over url =
    Internal.Client
        { protocol = over
        , baseUrl = url
        , headers = []
        , timeout = Nothing
        , withCredentials = False
        , retry = Nothing
        }


{-| Headers sent with every call, after any given before, such as
`( "Authorization", "Bearer …" )`. A name must be an HTTP token (letters,
digits and `` !#$%&'*+-.^_`|~ ``), and a value can hold no NUL, CR or LF
and no character above U+00FF, which a browser refuses. A call with such a
header is not sent, and fails with `NoAnswer (InvalidHeader name)`.
-}
withHeaders : List ( String, String ) -> Client codec -> Client codec
withHeaders extra (Internal.Client c) =
    Internal.Client { c | headers = c.headers ++ extra }


{-| A timeout for every call, in milliseconds; a call's own
([`Rpc.Call.withTimeout`](Rpc-Call#withTimeout)) takes its place. Connect and
gRPC-Web also tell the server. One that is not a positive number means none.
-}
withTimeout : Float -> Client codec -> Client codec
withTimeout ms (Internal.Client c) =
    Internal.Client { c | timeout = Just ms }


{-| Send cookies and other credentials cross-origin (`Http.riskyRequest`).
-}
withCredentials : Client codec -> Client codec
withCredentials (Internal.Client c) =
    Internal.Client { c | withCredentials = True }


{-| Try a failed call again as the policy says ([`Rpc.Retry`](Rpc-Retry)). A
call can take another policy ([`Rpc.Call.withRetry`](Rpc-Call#withRetry)) or
none ([`Rpc.Call.withoutRetry`](Rpc-Call#withoutRetry)) in its place.
-}
withRetry : Retry -> Client codec -> Client codec
withRetry policy (Internal.Client c) =
    Internal.Client { c | retry = Just policy }


{-| The client's protocol.
-}
protocol : Client codec -> Protocol codec
protocol (Internal.Client c) =
    c.protocol


{-| The client's base URL, as given.
-}
baseUrl : Client codec -> String
baseUrl (Internal.Client c) =
    c.baseUrl


{-| The client's headers, in order.
-}
headers : Client codec -> List ( String, String )
headers (Internal.Client c) =
    c.headers


{-| The client's timeout, as given.
-}
timeout : Client codec -> Maybe Float
timeout (Internal.Client c) =
    c.timeout


{-| Whether credentials go cross-origin.
-}
credentials : Client codec -> Bool
credentials (Internal.Client c) =
    c.withCredentials


{-| The client's retry policy.
-}
retry : Client codec -> Maybe Retry
retry (Internal.Client c) =
    c.retry


{-| What is wrong with a client, one sentence each, or `[]` when nothing is:
the problems sending would otherwise find one call at a time. It finds a base
URL holding a query or a fragment, headers a request cannot carry, each by
its name (a value is left out, since it may be a credential), and a read or
write limit below 1. Later releases may find more, so the result is read as
a list rather than matched.
-}
problems : Client codec -> List String
problems (Internal.Client c) =
    let
        (Protocol.Protocol p) =
            c.protocol
    in
    (if Rpc.Internal.Http.badBaseUrl c.baseUrl then
        [ "baseUrl " ++ c.baseUrl ++ " holds a query or a fragment (? or #), after which a call's path cannot go" ]

     else
        []
    )
        ++ List.filterMap
            (\( name, value ) ->
                if not (Rpc.Internal.Http.validHeaderName name) then
                    Just ("header " ++ quote name ++ " has a name that is not an HTTP token")

                else if not (Rpc.Internal.Http.validHeaderValue value) then
                    Just ("header " ++ quote name ++ " has a value a request cannot carry (NUL, CR, LF or a character above U+00FF)")

                else
                    Nothing
            )
            c.headers
        ++ belowOne "readMaxBytes" "every response with a body is refused" p.options.readMaxBytes
        ++ belowOne "writeMaxBytes" "every call is refused unsent" p.options.writeMaxBytes


belowOne : String -> String -> Maybe Int -> List String
belowOne knob consequence setting =
    case setting of
        Just limit ->
            if limit < 1 then
                [ knob ++ " " ++ String.fromInt limit ++ " is below 1, so " ++ consequence ]

            else
                []

        Nothing ->
            []


quote : String -> String
quote text =
    Json.Encode.encode 0 (Json.Encode.string text)


{-| The client as JSON, for logs and tests: its protocol
([`Rpc.Protocol.toJson`](Rpc-Protocol#toJson)), base URL, headers (values
included, as [`Rpc.Trace.toJson`](Rpc-Trace#toJson) gives them), timeout,
credentials and whether it has a retry policy.
-}
toJson : Client codec -> Value
toJson (Internal.Client c) =
    Json.Encode.object
        [ ( "protocol", Rpc.Protocol.toJson c.protocol )
        , ( "baseUrl", Json.Encode.string c.baseUrl )
        , ( "headers", Json.Encode.list (\( k, v ) -> Json.Encode.list Json.Encode.string [ k, v ]) c.headers )
        , ( "timeout", Maybe.map Json.Encode.float c.timeout |> Maybe.withDefault Json.Encode.null )
        , ( "withCredentials", Json.Encode.bool c.withCredentials )
        , ( "retry"
          , Json.Encode.bool
                (case c.retry of
                    Just _ ->
                        True

                    Nothing ->
                        False
                )
          )
        ]
