module Rpc.Internal.Http exposing (badBaseUrl, bytesText, configProblems, encodeRouteText, invalidHeader, metadataOf, overLimit, percentDecode, percentEncode, requestTooLarge, send, splitTrailers, task, unreserved, utf8Length, validHeaderName, validHeaderValue)

{-| The elm/http adapter: sending a built `Rpc.Request` and reading an
answer's metadata, with what decides whether a request can be sent at all
(header names and values a browser accepts, a base URL without a query) and
the percent-encoding the transports share. Not exposed. It is kept out of `Rpc` so that the public module reads as API;
`Rpc` re-exports what users need.
-}

import Bitwise
import Bytes exposing (Bytes)
import Bytes.Decode
import Dict exposing (Dict)
import Http
import Json.Encode
import Rpc.Body
import Rpc.Error as Error
import Rpc.Internal.Transport as Transport exposing (Transport)
import Rpc.Request exposing (Request)
import Task exposing (Task)


{-| Percent-encode `text` as UTF-8, keeping the characters `keep` accepts and
writing every other byte as `%XX` with uppercase hex digits. A high surrogate
left without its pair, which a string holds when it was cut inside a
character, has no UTF-8 form and is written as U+FFFD, the replacement
character, as the WHATWG URL encoder writes it.
-}
percentEncode : (Char -> Bool) -> String -> String
percentEncode keep text =
    String.foldr
        (\char encoded ->
            if keep char then
                String.cons char encoded

            else
                String.concat (List.map hexByte (utf8 (Char.toCode char))) ++ encoded
        )
        ""
        text


{-| Decode `%XX` escapes as UTF-8; `Nothing` when an escape is malformed or
the bytes are not UTF-8.
-}
percentDecode : String -> Maybe String
percentDecode text =
    bytesOf (String.toList text) []
        |> Maybe.andThen (\bytes -> decodeUtf8 (List.reverse bytes) [])


bytesOf : List Char -> List Int -> Maybe (List Int)
bytesOf chars acc =
    case chars of
        [] ->
            Just acc

        '%' :: high :: low :: rest ->
            case ( hexValue high, hexValue low ) of
                ( Just h, Just l ) ->
                    bytesOf rest ((h * 16 + l) :: acc)

                _ ->
                    Nothing

        '%' :: _ ->
            Nothing

        char :: rest ->
            bytesOf rest (List.reverse (utf8 (Char.toCode char)) ++ acc)


hexValue : Char -> Maybe Int
hexValue char =
    let
        code =
            Char.toCode (Char.toUpper char)
    in
    if code >= 48 && code <= 57 then
        Just (code - 48)

    else if code >= 65 && code <= 70 then
        Just (code - 55)

    else
        Nothing


decodeUtf8 : List Int -> List Char -> Maybe String
decodeUtf8 bytes acc =
    case bytes of
        [] ->
            Just (String.fromList (List.reverse acc))

        b :: rest ->
            case leadByte b of
                Just ( high, width ) ->
                    case continuations width rest of
                        Just ( low, remaining ) ->
                            -- A tail call, so a long header (a server's
                            -- `grpc-message`) cannot overflow the stack.
                            decodeUtf8 remaining (Char.fromCode (Bitwise.shiftLeftBy (6 * width) high + low) :: acc)

                        Nothing ->
                            Nothing

                Nothing ->
                    Nothing


{-| The value bits of a UTF-8 lead byte and how many continuation bytes follow
it; `Nothing` for a byte that cannot begin a character.
-}
leadByte : Int -> Maybe ( Int, Int )
leadByte b =
    if b < 0x80 then
        Just ( b, 0 )

    else if b >= 0xC2 && b < 0xE0 then
        Just ( b - 0xC0, 1 )

    else if b >= 0xE0 && b < 0xF0 then
        Just ( b - 0xE0, 2 )

    else if b >= 0xF0 && b < 0xF5 then
        Just ( b - 0xF0, 3 )

    else
        Nothing


{-| The value of `width` continuation bytes at the front of `bytes`, and the
bytes after them.
-}
continuations : Int -> List Int -> Maybe ( Int, List Int )
continuations width bytes =
    if width == 0 then
        Just ( 0, bytes )

    else
        case bytes of
            b :: rest ->
                if Bitwise.and 0xC0 b == 0x80 then
                    continuations (width - 1) rest
                        |> Maybe.map (\( value, remaining ) -> ( Bitwise.shiftLeftBy (6 * (width - 1)) (b - 0x80) + value, remaining ))

                else
                    Nothing

            [] ->
                Nothing


{-| RFC 3986's unreserved characters, which percent-encoding never touches:
ASCII letters and digits, `-`, `_`, `.` and `~`.
-}
unreserved : Char -> Bool
unreserved char =
    Char.isAlphaNum char && Char.toCode char < 128 || char == '-' || char == '_' || char == '.' || char == '~'


utf8 : Int -> List Int
utf8 code =
    if code < 0x80 then
        [ code ]

    else if code < 0x0800 then
        [ 0xC0 + Bitwise.shiftRightBy 6 code
        , continuation code
        ]

    else if isNaN (toFloat code) || (code >= 0xD800 && code <= 0xDFFF) then
        -- A high surrogate left without its pair, as when a string is cut
        -- inside a character, reaches here with no code: `Char.toCode`
        -- gives NaN for it. Its value is written as U+FFFD, since no byte
        -- sequence is UTF-8 for it.
        utf8 0xFFFD

    else if code < 0x00010000 then
        [ 0xE0 + Bitwise.shiftRightBy 12 code
        , continuation (Bitwise.shiftRightBy 6 code)
        , continuation code
        ]

    else
        [ 0xF0 + Bitwise.shiftRightBy 18 code
        , continuation (Bitwise.shiftRightBy 12 code)
        , continuation (Bitwise.shiftRightBy 6 code)
        , continuation code
        ]


continuation : Int -> Int
continuation code =
    0x80 + Bitwise.and 0x3F code


hexByte : Int -> String
hexByte byte =
    "%" ++ hexDigit (byte // 16) ++ hexDigit (modBy 16 byte)


hexDigit : Int -> String
hexDigit digit =
    String.slice digit (digit + 1) "0123456789ABCDEF"


{-| A route's literal text (a path segment or a custom verb) as a URL can hold
it: RFC 3986's `pchar` (unreserved characters, sub-delimiters, `:` and `@`)
kept, a `%` already followed by two hex digits kept as the escape it is, and
every other byte percent-encoded.
-}
encodeRouteText : String -> String
encodeRouteText text =
    routeText (String.toList text) []
        |> List.reverse
        |> String.concat


routeText : List Char -> List String -> List String
routeText chars acc =
    case chars of
        [] ->
            acc

        '%' :: high :: low :: rest ->
            if hexValue high /= Nothing && hexValue low /= Nothing then
                routeText rest (String.fromList [ '%', high, low ] :: acc)

            else
                routeText (high :: low :: rest) ("%25" :: acc)

        char :: rest ->
            if pchar char then
                routeText rest (String.fromChar char :: acc)

            else
                routeText rest (percentEncode (\_ -> False) (String.fromChar char) :: acc)


pchar : Char -> Bool
pchar char =
    unreserved char || String.contains (String.fromChar char) "!$&'()*+,;=:@"


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
    Char.isAlphaNum char && Char.toCode char < 128 || String.contains (String.fromChar char) "!#$%&'*+-.^_`|~"


{-| Whether a browser accepts a header value: after the spaces and tabs at
either end, which it trims, no NUL, CR or LF, and no character above U+00FF
(XHR's values are byte strings).
-}
validHeaderValue : String -> Bool
validHeaderValue value =
    String.toList value
        |> dropWhitespace
        |> List.reverse
        |> dropWhitespace
        |> List.all byteChar


dropWhitespace : List Char -> List Char
dropWhitespace chars =
    case chars of
        char :: rest ->
            if char == ' ' || char == '\t' then
                dropWhitespace rest

            else
                chars

        [] ->
            []


{-| A character a header value can hold: up to U+00FF, but NUL, LF and CR. A
lone surrogate's code is NaN, which every comparison fails, so the bound is
written to reject it.
-}
byteChar : Char -> Bool
byteChar char =
    let
        code =
            Char.toCode char
    in
    (code <= 0xFF) && code /= 0 && code /= 0x0A && code /= 0x0D


{-| Whether a base URL holds a query or a fragment, after which a call's path
cannot go.
-}
badBaseUrl : String -> Bool
badBaseUrl url =
    String.contains "?" url || String.contains "#" url


{-| What `Rpc.checkConfig` reports of a config's transport, base URL and
headers, one sentence each. A header is named but its value left out, since
it may be a credential.
-}
configProblems : Transport -> String -> List ( String, String ) -> List String
configProblems transport baseUrl headers =
    (if badBaseUrl baseUrl then
        [ "baseUrl " ++ baseUrl ++ " holds a query or a fragment (? or #), after which a call's path cannot go" ]

     else
        []
    )
        ++ List.filterMap
            (\( name, value ) ->
                if not (validHeaderName name) then
                    Just ("header " ++ quote name ++ " has a name that is not an HTTP token")

                else if not (validHeaderValue value) then
                    Just ("header " ++ quote name ++ " has a value a request cannot carry (NUL, CR, LF or a character above U+00FF)")

                else
                    Nothing
            )
            headers
        ++ belowOne "readMaxBytes" "every response with a body is refused" (Transport.readMaxBytes transport)
        ++ belowOne "writeMaxBytes" "every call is refused unsent" (Transport.writeMaxBytes transport)


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


{-| The request as a task, its response read by `resolver`. A text body is
sent as `application/json`, a bytes body as `application/proto`;
`withCredentials` sends cookies cross-origin (`Http.riskyTask`).
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
    case Rpc.Body.toText request.body of
        Just json ->
            Http.stringBody "application/json" json

        Nothing ->
            case Rpc.Body.toBytes request.body of
                Just binary ->
                    Http.bytesBody "application/proto" binary

                Nothing ->
                    Http.emptyBody


{-| Bytes read as UTF-8 text, as a browser decodes a text body; `""` when
they are not UTF-8.
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


{-| Why a call whose request message's JSON is `json` must not be sent over a
transport: its length in bytes is over the transport's write limit.
-}
requestTooLarge : Transport -> String -> Maybe Error.Reason
requestTooLarge transport json =
    Transport.writeMaxBytes transport
        |> Maybe.andThen
            (\limit ->
                overLimit limit json
                    |> Maybe.map (\size -> Error.RequestTooLarge { limit = limit, size = size })
            )
