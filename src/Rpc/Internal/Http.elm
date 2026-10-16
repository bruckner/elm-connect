module Rpc.Internal.Http exposing (Request, badBaseUrl, metadataOf, percentDecode, percentEncode, send, splitTrailers, task, unreserved)

{-| What the transports share: percent-encoding, sending a built request, and
reading an answer's metadata. Not exposed; `Rpc` re-exports what users need.
-}

import Bitwise
import Dict exposing (Dict)
import Http
import Rpc.Internal.Body as Body
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


{-| Whether a base URL holds a query or a fragment, after which a call's path
cannot go.
-}
badBaseUrl : String -> Bool
badBaseUrl url =
    String.contains "?" url || String.contains "#" url


{-| `Rpc.Request`, which `Rpc.Trace` holds too and cannot import from `Rpc`.
-}
type alias Request =
    { method : String
    , url : String
    , headers : List ( String, String )
    , body : Body.Body
    , timeout : Maybe Float
    , withCredentials : Bool
    }


{-| The request as a task, its response read by `read`. A body is sent as
`application/json`; `withCredentials` sends cookies cross-origin
(`Http.riskyTask`).
-}
task : (Http.Response String -> Result e a) -> Request -> Task e a
task read request =
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
        , resolver = Http.stringResolver read
        , timeout = request.timeout
        }


{-| The request as a command, its response read by `read`, cancellable through
`tracker` (`Http.cancel`).
-}
send : (Http.Response String -> Result e a) -> (Result e a -> msg) -> Maybe String -> Request -> Cmd msg
send read toMsg tracker request =
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
        , expect = Http.expectStringResponse toMsg read
        , timeout = request.timeout
        , tracker = tracker
        }


body : Request -> Http.Body
body request =
    case request.body of
        Body.Text json ->
            Http.stringBody "application/json" json

        Body.Empty ->
            Http.emptyBody


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
