module Rpc.Internal.Http exposing
    ( badBaseUrl
    , invalidHeader
    , send
    , task
    , usableTimeout
    , validHeaderName
    , validHeaderValue
    )

{-| The elm/http adapter: a built `Rpc.Request` sent as a task or as a
command, and what decides whether a request can be sent at all (header names
and values a browser accepts, a base URL without a query, a timeout XHR reads
as the header says). Not exposed. It is kept out of `Rpc` so that the public
module reads as API: `Rpc` sends through `task` and `send`, and
`Rpc.Internal.Plan` refuses a call that fails a check before it gets there.

It knows no protocol and reads no answer: what the protocols share in
building a request and reading an answer is `Rpc.Internal.Envelope`, and the
limits a message is held to are `Rpc.Internal.Limit`. Percent-encoding is
`Proto.Internal.Percent`'s.

-}

import Http
import Rpc.Body
import Rpc.Request exposing (Request)
import Task exposing (Task)


{-| The name of the first header a browser would refuse: one whose name is not
an HTTP token, or whose value a request cannot carry. XHR's `setRequestHeader`
throws on either, and elm/http calls it outside any handler, so the throw
would stop every Elm process for good.
-}
invalidHeader : List ( String, String ) -> Maybe String
invalidHeader headers =
    case headers of
        [] ->
            Nothing

        ( name, value ) :: rest ->
            if validHeaderName name && validHeaderValue value then
                invalidHeader rest

            else
                Just name


{-| Whether a header name is an RFC 9110 token: one or more letters, digits
and `` !#$%&'*+-.^_`|~ ``.
-}
validHeaderName : String -> Bool
validHeaderName name =
    not (String.isEmpty name) && String.all tchar name


tchar : Char -> Bool
tchar char =
    oneUnit char && (Char.isAlphaNum char && Char.toCode char < 128 || String.contains (String.fromChar char) "!#$%&'*+-.^_`|~")


{-| Whether a browser accepts a header value: after the spaces and tabs at
either end, which it trims, no NUL, CR or LF, and no character above U+00FF
(XHR's values are byte strings). A space and a tab are such characters
themselves, so the whole value is checked as it is, in one pass.
-}
validHeaderValue : String -> Bool
validHeaderValue value =
    String.all byteChar value


{-| Whether a character is one UTF-16 code unit, as every character a header
can hold is. elm/core's `String.all` reads a string from its end and takes a
lone low surrogate together with the code unit before it for one character,
whose code is that unit's; the pair's length gives it away. One at the start
is taken with what lies before the string, and rejecting it there stops
`String.all` before it reads further, where it would throw or never return.
-}
oneUnit : Char -> Bool
oneUnit char =
    String.length (String.fromChar char) == 1


{-| A character a header value can hold: up to U+00FF, but NUL, LF and CR. A
lone high surrogate's code is NaN, which every comparison fails, so the bound
is written to reject it.
-}
byteChar : Char -> Bool
byteChar char =
    let
        code =
            Char.toCode char
    in
    oneUnit char && (code <= 0xFF) && code /= 0 && code /= 0x0A && code /= 0x0D


{-| Whether a base URL holds a query or a fragment, after which a call's path
cannot go.
-}
badBaseUrl : String -> Bool
badBaseUrl url =
    String.contains "?" url || String.contains "#" url


{-| The request as a task, its response read by `resolver`. A body is sent
as its content type (`Rpc.Body.contentType`); `withCredentials` sends cookies
cross-origin (`Http.riskyTask`).
-}
task : Http.Resolver e a -> Request -> Task e a
task resolver request =
    let
        perform =
            if request.withCredentials then
                Http.riskyTask

            else
                Http.task
    in
    perform
        { method = request.method
        , headers = List.map (\( name, value ) -> Http.header name value) request.headers
        , url = request.url
        , body = body request
        , resolver = resolver
        , timeout = request.timeout
        }


{-| The request as a command, its response read by `expect`, cancellable
through `tracker` (`Http.cancel`).
-}
send : Http.Expect msg -> Maybe String -> Request -> Cmd msg
send expect tracker request =
    let
        perform =
            if request.withCredentials then
                Http.riskyRequest

            else
                Http.request
    in
    perform
        { method = request.method
        , headers = List.map (\( name, value ) -> Http.header name value) request.headers
        , url = request.url
        , body = body request
        , expect = expect
        , timeout = request.timeout
        , tracker = tracker
        }


body : Request -> Http.Body
body request =
    case ( Rpc.Body.toText request.body, Rpc.Body.toBytes request.body, Rpc.Body.contentType request.body ) of
        ( Just json, _, _ ) ->
            Http.stringBody "application/json" json

        ( Nothing, Just binary, Just type_ ) ->
            Http.bytesBody type_ binary

        _ ->
            Http.emptyBody



-- TIMEOUTS


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
