module Proto.Internal.Percent exposing (encodeRouteText, percentDecode, percentEncode, unreserved, wellFormed)

{-| Percent-encoding and decoding as URLs need them: the protocols' query
strings, a route's path values and literals, and the reading of an error
message from a header. Not exposed. It lives under `Proto` so that the route
helpers generated code calls (`Proto.Route`) reach no `Rpc` module.
-}

import Bitwise


{-| Percent-encode `text` as UTF-8, keeping the characters `keep` accepts and
writing every other byte as `%XX` with uppercase hex digits. A surrogate
without its pair has no UTF-8 form and is written as U+FFFD, the replacement
character, as the WHATWG URL encoder writes it.
-}
percentEncode : (Char -> Bool) -> String -> String
percentEncode keep text =
    foldrScalars
        (\char encoded ->
            if keep char then
                String.cons char encoded

            else
                String.concat (List.map hexByte (utf8 (Char.toCode char))) ++ encoded
        )
        ""
        text


{-| `String.foldr` over the characters of `text`, each surrogate without its
pair read as U+FFFD. elm/core's `String.foldr` reads a string from its end
and takes a low surrogate together with the code unit before it for one
character, whose code is that unit's when the unit is not a high surrogate;
one at the start is taken with what lies before the string, and the fold
then never returns. The leading ones are read off first, from the start.
-}
foldrScalars : (Char -> b -> b) -> b -> String -> b
foldrScalars step initial text =
    let
        ( leading, rest ) =
            leadingLows 0 text

        folded =
            String.foldr
                (\char state ->
                    let
                        code =
                            Char.toCode char
                    in
                    if String.length (String.fromChar char) == 1 then
                        -- A lone high surrogate's code is NaN.
                        if code >= 0 then
                            step char state

                        else
                            step replacement state

                    else if code >= 0x00010000 then
                        step char state

                    else
                        step (scalar code) (step replacement state)
                )
                initial
                rest
    in
    List.foldl (\_ state -> step replacement state) folded (List.repeat leading ())


{-| How many lone low surrogates `text` starts with, and the text after them.
-}
leadingLows : Int -> String -> ( Int, String )
leadingLows count text =
    case String.uncons text of
        Just ( first, rest ) ->
            if String.length (String.fromChar first) == 1 && surrogate (Char.toCode first) then
                leadingLows (count + 1) rest

            else
                ( count, text )

        Nothing ->
            ( count, text )


{-| Whether every character of `text` is a Unicode scalar value: it holds no
surrogate without its pair, so it has a UTF-8 form. `String.all` reads from
the end as `String.foldr` does, and stops at the first character this
refuses: a low surrogate taken with a unit that is not its high half, a lone
high surrogate, or one at the start taken with what lies before the string.
-}
wellFormed : String -> Bool
wellFormed =
    String.all
        (\char ->
            let
                code =
                    Char.toCode char
            in
            case String.length (String.fromChar char) of
                1 ->
                    code < 0xD800 || code > 0xDFFF

                2 ->
                    code >= 0x00010000

                _ ->
                    False
        )


surrogate : Int -> Bool
surrogate code =
    code >= 0xD800 && code <= 0xDFFF


scalar : Int -> Char
scalar code =
    if surrogate code then
        replacement

    else
        Char.fromCode code


replacement : Char
replacement =
    '�'


{-| Decode `%XX` escapes as UTF-8; `Nothing` when an escape is malformed or
the bytes are not UTF-8.
-}
percentDecode : String -> Maybe String
percentDecode text =
    bytesOf (foldrScalars (::) [] text) []
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


{-| The UTF-8 bytes of a Unicode scalar value, which `foldrScalars` makes of
every character it reads.
-}
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


{-| A route's literal text (a path segment or a custom verb) as a URL can hold
it: RFC 3986's `pchar` (unreserved characters, sub-delimiters, `:` and `@`)
kept, a `%` already followed by two hex digits kept as the escape it is, and
every other byte percent-encoded.
-}
encodeRouteText : String -> String
encodeRouteText text =
    routeText (foldrScalars (::) [] text) []
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
