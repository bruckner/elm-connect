module Rpc.Error exposing
    ( Error(..), Reason(..), StatusError, Source(..)
    , code, message, details, toString
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

@docs Error, Reason, StatusError, Source


# Reading an error

@docs code, message, details, toString

-}

import Proto.Any exposing (Any)
import Proto.Message exposing (Message)
import Rpc.Code as Code exposing (Code)
import Rpc.Response exposing (Response)


{-| Why a call failed, by what came back:

  - `RpcStatus`: the server stated an RPC status, in a Connect error body, a
    `google.rpc.Status` body or the `grpc-status` headers
    ([`StatusError`](#StatusError)), with the answer itself.
  - `HttpStatus`: the server answered with a failure and stated no status;
    [`code`](#code) infers one from the HTTP status.
  - `BadResponse`: the server answered with success, but the body did not
    decode as the response; the problem, then the answer.
  - `NoAnswer`: nothing came back, or nothing was sent
    ([`Reason`](#Reason)).

The [`Response`](Rpc-Response#Response) is kept whenever there was an answer,
so an error in a shape the runtime does not read, or a body that drifted from
the schema, can still be read:

    case error of
        Rpc.Error.HttpStatus response ->
            myDecoder response.body

        _ ->
            Err (Rpc.Error.toString error)

The constructors are fixed: a failure before an answer is one of the
[`Reason`](#Reason)s, and one found in an answer that arrived is a
`BadResponse`.

-}
type Error
    = RpcStatus StatusError Response
    | HttpStatus Response
    | BadResponse String Response
    | NoAnswer Reason


{-| Why no answer came:

  - `Timeout`: the call's timeout passed first.
  - `NetworkError`: the request failed on the way, as when the server is
    unreachable or a browser's CORS check refused the answer.
  - `BadUrl`: the URL the call would be sent to cannot be: a `baseUrl` holding
    `?` or `#`, or one the browser refuses. Nothing was sent.

These are every way a request can fail before an answer, and the type is
fixed.

-}
type Reason
    = Timeout
    | NetworkError
    | BadUrl String


{-| A status the server stated: its code, its message (which may be empty), its
details and where it was found. Each detail is a message packed in an
[`Any`](Proto-Any#Any), read with [`details`](#details) or
[`Proto.Any.unpack`](Proto-Any#unpack). The code is a [`Code`](Rpc-Code#Code),
which has no `ok`: an answer claiming `ok` while failing reads as `Unknown`.
-}
type alias StatusError =
    { code : Code
    , message : String
    , details : List Any
    , source : Source
    }


{-| Where a status was read from, tried in this order:

  - `ConnectBody`: a Connect error body, `{"code": "not_found", …}`.
  - `StatusBody`: a `google.rpc.Status` body, `{"code": 5, …}`, as grpc-gateway
    and Envoy send; a number outside `1` to `16` is the code `Unknown`, and the
    number as sent is in the response's body.
  - `GrpcHeaders`: the `grpc-status` and `grpc-message` headers, when the
    browser exposes them; the message is percent-decoded, and the status text
    stands in when there is none.

An answer with none of these is an `HttpStatus` error.

-}
type Source
    = ConnectBody
    | StatusBody
    | GrpcHeaders


{-| An error's code, as the Connect clients give it:

  - `RpcStatus`: the server's.
  - `HttpStatus`: inferred from the HTTP status by
    [`Rpc.Code.fromHttpStatus`](Rpc-Code#fromHttpStatus).
  - `BadResponse`: `Internal`.
  - `NoAnswer`: a timeout is `DeadlineExceeded`, a network failure
    `Unavailable`, a bad URL `Internal`.

-}
code : Error -> Code
code error =
    case error of
        RpcStatus status _ ->
            status.code

        HttpStatus answer ->
            Code.fromHttpStatus answer.statusCode

        BadResponse _ _ ->
            Code.Internal

        NoAnswer Timeout ->
            Code.DeadlineExceeded

        NoAnswer NetworkError ->
            Code.Unavailable

        NoAnswer (BadUrl _) ->
            Code.Internal


{-| An error's message:

  - `RpcStatus`: the server's, which may be empty.
  - `HttpStatus`: the status text, or `HTTP <status>` when there is none.
  - `BadResponse`: `bad response body: <problem>`. elm/json's problem quotes
    the JSON it rejected, which can be the whole response and hold data the
    application never shows, so the message keeps its first 300 characters,
    then `…`; the whole problem stays in the error.
  - `NoAnswer`: `timeout`, `network error` or `bad URL: <url>`. A bad URL is printed as its scheme, host and
    path, without the user and password a URL can hold, and without its query
    and fragment, which over Connect's GET hold the request:
    `bad URL: https://api.example.com/base (query omitted)`. The whole URL
    stays in the error.

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

        BadResponse problem _ ->
            "bad response body: " ++ excerpt problem

        NoAnswer Timeout ->
            "timeout"

        NoAnswer NetworkError ->
            "network error"

        NoAnswer (BadUrl url) ->
            "bad URL: " ++ printableUrl url


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


{-| The details of an error that are of this message type, in the order the
server sent them, leaving out any that do not decode. Only an `RpcStatus`
error has any.

    case Rpc.Error.details Google.Rpc.messageBadRequest error of
        badRequest :: _ ->
            showViolations badRequest.fieldViolations

        [] ->
            showMessage (Rpc.Error.message error)

-}
details : Message a -> Error -> List a
details proto error =
    case error of
        RpcStatus status _ ->
            List.filterMap (Proto.Any.unpack proto >> Maybe.andThen Result.toMaybe) status.details

        _ ->
            []


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
