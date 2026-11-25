module Rpc.Error exposing
    ( Error
    , code, message, details, source, Source(..)
    , cause, Cause(..), httpStatus
    , protoError
    , toString
    , fromStatus, fromCode, fromResponse, timeout, networkError, badCall, badAny, badValue, badResponse, badBody, withMessage
    )

{-| Why a call failed: what [`Rpc.task`](Rpc#task), [`Rpc.send`](Rpc#send) and
the other ways of sending give in place of the response.

An error reads in three layers, and an application reads the one it thinks
in. On top is the RPC: every error has a [`code`](#code) and a
[`message`](#message), the server's when it stated a status, and its
[`details`](#details):

    case Rpc.Error.code error of
        Rpc.Code.Unauthenticated ->
            signInAgain

        _ ->
            showMessage (Rpc.Error.message error)

Underneath is the HTTP exchange the RPC went over: its [`cause`](#cause),
elm/http's error with the answer kept, for an application that thinks in
HTTP statuses, as one calling a REST API over transcoding may:

    case Rpc.Error.cause error of
        Rpc.Error.BadStatus answer ->
            if answer.statusCode == 401 then
                signInAgain

            else
                showMessage (Rpc.Error.message error)

        _ ->
            showMessage (Rpc.Error.message error)

Underneath that is the codec: for a body that did not decode, or a request
that could not be written as JSON, [`protoError`](#protoError) holds the
problem itself.

@docs Error


# The RPC

@docs code, message, details, source, Source


# The HTTP exchange

@docs cause, Cause, httpStatus


# The codec

@docs protoError


# For logs

@docs toString


# Building errors

The runtime builds its errors with these same functions, so an error built
here and one the runtime gives are `==` when they state the same things.
They serve tests and previews, and application code too: an application
that fails a call itself before sending, such as an auth layer that will not
send without a session, builds a [`badCall`](#badCall) with the code it means.

    Rpc.Error.badCall Rpc.Code.Unauthenticated "not signed in"

Nothing was sent, and such an error is never retried.

@docs fromStatus, fromCode, fromResponse, timeout, networkError, badCall, badAny, badValue, badResponse, badBody, withMessage

-}

import Dict
import Proto.Any exposing (Any)
import Proto.Error
import Rpc.Body
import Rpc.Code as Code exposing (Code)
import Rpc.Response exposing (Response)


{-| A failed call. Read it through the functions below; it has no
constructors to match on.
-}
type Error
    = Error
        { code : Code
        , message : String
        , details : List (Result Proto.Error.Error Any)
        , source : Maybe Source
        , cause : Cause
        , protoProblem : Maybe Proto.Error.Error
        }



-- THE RPC


{-| An error's code, as the Connect clients give it.

When the server stated a status ([`source`](#source) is not `Nothing`), the
code is the server's. When it answered with a failure and stated none, the
code is inferred from the HTTP status by
[`Rpc.Code.fromHttpStatus`](Rpc-Code#fromHttpStatus): a 404 is
`Unimplemented`, not `NotFound`.

Otherwise the client produced the code itself: a timeout is
`DeadlineExceeded`; a network failure `Unavailable`; a call that could not be
made `Internal`, `InvalidArgument` for a path value its template cannot match
or a request value with no JSON form, or `ResourceExhausted` for a request over its limit; an answer that could not
be used `Internal`, `ResourceExhausted` for one over its limit,
`Unimplemented` for a unary gRPC-Web answer that carried no message or more
than one, and `Unknown` for a success that is not the protocol's answer at
all.

Those codes have server meanings too, and so do the inferred ones (an edge's
bare 429 reads as `Unavailable`). Code that acts on a code the server stated
checks that it stated one:

    Rpc.Error.source error
        /= Nothing
        && Rpc.Error.code error
        == Rpc.Code.ResourceExhausted

-}
code : Error -> Code
code (Error e) =
    e.code


{-| An error's message. Every message is safe to log or show: none holds a
value from the request or the answer beyond what the server stated as its
message.

  - When the server stated a status, the server's, which may be empty.
  - When the server answered with a failure and stated none, the status
    text, or `HTTP <status>` when there is none.
  - Otherwise what went wrong: `timeout`, `network error`,
    `bad URL: the base URL holds a query or a fragment`,
    `bad URL: the browser could not read it`, `invalid header "<name>"` (its
    value left out, since it may be a credential), `path field "<field>"
    does not match <template>`, `bad Any`, `bad response body`,
    `bad response: <what was malformed>`, or, as connect-es words them,
    `message size <size> is larger than configured writeMaxBytes <limit>`
    and `… readMaxBytes <limit>`, in bytes.

For a body that did not decode or an `Any` that could not be written,
[`protoError`](#protoError) holds the problem.

-}
message : Error -> String
message (Error e) =
    e.message


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
    or that is not the message its `"@type"` names.
  - `BadBinary`: over gRPC-Web, a `grpc-status-details-bin` that does not
    decode as a `google.rpc.Status`, which then stands for all of them.

Unpack one with [`Proto.Any.unpack`](Proto-Any#unpack):

    Rpc.Error.details error
        |> List.filterMap Result.toMaybe
        |> List.filterMap (Proto.Any.unpack Proto.ErrorDetails.badRequest)

A Connect error body and gRPC-Web carry a detail's protobuf binary, which
needs no registry. A `google.rpc.Status` body (transcoding) carries proto3
JSON, which is read through the client's registry. Details a proxy stripped
are simply absent, `[]`.

-}
details : Error -> List (Result Proto.Error.Error Any)
details (Error e) =
    e.details


{-| Where the server stated the error's status, or `Nothing` when no status
was stated: a failure answer without one, or an error the client produced.
-}
source : Error -> Maybe Source
source (Error e) =
    e.source


{-| Where a status was read from, tried in this order:

  - `ConnectBody`: a Connect error body, `{"code": "not_found", …}`. A code
    the protocol does not name, `"ok"` included, and a missing or `null`
    code beside a string `message` (`{"message": "…"}`) take the code
    [`Rpc.Code.fromHttpStatus`](Rpc-Code#fromHttpStatus) gives the answer's
    status, as the protocol tells a client to infer one, the message and
    details kept. Without a string `message`, a body with no code (`{}`) is
    not a Connect body.
  - `StatusBody`: a `google.rpc.Status` body, `{"code": 5, …}`, as grpc-gateway
    and Envoy send; a number outside `1` to `16` is the code `Unknown`, and the
    number as sent is in the answer's body.
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

The constructors are fixed.

-}
type Source
    = ConnectBody
    | StatusBody
    | GrpcHeaders
    | GrpcTrailers
    | ConnectEndStream



-- THE HTTP EXCHANGE


{-| What happened underneath, in the HTTP exchange.
-}
cause : Error -> Cause
cause (Error e) =
    e.cause


{-| What happened underneath, in the HTTP exchange: elm/http's error, with the
answer kept.

| elm/http | `Cause` |
|---|---|
| `BadUrl _` | `BadCall` |
| `Timeout` | `Timeout` |
| `NetworkError` | `NetworkError` |
| `BadStatus n` | `BadStatus answer`, `answer.statusCode == n`, which can be 200 (below) |
| `BadBody _` | `BadResponse answer` |

  - `BadCall`: the call could not be made, and nothing was sent. The runtime
    gives one for a base URL holding `?` or `#`, or a URL the browser
    refuses; a header a request cannot carry; a path value its template
    cannot match; a request over the protocol's write limit
    ([`withWriteMaxBytes`](Rpc-Protocol#withWriteMaxBytes)); over JSON, a
    request holding a value proto3 JSON has no form for, or an
    [`Any`](Proto-Any) the client's registry cannot write
    ([`Rpc.Client.withRegistry`](Rpc-Client#withRegistry)). An application
    that refuses to send a call builds one too ([`badCall`](#badCall)). The
    [`message`](#message) says which.
  - `NetworkError`: the request failed on the way, as when the server is
    unreachable or a browser's CORS check refused the answer.
  - `Timeout`: the call's timeout passed first.
  - `BadStatus`: the server answered with a failure, the answer here: a
    failure status, or a success whose answer states a failing RPC status
    (as gRPC-Web's trailers do). Over gRPC-Web a failure is stated in the
    trailers of a 200, so a reader that branches on `answer.statusCode`
    should not assume a failing status there; [`code`](#code) is the
    reading for it.
  - `BadResponse`: the server answered with success, always a 2xx, and the
    answer could not be used, the answer here: its body is not the response
    message, its content type, framing or status is malformed, it is not
    the protocol's answer at all (over Connect or gRPC-Web, a 200 of another
    content type, such as a proxy's HTML page), or it is over the protocol's
    read limit ([`withReadMaxBytes`](Rpc-Protocol#withReadMaxBytes)), which
    keeps its status and headers without the body. Over transcoding, any
    success is read as the answer.

Whether the request reached the server, and whether the error came from it:

| `Cause` | Did the request reach the server? | Did the error come from the server? |
|---|---|---|
| `BadCall` | no | no |
| `NetworkError` | probably not; a CORS refusal arrives so after the server acted | no |
| `Timeout` | unknown | no |
| `BadResponse` | yes | no: the client could not use the answer |
| `BadStatus` | something answered | when [`source`](#source) is not `Nothing`; otherwise possibly an edge or a proxy |

A `BadCall` or a `BadResponse` is never retried ([`Rpc.Retry`](Rpc-Retry)):
trying again cannot change it. The constructors are fixed.

-}
type Cause
    = BadCall
    | NetworkError
    | Timeout
    | BadStatus Response
    | BadResponse Response


{-| The HTTP status of the answer, if one came: a `BadStatus`'s or a
`BadResponse`'s. It is always the status the server sent, so it can be 200
for a `BadStatus`: over gRPC-Web a failure is stated in the trailers of a
200, and [`code`](#code) is the reading for it.
-}
httpStatus : Error -> Maybe Int
httpStatus (Error e) =
    case e.cause of
        BadStatus answer ->
            Just answer.statusCode

        BadResponse answer ->
            Just answer.statusCode

        BadCall ->
            Nothing

        NetworkError ->
            Nothing

        Timeout ->
            Nothing



-- THE CODEC


{-| The problem with a body that did not decode as the response message, or
with a request that could not be written as JSON (a value with no JSON form,
or an `Any`); `Nothing` for every other error.

[`Proto.Error.toString`](Proto-Error#toString) describes it in full:

    Rpc.Error.protoError error
        |> Maybe.map Proto.Error.toString

That text can quote the value that failed, and so hold the answer's or the
request's data: keep it out of logs and reports that must not carry it.
Every failure text this package's decoders write says what was expected
and never what was found, so a walk over a `BadJson`'s `Json.Decode.Error`
that prints its path and texts and leaves out its values is safe to report;
calling.md's "The codec" gives one.

-}
protoError : Error -> Maybe Proto.Error.Error
protoError (Error e) =
    e.protoProblem



-- FOR LOGS


{-| A one-line description of an error, for logs: its [`code`](#code) and
[`message`](#message), `not_found: no such note`, or the code alone when the
message is empty.
-}
toString : Error -> String
toString (Error e) =
    Code.toString e.code
        ++ (if String.isEmpty e.message then
                ""

            else
                ": " ++ e.message
           )



-- BUILDING ERRORS


{-| A failure whose status the server stated, with the answer it came in.
-}
fromStatus :
    { code : Code, message : String, details : List (Result Proto.Error.Error Any), source : Source }
    -> Response
    -> Error
fromStatus status answer =
    Error
        { code = status.code
        , message = status.message
        , details = status.details
        , source = Just status.source
        , cause = BadStatus answer
        , protoProblem = Nothing
        }


{-| A failure whose status the server stated, with this code and an empty
message. Its answer is a stand-in: the HTTP status a Connect server sends with
the code ([`Rpc.Code.toHttpStatus`](Rpc-Code#toHttpStatus)), no headers and no
body, and its source is `ConnectBody`.

    Rpc.Error.fromCode Rpc.Code.NotFound
        |> Rpc.Error.withMessage "no such note"

-}
fromCode : Code -> Error
fromCode c =
    fromStatus
        { code = c, message = "", details = [], source = ConnectBody }
        { url = ""
        , statusCode = Code.toHttpStatus c
        , statusText = ""
        , headers = Dict.empty
        , body = Rpc.Body.none
        }


{-| An answer that states no status, as the runtime reads one: a failure
status is a `BadStatus` whose code is inferred from it, and a success (2xx)
is not the protocol's answer, a `BadResponse` whose code is `Unknown`. The
message is the status text, or `HTTP <status>`.
-}
fromResponse : Response -> Error
fromResponse answer =
    Error
        { code = Code.fromHttpStatus answer.statusCode
        , message =
            if String.isEmpty answer.statusText then
                "HTTP " ++ String.fromInt answer.statusCode

            else
                answer.statusText
        , details = []
        , source = Nothing
        , cause =
            if isSuccess answer then
                BadResponse answer

            else
                BadStatus answer
        , protoProblem = Nothing
        }


{-| The call's timeout passed first: `DeadlineExceeded`, `timeout`.
-}
timeout : Error
timeout =
    clientError Timeout Code.DeadlineExceeded "timeout" Nothing


{-| The request failed on the way: `Unavailable`, `network error`.
-}
networkError : Error
networkError =
    clientError NetworkError Code.Unavailable "network error" Nothing


{-| A call that could not be made, with its code and message: nothing was
sent, and it is never retried. The runtime builds one for each check a call
fails before sending; an application that refuses to send a call builds one
the same way, with the code it means.
-}
badCall : Code -> String -> Error
badCall c text =
    clientError BadCall c text Nothing


{-| A call that could not be made because an [`Any`](Proto-Any) in its request
could not be written as JSON, for this reason: a `BadCall`, `Internal`,
`bad Any`, the reason in [`protoError`](#protoError).
-}
badAny : Proto.Error.Error -> Error
badAny problem =
    clientError BadCall Code.Internal "bad Any" (Just problem)


{-| A call that could not be made because its request holds a value proto3
JSON has no form for, such as a `Timestamp` past the year 9999: a `BadCall`,
`InvalidArgument`, the code a server checking the value gives, with the
message `bad value: a <type name> with no JSON form`
and the value's [`BadValue`](Proto-Error#Error), its type and where it is, in
[`protoError`](#protoError). The message names the type alone: the path can
hold a map's keys, which are the request's data.

    Rpc.Error.badValue { typeName = "google.protobuf.Timestamp", path = [ "createTime" ] }

-}
badValue : { typeName : String, path : List String } -> Error
badValue value =
    clientError BadCall Code.InvalidArgument ("bad value: a " ++ value.typeName ++ " with no JSON form") (Just (Proto.Error.BadValue value))


{-| A success that could not be used, with its code, its message and the
answer. Like every builder that takes an answer, it gives the error the
runtime would give for that answer: one that is not a success (2xx) is a
failure that states no status, as [`fromResponse`](#fromResponse) builds it.
-}
badResponse : Code -> String -> Response -> Error
badResponse c text answer =
    answered c text Nothing answer


{-| A success whose body did not decode as the response message, for this
reason: a `BadResponse`, `Internal`, `bad response body`, the reason in
[`protoError`](#protoError). Like every builder that takes an answer, it gives
the error the runtime would give for that answer: one that is not a success
(2xx) is a failure that states no status, as
[`fromResponse`](#fromResponse) builds it.
-}
badBody : Proto.Error.Error -> Response -> Error
badBody problem answer =
    answered Code.Internal "bad response body" (Just problem) answer


answered : Code -> String -> Maybe Proto.Error.Error -> Response -> Error
answered c text problem answer =
    if isSuccess answer then
        clientError (BadResponse answer) c text problem

    else
        fromResponse answer


isSuccess : Response -> Bool
isSuccess answer =
    answer.statusCode >= 200 && answer.statusCode < 300


clientError : Cause -> Code -> String -> Maybe Proto.Error.Error -> Error
clientError why c text problem =
    Error { code = c, message = text, details = [], source = Nothing, cause = why, protoProblem = problem }


{-| An error with this message in place of its own, whatever the error.
-}
withMessage : String -> Error -> Error
withMessage text (Error e) =
    Error { e | message = text }
