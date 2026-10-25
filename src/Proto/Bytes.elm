module Proto.Bytes exposing (fromBase64, toBase64, empty)

{-| Conversions between the base64 text proto3 JSON carries `bytes` fields in
and elm/bytes' `Bytes`.

By default elm-connect holds a `bytes` field as a `String`, the base64 text as
it arrived; these functions turn it into `Bytes` where an application needs the
bytes themselves. Code generated with the `bytes=bytes` option holds the field
as `Bytes` already, and uses these functions to read and write it.

**Elm's `==` does not look inside a `Bytes` value.** Any two `Bytes` compare
equal, whatever they hold:

    Bytes.Encode.encode (Bytes.Encode.unsignedInt8 1)
        == Bytes.Encode.encode (Bytes.Encode.unsignedInt8 2)
    -- True

So two records that differ only in a `Bytes` field compare equal, a test's
`Expect.equal` passes when the bytes differ, and a check for whether a model
changed misses a change to them. Compare the bytes some other way, such as
through `toBase64`:

    toBase64 old.avatar == toBase64 new.avatar

@docs fromBase64, toBase64, empty

-}

import Bitwise
import Bytes exposing (Bytes)
import Bytes.Decode
import Bytes.Encode


{-| The bytes that base64 text holds, or `Nothing` when it is not base64.

It reads what proto3 JSON parsers accept: the standard alphabet (`A`–`Z`,
`a`–`z`, `0`–`9`, `+`, `/`) or the URL-safe one (`-` and `_` in place of `+`
and `/`), not both in one string, with or without `=` padding. Anything else
gives `Nothing`: another character, a length no base64 text has, or padding
that does not fit the length.

    fromBase64 "aGk=" |> Maybe.map Bytes.width -- Just 2

    fromBase64 "aGk" |> Maybe.map Bytes.width -- Just 2

    fromBase64 "a" -- Nothing

-}
fromBase64 : String -> Maybe Bytes
fromBase64 text =
    -- Checked first: only text of these characters is safe to read from the
    -- end, as `String.any` and `String.toList` do (see `base64Char`).
    if String.all base64Char text then
        decodeBase64 text

    else
        Nothing


{-| A character base64 text can hold: either alphabet or padding. elm/core's
`String.all` reads a string from its end and takes a low surrogate without its
high half together with the code unit before it, a letter perhaps, as one
character two units long; at the start of the text, with what lies before the
string, where reading on would never return. Its length refuses it.
-}
base64Char : Char -> Bool
base64Char char =
    String.length (String.fromChar char) == 1 && (Char.isAlphaNum char || String.contains (String.fromChar char) "+/-_=")


decodeBase64 : String -> Maybe Bytes
decodeBase64 text =
    let
        body =
            dropPadding text

        length =
            String.length body

        padding =
            String.length text - length

        partial =
            modBy 4 length

        standard =
            String.any (\char -> char == '+' || char == '/') body

        urlSafe =
            String.any (\char -> char == '-' || char == '_') body
    in
    if
        (partial == 1)
            || (padding /= 0 && (partial == 0 || padding /= 4 - partial))
            || (standard && urlSafe)
    then
        Nothing

    else
        decodeGroups (String.toList body) []
            |> Maybe.map (\encoders -> Bytes.Encode.encode (Bytes.Encode.sequence (List.reverse encoders)))


{-| The bytes of base64 characters four at a time, each group's three bytes
pushed onto `done` in reverse; a final group of two or three characters holds
one or two bytes.
-}
decodeGroups : List Char -> List Bytes.Encode.Encoder -> Maybe (List Bytes.Encode.Encoder)
decodeGroups chars done =
    case chars of
        a :: b :: c :: d :: rest ->
            let
                group =
                    sextets [ a, b, c, d ]
            in
            if group < 0 then
                Nothing

            else
                decodeGroups rest (byte group 0 :: byte group 8 :: byte group 16 :: done)

        [ a, b, c ] ->
            let
                group =
                    sextets [ a, b, c, 'A' ]
            in
            if group < 0 then
                Nothing

            else
                Just (byte group 8 :: byte group 16 :: done)

        [ a, b ] ->
            let
                group =
                    sextets [ a, b, 'A', 'A' ]
            in
            if group < 0 then
                Nothing

            else
                Just (byte group 16 :: done)

        [] ->
            Just done

        -- A length with one character over a group is rejected before.
        _ ->
            Nothing


{-| The 24 bits four base64 characters hold, or -1 when one is not a base64
character.
-}
sextets : List Char -> Int
sextets chars =
    List.foldl
        (\char group ->
            let
                value =
                    sextet char
            in
            if group < 0 || value < 0 then
                -1

            else
                Bitwise.or (Bitwise.shiftLeftBy 6 group) value
        )
        0
        chars


{-| The value of a base64 character of either alphabet, or -1.
-}
sextet : Char -> Int
sextet char =
    let
        code =
            Char.toCode char
    in
    if code >= 0x41 && code <= 0x5A then
        code - 0x41

    else if code >= 0x61 && code <= 0x7A then
        code - 0x61 + 26

    else if code >= 0x30 && code <= 0x39 then
        code - 0x30 + 52

    else if char == '+' || char == '-' then
        62

    else if char == '/' || char == '_' then
        63

    else
        -1


byte : Int -> Int -> Bytes.Encode.Encoder
byte group shift =
    Bytes.Encode.unsignedInt8 (Bitwise.and 0xFF (Bitwise.shiftRightZfBy shift group))


dropPadding : String -> String
dropPadding text =
    if String.endsWith "=" text then
        dropPadding (String.dropRight 1 text)

    else
        text


{-| Bytes as base64 text, as proto3 JSON writes them: the standard alphabet,
padded with `=` to a multiple of four characters.

    toBase64 (Bytes.Encode.encode (Bytes.Encode.string "hi")) -- "aGk="

-}
toBase64 : Bytes -> String
toBase64 bytes =
    Bytes.Decode.decode (Bytes.Decode.loop ( Bytes.width bytes, [] ) encodeGroup) bytes
        |> Maybe.withDefault ""


{-| One step of `toBase64`: the next three bytes as four characters, pushed
onto `done` in reverse, or the last one or two bytes as padded characters.
-}
encodeGroup : ( Int, List Char ) -> Bytes.Decode.Decoder (Bytes.Decode.Step ( Int, List Char ) String)
encodeGroup ( remaining, done ) =
    if remaining >= 3 then
        Bytes.Decode.map3
            (\a b c ->
                Bytes.Decode.Loop ( remaining - 3, groupChars 4 (triple a b c) done )
            )
            Bytes.Decode.unsignedInt8
            Bytes.Decode.unsignedInt8
            Bytes.Decode.unsignedInt8

    else if remaining == 2 then
        Bytes.Decode.map2
            (\a b -> Bytes.Decode.Done (finish ('=' :: groupChars 3 (triple a b 0) done)))
            Bytes.Decode.unsignedInt8
            Bytes.Decode.unsignedInt8

    else if remaining == 1 then
        Bytes.Decode.map
            (\a -> Bytes.Decode.Done (finish ('=' :: '=' :: groupChars 2 (triple a 0 0) done)))
            Bytes.Decode.unsignedInt8

    else
        Bytes.Decode.succeed (Bytes.Decode.Done (finish done))


triple : Int -> Int -> Int -> Int
triple a b c =
    Bitwise.or (Bitwise.shiftLeftBy 16 a) (Bitwise.or (Bitwise.shiftLeftBy 8 b) c)


{-| The first `count` characters of a 24-bit group, most significant first,
pushed onto `done` in reverse.
-}
groupChars : Int -> Int -> List Char -> List Char
groupChars count bits done =
    List.foldl
        (\index acc -> character (Bitwise.and 0x3F (Bitwise.shiftRightZfBy (18 - 6 * index) bits)) :: acc)
        done
        (List.range 0 (count - 1))


character : Int -> Char
character value =
    if value < 26 then
        Char.fromCode (0x41 + value)

    else if value < 52 then
        Char.fromCode (0x61 + value - 26)

    else if value < 62 then
        Char.fromCode (0x30 + value - 52)

    else if value == 62 then
        '+'

    else
        '/'


finish : List Char -> String
finish done =
    String.fromList (List.reverse done)


{-| No bytes: the zero value of a `bytes` field held as `Bytes`.
-}
empty : Bytes
empty =
    Bytes.Encode.encode (Bytes.Encode.sequence [])
