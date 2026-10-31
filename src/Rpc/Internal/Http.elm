module Rpc.Internal.Http exposing (badBaseUrl, bytesText, invalidHeader, metadataOf, overLimit, send, splitTrailers, task, utf8Length, validHeaderName, validHeaderValue)

{-| The elm/http adapter: sending a built `Rpc.Request` and reading an
answer's metadata, with what decides whether a request can be sent at all
(header names and values a browser accepts, a base URL without a query).
Percent-encoding is `Proto.Internal.Percent`'s. Not exposed. It is kept out
of `Rpc` so that the public module reads as API; `Rpc` re-exports what users
need.
-}

import Bytes exposing (Bytes)
import Bytes.Decode
import Dict exposing (Dict)
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


{-| Bytes read as UTF-8 text; `""` when they are not UTF-8, where a browser
would write U+FFFD for what it cannot read. Only the bytes path reaches it, so a program that reads
no answer as bytes carries no elm/bytes.
-}
bytesText : Bytes -> String
bytesText raw =
    Bytes.Decode.decode (Bytes.Decode.string (Bytes.width raw)) raw
        |> Maybe.withDefault ""


{-| An answer's status and headers, or `Nothing` when there was no answer.
-}
metadataOf : Http.Response body -> Maybe Http.Metadata
metadataOf answer =
    case answer of
        Http.GoodStatus_ metadata _ ->
            Just metadata

        Http.BadStatus_ metadata _ ->
            Just metadata

        _ ->
            Nothing


{-| Split response headers as a Connect unary answer carries its metadata:
trailers as headers named `trailer-<name>` in any case, headers as the rest.
Names are lowercased, and values whose names differ only in case are joined
with `", "` in the order of their original names. A header named `trailer-`
alone names no trailer and stays a header.
-}
splitTrailers : Dict String String -> { headers : Dict String String, trailers : Dict String String }
splitTrailers =
    Dict.foldl
        (\name value split ->
            let
                lower =
                    String.toLower name
            in
            if String.startsWith trailerPrefix lower && String.length lower > String.length trailerPrefix then
                { split | trailers = insertJoined (String.dropLeft (String.length trailerPrefix) lower) value split.trailers }

            else
                { split | headers = insertJoined lower value split.headers }
        )
        { headers = Dict.empty, trailers = Dict.empty }


trailerPrefix : String
trailerPrefix =
    "trailer-"


insertJoined : String -> String -> Dict String String -> Dict String String
insertJoined key value =
    Dict.update key
        (\earlier ->
            case earlier of
                Just first ->
                    Just (first ++ ", " ++ value)

                Nothing ->
                    Just value
        )


{-| The size of a text (an answer's body, a request's JSON), in UTF-8 bytes,
when it is over `limit`; `Nothing` when it is within it. A limit below 0 is
read as 0, so an empty text is never refused.

A text is at least one byte of UTF-8 per UTF-16 unit of its JavaScript string
and at most three, so a text that fits whatever it holds is never counted.

-}
overLimit : Int -> String -> Maybe Int
overLimit limit text =
    let
        bound =
            max 0 limit

        units =
            String.length text
    in
    if units * 3 <= bound then
        Nothing

    else
        let
            size =
                utf8Length text
        in
        if size > bound then
            Just size

        else
            Nothing


{-| The length of a string written as UTF-8, in bytes. `String.foldl` is a
loop in elm/core's kernel rather than a recursion, so a body of any length
is counted in constant stack. A surrogate pair is one character of four
bytes. The count is exact for well-formed text, which every body the browser
decoded is (it writes U+FFFD for bytes that are not UTF-8); a lone surrogate
has no UTF-8 form, and counts as three or four.
-}
utf8Length : String -> Int
utf8Length =
    String.foldl (\char size -> size + utf8Width (Char.toCode char)) 0


utf8Width : Int -> Int
utf8Width code =
    if code < 0x80 then
        1

    else if code < 0x0800 then
        2

    else if code > 0xFFFF then
        4

    else
        3
