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
    let
        -- A character outside ASCII, a lone surrogate among them, encodes
        -- as bytes the first of which is 0x80 or more and lies before any
        -- trailing `=`, where `sextet` refuses it.
        ascii =
            Bytes.Encode.encode (Bytes.Encode.string text)

        -- A third `=` from the end is left in the body, where `sextet`
        -- refuses it.
        padding =
            if String.endsWith "==" text then
                2

            else if String.endsWith "=" text then
                1

            else
                0

        length =
            Bytes.width ascii - padding

        partial =
            modBy 4 length
    in
    if
        (partial == 1)
            || (padding /= 0 && padding /= 4 - partial)
            || ((String.contains "+" text || String.contains "/" text)
                    && (String.contains "-" text || String.contains "_" text)
               )
    then
        Nothing

    else
        Bytes.Decode.decode (Bytes.Decode.loop ( length, [] ) decodeStep) ascii
            |> Maybe.andThen identity
            |> Maybe.map (\done -> Bytes.Encode.encode (Bytes.Encode.sequence (List.reverse done)))


{-| One step of `fromBase64`: the next sixteen characters as twelve bytes,
the next four as three, or the last two or three as one or two, pushed onto
`done` in reverse; `Nothing` at a character that is not base64.
-}
decodeStep : ( Int, List Bytes.Encode.Encoder ) -> Bytes.Decode.Decoder (Bytes.Decode.Step ( Int, List Bytes.Encode.Encoder ) (Maybe (List Bytes.Encode.Encoder)))
decodeStep ( remaining, done ) =
    if remaining >= 16 then
        Bytes.Decode.map4
            (\w0 w1 w2 w3 ->
                let
                    g0 =
                        group w0

                    g1 =
                        group w1

                    g2 =
                        group w2

                    g3 =
                        group w3
                in
                if Bitwise.or (Bitwise.or g0 g1) (Bitwise.or g2 g3) < 0 then
                    Bytes.Decode.Done Nothing

                else
                    Bytes.Decode.Loop
                        ( remaining - 16
                        , word (Bitwise.or (Bitwise.shiftLeftBy 24 g2) g3)
                            :: word (Bitwise.or (Bitwise.shiftLeftBy 16 g1) (Bitwise.shiftRightZfBy 8 g2))
                            :: word (Bitwise.or (Bitwise.shiftLeftBy 8 g0) (Bitwise.shiftRightZfBy 16 g1))
                            :: done
                        )
            )
            word32
            word32
            word32
            word32

    else if remaining >= 4 then
        Bytes.Decode.map
            (\w ->
                let
                    g =
                        group w
                in
                if g < 0 then
                    Bytes.Decode.Done Nothing

                else
                    Bytes.Decode.Loop
                        ( remaining - 4
                        , Bytes.Encode.unsignedInt8 (Bitwise.and 0xFF g)
                            :: Bytes.Encode.unsignedInt16 Bytes.BE (Bitwise.shiftRightZfBy 8 g)
                            :: done
                        )
            )
            word32

    else if remaining == 3 then
        Bytes.Decode.map2
            (\w c ->
                let
                    g =
                        group (Bitwise.or (Bitwise.shiftLeftBy 16 w) (Bitwise.or (Bitwise.shiftLeftBy 8 c) 0x41))
                in
                if g < 0 then
                    Bytes.Decode.Done Nothing

                else
                    Bytes.Decode.Done (Just (Bytes.Encode.unsignedInt16 Bytes.BE (Bitwise.shiftRightZfBy 8 g) :: done))
            )
            word16
            Bytes.Decode.unsignedInt8

    else if remaining == 2 then
        Bytes.Decode.map
            (\w ->
                let
                    g =
                        group (Bitwise.or (Bitwise.shiftLeftBy 16 w) 0x4141)
                in
                if g < 0 then
                    Bytes.Decode.Done Nothing

                else
                    Bytes.Decode.Done (Just (Bytes.Encode.unsignedInt8 (Bitwise.shiftRightZfBy 16 g) :: done))
            )
            word16

    else
        Bytes.Decode.succeed (Bytes.Decode.Done (Just done))


{-| The 24 bits four base64 characters hold, given their codes as one
big-endian 32-bit word, or a negative number when one is not a base64
character: a refused character's -1, shifted left, keeps the sign bit. The
last two or three characters are read with `A`s, worth 0, after them.
-}
group : Int -> Int
group w =
    Bitwise.or
        (Bitwise.or
            (Bitwise.shiftLeftBy 18 (sextet (Bitwise.shiftRightZfBy 24 w)))
            (Bitwise.shiftLeftBy 12 (sextet (Bitwise.and 0xFF (Bitwise.shiftRightZfBy 16 w))))
        )
        (Bitwise.or
            (Bitwise.shiftLeftBy 6 (sextet (Bitwise.and 0xFF (Bitwise.shiftRightZfBy 8 w))))
            (sextet (Bitwise.and 0xFF w))
        )


{-| The value of a base64 character of either alphabet, from its code, or -1.
-}
sextet : Int -> Int
sextet code =
    if code >= 0x61 then
        if code <= 0x7A then
            code - 0x61 + 26

        else
            -1

    else if code >= 0x41 then
        if code <= 0x5A then
            code - 0x41

        else if code == 0x5F then
            63

        else
            -1

    else if code >= 0x30 then
        if code <= 0x39 then
            code - 0x30 + 52

        else
            -1

    else if code == 0x2B || code == 0x2D then
        62

    else if code == 0x2F then
        63

    else
        -1


word32 : Bytes.Decode.Decoder Int
word32 =
    Bytes.Decode.unsignedInt32 Bytes.BE


word16 : Bytes.Decode.Decoder Int
word16 =
    Bytes.Decode.unsignedInt16 Bytes.BE


word : Int -> Bytes.Encode.Encoder
word =
    Bytes.Encode.unsignedInt32 Bytes.BE


{-| Bytes as base64 text, as proto3 JSON writes them: the standard alphabet,
padded with `=` to a multiple of four characters.

    toBase64 (Bytes.Encode.encode (Bytes.Encode.string "hi")) -- "aGk="

-}
toBase64 : Bytes -> String
toBase64 bytes =
    let
        width =
            Bytes.width bytes

        chars =
            Bytes.Decode.decode (Bytes.Decode.loop ( width, [] ) encodeStep) bytes
                |> Maybe.withDefault []
                |> List.reverse
                |> Bytes.Encode.sequence
                |> Bytes.Encode.encode
    in
    Bytes.Decode.decode (Bytes.Decode.string (4 * ((width + 2) // 3))) chars
        |> Maybe.withDefault ""


{-| One step of `toBase64`: the next twelve bytes as sixteen characters, the
next three as four, or the last one or two as four with padding, each four
characters' codes as one big-endian 32-bit word, pushed onto `done` in
reverse.
-}
encodeStep : ( Int, List Bytes.Encode.Encoder ) -> Bytes.Decode.Decoder (Bytes.Decode.Step ( Int, List Bytes.Encode.Encoder ) (List Bytes.Encode.Encoder))
encodeStep ( remaining, done ) =
    if remaining >= 12 then
        Bytes.Decode.map3
            (\w0 w1 w2 ->
                Bytes.Decode.Loop
                    ( remaining - 12
                    , word (characters (Bitwise.and 0x00FFFFFF w2))
                        :: word (characters (Bitwise.or (Bitwise.shiftLeftBy 8 (Bitwise.and 0xFFFF w1)) (Bitwise.shiftRightZfBy 24 w2)))
                        :: word (characters (Bitwise.or (Bitwise.shiftLeftBy 16 (Bitwise.and 0xFF w0)) (Bitwise.shiftRightZfBy 16 w1)))
                        :: word (characters (Bitwise.shiftRightZfBy 8 w0))
                        :: done
                    )
            )
            word32
            word32
            word32

    else if remaining >= 3 then
        Bytes.Decode.map2
            (\w b -> Bytes.Decode.Loop ( remaining - 3, word (characters (Bitwise.or (Bitwise.shiftLeftBy 8 w) b)) :: done ))
            word16
            Bytes.Decode.unsignedInt8

    else if remaining == 2 then
        Bytes.Decode.map
            (\w -> Bytes.Decode.Done (word (Bitwise.or (Bitwise.and 0xFFFFFF00 (characters (Bitwise.shiftLeftBy 8 w))) 0x3D) :: done))
            word16

    else if remaining == 1 then
        Bytes.Decode.map
            (\b -> Bytes.Decode.Done (word (Bitwise.or (Bitwise.and 0xFFFF0000 (characters (Bitwise.shiftLeftBy 16 b))) 0x3D3D) :: done))
            Bytes.Decode.unsignedInt8

    else
        Bytes.Decode.succeed (Bytes.Decode.Done done)


{-| The codes of the four characters that write 24 bits, as one big-endian
32-bit word.
-}
characters : Int -> Int
characters bits =
    Bitwise.or
        (Bitwise.or
            (Bitwise.shiftLeftBy 24 (character (Bitwise.shiftRightZfBy 18 bits)))
            (Bitwise.shiftLeftBy 16 (character (Bitwise.and 0x3F (Bitwise.shiftRightZfBy 12 bits))))
        )
        (Bitwise.or
            (Bitwise.shiftLeftBy 8 (character (Bitwise.and 0x3F (Bitwise.shiftRightZfBy 6 bits))))
            (character (Bitwise.and 0x3F bits))
        )


{-| The code of the standard alphabet's character for a value from 0 to 63.
-}
character : Int -> Int
character value =
    if value < 26 then
        value + 0x41

    else if value < 52 then
        value - 26 + 0x61

    else if value < 62 then
        value - 52 + 0x30

    else if value == 62 then
        0x2B

    else
        0x2F


{-| No bytes: the zero value of a `bytes` field held as `Bytes`.
-}
empty : Bytes
empty =
    Bytes.Encode.encode (Bytes.Encode.sequence [])
