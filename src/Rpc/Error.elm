module Rpc.Error exposing
    ( Error
    , code, message, details, source, Source(..)
    , httpStatus, response
    , cause, Cause(..)
    , toString
    , fromCode, fromResponse, timeout, networkError, badCall, badResponse, withMessage, withDetails
    )

{-| Why a call failed: what [`Rpc.task`](Rpc#task), [`Rpc.send`](Rpc#send) and
the other ways of sending give in place of the response.

Read an error in the terms your application already thinks in. An
application calling an RPC API, over Connect or gRPC-Web, reads its
[`code`](#code), [`message`](#message) and [`details`](#details):

    case Rpc.Error.code error of
        Rpc.Code.Unauthenticated ->
            signInAgain

        _ ->
            showMessage (Rpc.Error.message error)

An application calling a REST API, over transcoding, reads its
[`httpStatus`](#httpStatus) and [`response`](#response):

    case Rpc.Error.httpStatus error of
        Just 401 ->
            signInAgain

        _ ->
            showMessage (Rpc.Error.message error)

Each view is complete on its own: every error has a code and a message, and
every error that came with an answer has its HTTP status and the answer.

When it matters who produced the error, the server or this client, read its
[`cause`](#cause). The client gives its own failures codes too, and those
codes also have server meanings: an oversized request is
`ResourceExhausted`, as a server's quota is, and a network failure
`Unavailable`, as a server shedding load is. Code that acts on what the
server said checks that the cause is `Nothing`.

@docs Error


# The RPC view

@docs code, message, details, source, Source


# The HTTP view

@docs httpStatus, response


# Who produced it

@docs cause, Cause


# For logs

@docs toString


# Building errors

For tests and previews. Every error built here has a cause or a response, or
both, as every error the runtime gives does.

@docs fromCode, fromResponse, timeout, networkError, badCall, badResponse, withMessage, withDetails

-}

import Dict
import Json.Encode
import Proto.Any exposing (Any)
import Proto.Error
import Rpc.Body
import Rpc.Code as Code exposing (Code)
import Rpc.Internal.Error as Internal exposing (Fault(..))
import Rpc.Response exposing (Response)


{-| A failed call. Read it through the functions below; it has no
constructors to match on.

The package site and compiler errors may show it as
`Rpc.Internal.Error.Error`, its name inside the package; that module is not
exposed.

-}
type alias Error =
    Internal.Error



-- THE RPC VIEW


{-| An error's code, as the Connect clients give it.

When the server stated a status, it is the server's. When the server
answered with a failure and stated none, it is inferred from the HTTP status
by [`Rpc.Code.fromHttpStatus`](Rpc-Code#fromHttpStatus), so a 200 that is not
the protocol's answer is `Unknown`, and a 404 is `Unimplemented`, not
`NotFound`. That is right for Connect, whose servers send a status with every
error; a REST server should send a `google.rpc.Status` body
(`{"code": 5, "message": …}`) so the code reads as `NotFound`.

When the client produced the error ([`cause`](#cause)), it is the client's:
a timeout is `DeadlineExceeded`, a network failure `Unavailable`; a call that
could not be made is `Internal` (a bad URL, header or `Any`),
`InvalidArgument` (a path value its template cannot match) or
`ResourceExhausted` (a request over its limit); an answer that could not be
used is `Internal`, `ResourceExhausted` for one over its limit, and
`Unimplemented` for a unary gRPC-Web answer that carried no message or more
than one.

-}
code : Error -> Code
code (Internal.Error e) =
    e.code


{-| An error's message:

  - When the server stated a status, the server's, which may be empty.
  - When the server answered with a failure and stated none, the status
    text, or `HTTP <status>` when there is none.
  - When the client produced it, what went wrong: `timeout`, `network
    error`, `bad URL: <url>`, `invalid header "<name>"`, `path field
    "<field>" does not match <template>`, `bad Any: <problem>`,
    `bad response body: <problem>`, `bad response: <problem>`, or, as
    connect-es words them,
    `message size <size> is larger than configured writeMaxBytes <limit>`
    for a request and `… readMaxBytes <limit>` for a response, both in
    bytes. A bad URL is printed as its scheme, host and path, without the
    user and password a URL can hold, and without its query and fragment,
    which over Connect's GET hold the request:
    `bad URL: https://api.example.com/base (query omitted)`. A bad header
    is named, its value left out, since it may be a credential; a bad path
    value is left out too. A body's problem is described by
    [`Proto.Error.toString`](Proto-Error#toString); elm/json's quotes the
    JSON it rejected, which can be the whole response and hold data the
    application never shows, so the message keeps its first 300
    characters, then `…`.

-}
message : Error -> String
message (Internal.Error e) =
    case e.fault of
        Said text ->
            text

        BadUrl url ->
            "bad URL: " ++ printableUrl url

        BadHeader name ->
            "invalid header " ++ Json.Encode.encode 0 (Json.Encode.string name)

        BadPathValue { field, template } ->
            "path field " ++ Json.Encode.encode 0 (Json.Encode.string field) ++ " does not match " ++ template

        RequestTooLarge { limit, size } ->
            "message size " ++ String.fromInt size ++ " is larger than configured writeMaxBytes " ++ String.fromInt limit

        ResponseTooLarge { limit, size } ->
            "message size " ++ String.fromInt size ++ " is larger than configured readMaxBytes " ++ String.fromInt limit

        BadAny problem ->
            "bad Any: " ++ Proto.Error.toString problem

        BadBody problem ->
            "bad response body: " ++ excerpt (Proto.Error.toString problem)

        BadEnvelope problem ->
            "bad response: " ++ excerpt problem


{-| The details of a status the server stated, `[]` for any other error.

Each detail is a message packed in an [`Any`](Proto-Any#Any), in the order
the server sent them, or the [`Proto.Error`](Proto-Error#Error) that kept one
from being read; a problem with a detail never loses the error's code,
message and source:

  - `UnregisteredType`: it arrived as proto3 JSON (a `google.rpc.Status`
    body) whose type, its URL here, the client's registry has no entry for.
    Register the type ([`Rpc.Client.withRegistry`](Rpc-Client#withRegistry)); for
    `google.rpc` details such as `ErrorInfo` or `BadRequest`, that is
    [`Proto.ErrorDetails.registry`](Proto-ErrorDetails#registry). A
    [lenient](Proto-Registry#lenient) registry reads it instead, as its
    JSON alone.
  - `BadJson`: it is not a detail of its form: a Connect detail with no
    `type`, or whose `value` is not base64; proto3 JSON with no `"@type"`,
    or that is not the message its `"@type"` names. elm/json's error holds
    the detail and what was wrong, for a log.
  - `BadBinary`: over gRPC-Web, a `grpc-status-details-bin` that does not
    decode as a `google.rpc.Status`, which then stands for all of them.

Nothing in the program fixes a `BadJson` or a `BadBinary`; report it as
the server's. Unpack one with
[`Proto.Any.tryUnpack`](Proto-Any#tryUnpack):

    Rpc.Error.details error
        |> List.filterMap Result.toMaybe
        |> List.filterMap (Proto.Any.unpack Proto.ErrorDetails.badRequest)

A Connect error body and gRPC-Web carry a detail's protobuf binary, which
needs no registry. A `google.rpc.Status` body (transcoding) carries proto3
JSON, which is read through the client's registry
([`Rpc.Client.withRegistry`](Rpc-Client#withRegistry)). Details a proxy stripped are
simply absent, `[]`.

-}
details : Error -> List (Result Proto.Error.Error Any)
details (Internal.Error e) =
    e.details


{-| Where the server stated the error's status, or `Nothing` when it stated
none: a failure answer without one, or an error the client produced.
-}
source : Error -> Maybe Source
source (Internal.Error e) =
    Maybe.map publicSource e.source


publicSource : Internal.Source -> Source
publicSource found =
    case found of
        Internal.ConnectBody ->
            ConnectBody

        Internal.StatusBody ->
            StatusBody

        Internal.GrpcHeaders ->
            GrpcHeaders

        Internal.GrpcTrailers ->
            GrpcTrailers

        Internal.ConnectEndStream ->
            ConnectEndStream


{-| Where a status was read from, tried in this order:

  - `ConnectBody`: a Connect error body, `{"code": "not_found", …}`.
  - `StatusBody`: a `google.rpc.Status` body, `{"code": 5, …}`, as grpc-gateway
    and Envoy send; a number outside `1` to `16` is the code `Unknown`.
  - `GrpcHeaders`: the `grpc-status` and `grpc-message` headers, when the
    browser exposes them; the message is percent-decoded, and the status text
    stands in when there is none. A gRPC-Web answer without a body
    ("trailers-only") states its status so, with its details in
    `grpc-status-details-bin`.
  - `GrpcTrailers`: the `grpc-status`, `grpc-message` and
    `grpc-status-details-bin` trailers that end a gRPC-Web answer's body.
    Either way, when `grpc-status-details-bin` holds a `google.rpc.Status`
    with a code, its code and message are the error's, as connect-go and
    connect-es read them, and its details are the error's details.

One more is reserved for streaming calls, which this release does not make,
so it never gives it; a `case` on a `Source` covers it all the same:

  - `ConnectEndStream`: the error in the end-of-stream message of a Connect
    stream.

-}
type Source
    = ConnectBody
    | StatusBody
    | GrpcHeaders
    | GrpcTrailers
    | ConnectEndStream



-- THE HTTP VIEW


{-| The HTTP status of the answer the error came with, or `Nothing` when none
came: a timeout, a network failure, or a call that could not be made
([`cause`](#cause)). It is always the status the server sent.

A 200 is a failure too when its body could not be used, or when it is not
the protocol's answer at all, such as a proxy's HTML page in place of a
Connect or gRPC-Web answer. Over transcoding, any success is read as the
answer.

-}
httpStatus : Error -> Maybe Int
httpStatus (Internal.Error e) =
    Maybe.map .statusCode e.response


{-| The answer the error came with, its URL, status, status text, headers and
body, or `Nothing` when none came, so a failure in a shape the runtime does
not read, or a body that drifted from the schema, can still be read:

    case Rpc.Error.response error of
        Just answer ->
            Rpc.Body.toText answer.body
                |> Maybe.withDefault ""
                |> myDecoder

        Nothing ->
            Err (Rpc.Error.toString error)

An answer over the protocol's read limit
([`withReadMaxBytes`](Rpc-Protocol#withReadMaxBytes)) is kept without its
body, which was dropped unread.

-}
response : Error -> Maybe Response
response (Internal.Error e) =
    e.response



-- WHO PRODUCED IT


{-| Why the client produced the error, or `Nothing` when the server answered
with a failure (connect-go's `IsWireError`).

Check it when it matters who produced the error. The client's codes share
meanings with the server's: `ResourceExhausted` is a request over the
client's limit as well as a server's quota, and `Unavailable` a network
failure as well as a server shedding load.

    case ( Rpc.Error.cause error, Rpc.Error.code error ) of
        ( Nothing, Rpc.Code.ResourceExhausted ) ->
            showMessage "Slow down and try again in a minute."

        _ ->
            showMessage (Rpc.Error.message error)

-}
cause : Error -> Maybe Cause
cause (Internal.Error e) =
    Maybe.map publicCause e.cause


publicCause : Internal.Cause -> Cause
publicCause found =
    case found of
        Internal.BadCall ->
            BadCall

        Internal.NetworkError ->
            NetworkError

        Internal.Timeout ->
            Timeout

        Internal.BadResponse ->
            BadResponse


{-| Why the client produced an error:

  - `BadCall`: the call could not be made, and nothing was sent: a URL that
    cannot be sent to (a `baseUrl` holding `?` or `#`, or one the browser
    refuses), a header a request cannot carry, a path value its template
    cannot match, a request over the protocol's write limit
    ([`withWriteMaxBytes`](Rpc-Protocol#withWriteMaxBytes)), or an
    [`Any`](Proto-Any) the client's registry cannot write as JSON
    ([`Rpc.Client.withRegistry`](Rpc-Client#withRegistry)). The
    [`message`](#message) says which.
  - `NetworkError`: the request failed on the way, as when the server is
    unreachable or a browser's CORS check refused the answer.
  - `Timeout`: the call's timeout passed first.
  - `BadResponse`: an answer came and could not be used: its body is not the
    response message, its content type, framing or status is malformed, or
    it is over the protocol's read limit
    ([`withReadMaxBytes`](Rpc-Protocol#withReadMaxBytes)). It keeps the
    answer ([`response`](#response)).

A `BadCall` or a `BadResponse` is never retried
([`Rpc.Retry`](Rpc-Retry)): trying again cannot change it.

-}
type Cause
    = BadCall
    | NetworkError
    | Timeout
    | BadResponse



-- FOR LOGS


{-| A one-line description of an error, for logs: its [`code`](#code) and
[`message`](#message), `not_found: no such note`, or the code alone when the
message is empty.
-}
toString : Error -> String
toString error =
    let
        text =
            message error
    in
    Code.toString (code error)
        ++ (if String.isEmpty text then
                ""

            else
                ": " ++ text
           )



-- BUILDING ERRORS


{-| A failure whose status the server stated, with this code and an empty
message. Its response is the one a Connect server would send: the code's HTTP
status ([`Rpc.Code.toHttpStatus`](Rpc-Code#toHttpStatus)), and an empty body.

    Rpc.Error.fromCode Rpc.Code.NotFound
        |> Rpc.Error.withMessage "no such note"

-}
fromCode : Code -> Error
fromCode c =
    Internal.stated
        { code = c, message = "", details = [], source = Internal.ConnectBody }
        { url = ""
        , statusCode = Code.toHttpStatus c
        , statusText = ""
        , headers = Dict.empty
        , body = Rpc.Body.none
        }


{-| A failure answer that states no status: its code is inferred from the
HTTP status, its message is the status text.
-}
fromResponse : Response -> Error
fromResponse =
    Internal.unstated


{-| The call's timeout passed first.
-}
timeout : Error
timeout =
    Internal.timeout


{-| The request failed on the way.
-}
networkError : Error
networkError =
    Internal.networkError


{-| A call that could not be made, with its code and message.
-}
badCall : Code -> String -> Error
badCall c text =
    Internal.Error
        { code = c
        , cause = Just Internal.BadCall
        , source = Nothing
        , details = []
        , response = Nothing
        , fault = Said text
        }


{-| An answer that could not be used, with its code, its message and the
answer.
-}
badResponse : Code -> String -> Response -> Error
badResponse c text answer =
    Internal.Error
        { code = c
        , cause = Just Internal.BadResponse
        , source = Nothing
        , details = []
        , response = Just answer
        , fault = Said text
        }


{-| An error with this message in place of its own.
-}
withMessage : String -> Error -> Error
withMessage text (Internal.Error e) =
    Internal.Error { e | fault = Said text }


{-| An error with these details in place of its own.
-}
withDetails : List Any -> Error -> Error
withDetails found (Internal.Error e) =
    Internal.Error { e | details = List.map Ok found }



-- MESSAGES


{-| The first 300 characters of a text, and `…` when there were more.
-}
excerpt : String -> String
excerpt text =
    if String.length text > 300 then
        String.left 300 text ++ "…"

    else
        text


{-| A URL without its user information, query and fragment, saying so when a
query or fragment was left out.
-}
printableUrl : String -> String
printableUrl url =
    let
        beforeQuery =
            case String.indexes "?" url ++ String.indexes "#" url |> List.minimum of
                Just at ->
                    String.left at url

                Nothing ->
                    url

        omitted =
            if String.length beforeQuery < String.length url then
                " (query omitted)"

            else
                ""
    in
    withoutUserInfo beforeQuery ++ omitted


{-| A URL (without query or fragment) without the `user:password@` its
authority can begin with.
-}
withoutUserInfo : String -> String
withoutUserInfo url =
    case String.indexes "://" url of
        start :: _ ->
            let
                scheme =
                    String.left (start + 3) url

                rest =
                    String.dropLeft (start + 3) url

                authorityEnd =
                    String.indexes "/" rest |> List.head |> Maybe.withDefault (String.length rest)

                authority =
                    String.left authorityEnd rest
            in
            case List.reverse (String.indexes "@" authority) of
                at :: _ ->
                    scheme ++ String.dropLeft (at + 1) rest

                [] ->
                    url

        [] ->
            url
