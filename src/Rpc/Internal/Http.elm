module Rpc.Internal.Http exposing (percentEncode, send, task, unreserved)

{-| What the transports share: percent-encoding, and sending a built request.
Not exposed; `Rpc` re-exports what users need.
-}

import Bitwise
import Http
import Task exposing (Task)


{-| Percent-encode `text` as UTF-8, keeping the characters `keep` accepts and
writing every other byte as `%XX` with uppercase hex digits.
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


type alias Request r =
    { r
        | method : String
        , url : String
        , headers : List ( String, String )
        , body : Maybe String
        , timeout : Maybe Float
        , withCredentials : Bool
    }


{-| The request as a task, its response read by `read`. A body is sent as
`application/json`; `withCredentials` sends cookies cross-origin
(`Http.riskyTask`).
-}
task : (Http.Response String -> Result e a) -> Request r -> Task e a
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
send : (Http.Response String -> Result e a) -> (Result e a -> msg) -> Maybe String -> Request r -> Cmd msg
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


body : Request r -> Http.Body
body request =
    case request.body of
        Just json ->
            Http.stringBody "application/json" json

        Nothing ->
            Http.emptyBody
