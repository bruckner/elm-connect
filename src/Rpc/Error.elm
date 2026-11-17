module Rpc.Error exposing
    ( Error
    , code, message, details, source, Source(..)
    , response, httpStatus, cause, Cause(..)
    , toString
    , fromStatus, fromCode, fromResponse, timeout, networkError, badCall, badResponse, withMessage, withDetails
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

An application calling a REST API, over transcoding, reads it as elm/http's
`Http.Error`, through [`response`](#response):

    case Rpc.Error.response error of
        Ok answer ->
            -- elm/http's BadStatus: the server answered with a failure.
            if answer.statusCode == 401 then
                signInAgain

            else
                showMessage (Rpc.Error.message error)

        Err _ ->
            -- elm/http's BadUrl, Timeout, NetworkError or BadBody.
            showMessage (Rpc.Error.message error)

@docs Error


# The RPC view

@docs code, message, details, source, Source


# The HTTP view

@docs response, httpStatus, cause, Cause


# For logs

@docs toString


# Building errors

For tests and previews; the runtime builds its errors with these same
functions, so an error built here and one the runtime gives are `==` when
they state the same things.

@docs fromStatus, fromCode, fromResponse, timeout, networkError, badCall, badResponse, withMessage, withDetails

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
        , answer : Result Cause Response
        }



-- THE RPC VIEW


{-| An error's code, as the Connect clients give it.

When the server stated a status ([`source`](#source) is not `Nothing`), it
is the server's. When the server answered with a failure and stated none, it
is inferred from the HTTP status by
[`Rpc.Code.fromHttpStatus`](Rpc-Code#fromHttpStatus): a 404 is
`Unimplemented`, not `NotFound`, and a 200 that is not the protocol's answer
is `Unknown`.

When the client produced the error ([`cause`](#cause)), the code is its own:
a timeout is `DeadlineExceeded`, a network failure `Unavailable`; a call that
could not be made is `Internal`, `InvalidArgument` for a path value its
template cannot match, or `ResourceExhausted` for a request over its limit;
an answer that could not be used is `Internal`, `ResourceExhausted` for one
over its limit, or `Unimplemented` for a unary gRPC-Web answer that carried
no message or more than one.

Those codes have server meanings too, and so do the codes inferred from a
bare HTTP status (an edge's 429 reads as `Unavailable`). Code that acts on
what the server said checks that it said it:

    Rpc.Error.source error
        /= Nothing
        && Rpc.Error.code error
        == Rpc.Code.ResourceExhausted

-}
code : Error -> Code
code (Error e) =
    e.code


{-| An error's message:

  - When the server stated a status, the server's, which may be empty.
  - When the server answered with a failure and stated none, the status
    text, or `HTTP <status>` when there is none.
  - When the client produced it, what went wrong: `timeout`, `network
    error`, `bad URL: <url>`, `invalid header "<name>"`, `path field
    "<field>" does not match <template>`, `bad Any: <problem>`,
    `bad response: <problem>`, or, as connect-es words them,
    `message size <size> is larger than configured writeMaxBytes <limit>`
    and `… readMaxBytes <limit>`, in bytes. A bad URL is printed as its
    scheme, host and path, without the user and password a URL can hold and
    without its query and fragment, which over Connect's GET hold the
    request: `bad URL: https://api.example.com/base (query omitted)`. A bad
    header is named without its value, which may be a credential.
  - For a body that is not the response message, `bad response body:` and
    where and why, never the value it rejected:
    `bad response body: at json.tokens.accessToken: Expecting a STRING`
    ([`Proto.Error.toStringWithoutValues`](Proto-Error#toStringWithoutValues)).
    The body itself is in the [`response`](#response).

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


{-| Where the server stated the error's status, or `Nothing` when it stated
none: a failure answer without one, or an error the client produced.
-}
source : Error -> Maybe Source
source (Error e) =
    e.source


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


{-| The server's failure answer, or why there is none to read. This is
elm/http's `Http.Error` model:

| elm/http | `response` |
|---|---|
| `BadStatus n` | `Ok answer`, `answer.statusCode == n` |
| `BadBody _` | `Err (BadResponse answer)` |
| `Timeout` | `Err Timeout` |
| `NetworkError` | `Err NetworkError` |
| `BadUrl _` | `Err BadCall` |

`Ok` holds the answer, its URL, status, status text, headers and body, so a
failure in a shape the runtime does not read can still be read:

    case Rpc.Error.response error of
        Ok answer ->
            Rpc.Body.toText answer.body
                |> Maybe.withDefault ""
                |> myDecoder

        Err _ ->
            Err (Rpc.Error.toString error)

A 2xx is an `Ok` failure too when it is not the protocol's answer at all,
such as a proxy's HTML page in place of a Connect or gRPC-Web answer; over
transcoding, any success is read as the answer.

-}
response : Error -> Result Cause Response
response (Error e) =
    e.answer


{-| The HTTP status of any answer the error holds, a
[`BadResponse`](#Cause)'s included, or `Nothing` when none came. It is always
the status the server sent.
-}
httpStatus : Error -> Maybe Int
httpStatus (Error e) =
    case e.answer of
        Ok answer ->
            Just answer.statusCode

        Err (BadResponse answer) ->
            Just answer.statusCode

        Err _ ->
            Nothing


{-| Why the client produced the error, or `Nothing` when the server answered
with a failure: [`response`](#response)'s `Err`.
-}
cause : Error -> Maybe Cause
cause (Error e) =
    case e.answer of
        Ok _ ->
            Nothing

        Err why ->
            Just why


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
  - `BadResponse`: an answer came and could not be used, the answer here:
    its body is not the response message, its content type, framing or
    status is malformed, or it is over the protocol's read limit
    ([`withReadMaxBytes`](Rpc-Protocol#withReadMaxBytes)), which keeps its
    status and headers without the body.

A `BadCall` or a `BadResponse` is never retried
([`Rpc.Retry`](Rpc-Retry)): trying again cannot change it.

-}
type Cause
    = BadCall
    | NetworkError
    | Timeout
    | BadResponse Response



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
        , answer = Ok answer
        }


{-| A failure whose status the server stated in a Connect error body, with
this code and an empty message, in the answer a Connect server would send:
the code's HTTP status ([`Rpc.Code.toHttpStatus`](Rpc-Code#toHttpStatus))
and the body `{"code":"<code>"}`.

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
        , headers = Dict.singleton "content-type" "application/json"
        , body = Rpc.Body.text ("{\"code\":\"" ++ Code.toString c ++ "\"}")
        }


{-| A failure answer that states no status: its code is inferred from the
HTTP status, its message is the status text, or `HTTP <status>`.
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
        , answer = Ok answer
        }


{-| The call's timeout passed first: `DeadlineExceeded`, `timeout`.
-}
timeout : Error
timeout =
    clientError Timeout Code.DeadlineExceeded "timeout"


{-| The request failed on the way: `Unavailable`, `network error`.
-}
networkError : Error
networkError =
    clientError NetworkError Code.Unavailable "network error"


{-| A call that could not be made, with its code and message.
-}
badCall : Code -> String -> Error
badCall =
    clientError BadCall


{-| An answer that could not be used, with its code, its message and the
answer.
-}
badResponse : Code -> String -> Response -> Error
badResponse c text answer =
    clientError (BadResponse answer) c text


clientError : Cause -> Code -> String -> Error
clientError why c text =
    Error { code = c, message = text, details = [], source = Nothing, answer = Err why }


{-| An error with this message in place of its own.
-}
withMessage : String -> Error -> Error
withMessage text (Error e) =
    Error { e | message = text }


{-| An error with these details in place of its own. Only a status the
server stated has details; on any other error they are kept and read back,
though the runtime never gives such an error.
-}
withDetails : List Any -> Error -> Error
withDetails found (Error e) =
    Error { e | details = List.map Ok found }
