module Rpc.Error exposing
    ( Error(..), StatusError, Source(..)
    , code, message, toString, response, delivery, Delivery(..)
    )

{-| Why a call failed: what [`Rpc.task`](Rpc#task), [`Rpc.send`](Rpc#send) and
the other ways of sending give in place of the response.

Most code asks for the [`code`](#code) and [`message`](#message), which every
error has:

    case Rpc.Error.code error of
        Rpc.Code.Unauthenticated ->
            signInAgain

        _ ->
            showMessage (Rpc.Error.message error)

@docs Error, StatusError, Source


# Reading an error

@docs code, message, toString, response, delivery, Delivery

-}

import Json.Encode
import Proto.Any exposing (Any)
import Proto.Error
import Rpc.Code as Code exposing (Code)
import Rpc.Response exposing (Response)


{-| Why a call failed. Each constructor is one way, in four groups.


## The server answered

  - `RpcStatus`: the server stated an RPC status, in a Connect error body, a
    `google.rpc.Status` body or the `grpc-status` headers
    ([`StatusError`](#StatusError)), with the answer itself.
  - `HttpStatus`: the server answered with a failure, or with a success that
    is not the protocol's answer, and stated no status; [`code`](#code)
    infers one from the HTTP status. Over Connect and gRPC-Web, a 200 whose
    content type is not the protocol's at all, such as a proxy's HTML page,
    is not the protocol's answer, and is read as a failure is; transcoding
    reads any success as its answer, whatever its content type.


## An answer arrived but could not be read

  - `BadBody`: a successful answer whose body is not the response message,
    as the method's codec reads it: proto3 JSON that is not the message
    (`BadJson`, elm/json's error, whose path locates the failure), an `Any`
    in it of a type the client's registry has no entry for
    (`UnregisteredType`, with its type URL;
    [`Rpc.Client.withRegistry`](Rpc-Client#withRegistry) fixes it), or
    protobuf binary that is not the message (`BadBinary`, the report of
    where and why). [`Proto.Error.toString`](Proto-Error#toString)
    describes one.
  - `BadEnvelope`: what carries a successful answer's body is malformed,
    described here: a content type of the protocol's that the call does not
    read (a Connect JSON call answered as `application/proto`), or a
    gRPC-Web answer with no trailers, frames that do not parse, a status
    that is not a number, or a `grpc-status-details-bin` trailer that is
    not base64.
  - `BadMessageCount`: a unary gRPC-Web answer with status 0 and no message
    or more than one; the number of messages it carried.
  - `ResponseTooLarge`: a successful answer's body was longer, in bytes
    (`size`), than the protocol reads (`limit`,
    [`withReadMaxBytes`](Rpc-Protocol#withReadMaxBytes)). The body was
    dropped without decoding, so the error keeps no `Response`.


## The request was sent and nothing usable came back

  - `Timeout`: the call's timeout passed first.
  - `NetworkError`: the request failed on the way, as when the server is
    unreachable or a browser's CORS check refused the answer.


## The request was never sent

  - `BadUrl`: the URL the call would be sent to cannot be: a `baseUrl` holding
    `?` or `#`, or one the browser refuses.
  - `BadHeader`: a header, named here, that a request cannot carry: its
    name is not an HTTP token, or its value holds NUL, CR, LF or a character
    above U+00FF.
  - `BadPathValue`: over transcoding, a request field the path holds
    (`field`, its JSON names joined with `.`) whose value the variable's
    `template` cannot match, such as `""` or `notes/a/b` for
    `{name=notes/*}`, or which holds a surrogate without its pair, as text
    cut inside a character by `String.left` can.
  - `RequestTooLarge`: the request message, as JSON in UTF-8 or as protobuf
    binary, was longer in bytes (`size`) than the protocol sends (`limit`,
    [`withWriteMaxBytes`](Rpc-Protocol#withWriteMaxBytes)).
  - `BadAny`: over JSON, the request holds a
    [`google.protobuf.Any`](Proto-Any) the client's registry cannot write
    as JSON, for the [`Proto.Error`](Proto-Error#Error) given:
    `UnregisteredType`, which the client's registry fixes
    ([`Rpc.Client.withRegistry`](Rpc-Client#withRegistry)), or the `BadBinary` of an
    `Any` whose binary is not its type's message.

The [`Response`](Rpc-Response#Response) is kept whenever there was an answer
([`response`](#response)), so an error in a shape the runtime does not read,
or a body that drifted from the schema, can still be read:

    case error of
        Rpc.Error.HttpStatus answer ->
            Rpc.Body.toText answer.body
                |> Maybe.withDefault ""
                |> myDecoder

        _ ->
            Err (Rpc.Error.toString error)

-}
type Error
    = -- The server answered.
      RpcStatus StatusError Response
    | HttpStatus Response
      -- An answer arrived but could not be read.
    | BadBody Proto.Error.Error Response
    | BadEnvelope String Response
    | BadMessageCount Int Response
    | ResponseTooLarge { limit : Int, size : Int }
      -- The request was sent and nothing usable came back.
    | Timeout
    | NetworkError
      -- The request was never sent.
    | BadUrl String
    | BadHeader String
    | BadPathValue { field : String, template : String }
    | RequestTooLarge { limit : Int, size : Int }
    | BadAny Proto.Error.Error


{-| A status the server stated: its code, its message (which may be empty), its
details and where it was found. The code is a [`Code`](Rpc-Code#Code), which
has no `ok`: an answer claiming `ok` while failing reads as `Unknown`.

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

    status.details
        |> List.filterMap Result.toMaybe
        |> List.filterMap (Proto.Any.unpack Proto.ErrorDetails.badRequest)

A Connect error body and gRPC-Web carry a detail's protobuf binary, which
needs no registry. A `google.rpc.Status` body (transcoding) carries proto3
JSON, which is read through the client's registry
([`Rpc.Client.withRegistry`](Rpc-Client#withRegistry)). Details a proxy stripped are
simply absent, `[]`.

-}
type alias StatusError =
    { code : Code
    , message : String
    , details : List (Result Proto.Error.Error Any)
    , source : Source
    }


{-| Where a status was read from, tried in this order:

  - `ConnectBody`: a Connect error body, `{"code": "not_found", …}`.
  - `StatusBody`: a `google.rpc.Status` body, `{"code": 5, …}`, as grpc-gateway
    and Envoy send; a number outside `1` to `16` is the code `Unknown`, and the
    number as sent is in the response's body.
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

A failure with none of these is an `HttpStatus` error, and so is a success
that is not the protocol's answer and states none (see [`Error`](#Error)).

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


{-| An error's code, as the Connect clients give it:

  - `RpcStatus`: the server's.
  - `HttpStatus`: inferred from the HTTP status by
    [`Rpc.Code.fromHttpStatus`](Rpc-Code#fromHttpStatus), so a 200 that is
    not the protocol's answer is `Unknown`.
  - `BadBody` and `BadEnvelope` are `Internal`, and `BadMessageCount`
    `Unimplemented`, as connect-es gives them.
  - A timeout is `DeadlineExceeded`, a network failure `Unavailable`, a bad
    URL, a bad header or a bad `Any` `Internal`, a bad path value
    `InvalidArgument`, a request or a response over its limit
    `ResourceExhausted`.

An `HttpStatus` code follows gRPC's table, so a 404 that carries no status
reads as `Unimplemented`, not `NotFound`. That is right for Connect, whose
servers send a status with every error, but over transcoding a hand-written
REST server's bare 404 usually means "not found": such a server should send a
`google.rpc.Status` body (`{"code": 5, "message": …}`) so the code reads as
`NotFound`.

-}
code : Error -> Code
code error =
    case error of
        RpcStatus status _ ->
            status.code

        HttpStatus answer ->
            Code.fromHttpStatus answer.statusCode

        BadBody _ _ ->
            Code.Internal

        BadEnvelope _ _ ->
            Code.Internal

        BadMessageCount _ _ ->
            Code.Unimplemented

        ResponseTooLarge _ ->
            Code.ResourceExhausted

        Timeout ->
            Code.DeadlineExceeded

        NetworkError ->
            Code.Unavailable

        BadUrl _ ->
            Code.Internal

        BadHeader _ ->
            Code.Internal

        BadPathValue _ ->
            Code.InvalidArgument

        RequestTooLarge _ ->
            Code.ResourceExhausted

        BadAny _ ->
            Code.Internal


{-| An error's message:

  - `RpcStatus`: the server's, which may be empty.
  - `HttpStatus`: the status text, or `HTTP <status>` when there is none.
  - `BadBody`: `bad response body: <problem>`, described by
    [`Proto.Error.toString`](Proto-Error#toString); `BadEnvelope`:
    `bad response: <problem>`; `BadMessageCount`: `bad response:` and which
    count it was. elm/json's problem quotes the JSON it rejected, which can
    be the whole response and hold data the application never shows, so the
    message keeps its first 300 characters, then `…`; the whole problem
    stays in the error.
  - The rest: `timeout`, `network error`, `bad URL: <url>`,
    `invalid header "<name>"`, `path field "<field>" does not match
    <template>`, for a bad `Any` `bad Any:` and
    [`Proto.Error.toString`](Proto-Error#toString)'s text, or,
    as connect-es words them,
    `message size <size> is larger than configured writeMaxBytes <limit>`
    for a request and `… readMaxBytes <limit>` for a response, both in
    bytes. A bad URL is printed as its scheme, host and path, without the
    user and password a URL can hold, and without its query and fragment,
    which over Connect's GET hold the request:
    `bad URL: https://api.example.com/base (query omitted)`. The whole URL
    stays in the error. A bad header is named, its value left out, since
    it may be a credential; a bad path value is left out too.

-}
message : Error -> String
message error =
    case error of
        RpcStatus status _ ->
            status.message

        HttpStatus answer ->
            if String.isEmpty answer.statusText then
                "HTTP " ++ String.fromInt answer.statusCode

            else
                answer.statusText

        BadBody problem _ ->
            "bad response body: " ++ excerpt (Proto.Error.toString problem)

        BadEnvelope problem _ ->
            "bad response: " ++ excerpt problem

        BadMessageCount count _ ->
            if count == 0 then
                "bad response: a unary gRPC-Web answer with status 0 and no message"

            else
                "bad response: a unary gRPC-Web answer with status 0 and more than one message"

        ResponseTooLarge { limit, size } ->
            "message size " ++ String.fromInt size ++ " is larger than configured readMaxBytes " ++ String.fromInt limit

        Timeout ->
            "timeout"

        NetworkError ->
            "network error"

        BadUrl url ->
            "bad URL: " ++ printableUrl url

        BadHeader name ->
            "invalid header " ++ Json.Encode.encode 0 (Json.Encode.string name)

        BadPathValue { field, template } ->
            "path field " ++ Json.Encode.encode 0 (Json.Encode.string field) ++ " does not match " ++ template

        RequestTooLarge { limit, size } ->
            "message size " ++ String.fromInt size ++ " is larger than configured writeMaxBytes " ++ String.fromInt limit

        BadAny problem ->
            "bad Any: " ++ Proto.Error.toString problem


{-| The answer an error was read from: the [`Response`](Rpc-Response#Response)
an `RpcStatus`, `HttpStatus`, `BadBody`, `BadEnvelope` or `BadMessageCount`
keeps, and `Nothing` for every other error, which had no answer or dropped it
unread.
-}
response : Error -> Maybe Response
response error =
    case error of
        RpcStatus _ answer ->
            Just answer

        HttpStatus answer ->
            Just answer

        BadBody _ answer ->
            Just answer

        BadEnvelope _ answer ->
            Just answer

        BadMessageCount _ answer ->
            Just answer

        ResponseTooLarge _ ->
            Nothing

        Timeout ->
            Nothing

        NetworkError ->
            Nothing

        BadUrl _ ->
            Nothing

        BadHeader _ ->
            Nothing

        BadPathValue _ ->
            Nothing

        RequestTooLarge _ ->
            Nothing

        BadAny _ ->
            Nothing


{-| How far a failed call got, which says whether the server may have acted
on it ([`Delivery`](#Delivery)).

    case Rpc.Error.delivery error of
        Rpc.Error.NeverSent ->
            "The note was not saved: " ++ Rpc.Error.message error

        Rpc.Error.Unanswered ->
            "The note may have been saved; reload to check."

        Rpc.Error.Answered ->
            "The server answered: " ++ Rpc.Error.message error

-}
delivery : Error -> Delivery
delivery error =
    case error of
        RpcStatus _ _ ->
            Answered

        HttpStatus _ ->
            Answered

        BadBody _ _ ->
            Answered

        BadEnvelope _ _ ->
            Answered

        BadMessageCount _ _ ->
            Answered

        ResponseTooLarge _ ->
            Answered

        Timeout ->
            Unanswered

        NetworkError ->
            Unanswered

        BadUrl _ ->
            NeverSent

        BadHeader _ ->
            NeverSent

        BadPathValue _ ->
            NeverSent

        RequestTooLarge _ ->
            NeverSent

        BadAny _ ->
            NeverSent


{-| How far a failed call got:

  - `NeverSent`: the request was refused before it was sent (`BadUrl`,
    `BadHeader`, `BadPathValue`, `RequestTooLarge`, `BadAny`); the server
    did nothing.
  - `Unanswered`: the request may have been sent, and no answer came
    (`Timeout`, `NetworkError`); the server may or may not have acted.
  - `Answered`: an answer came, read or not; the server, or something in
    front of it, saw the request.

-}
type Delivery
    = NeverSent
    | Unanswered
    | Answered


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
