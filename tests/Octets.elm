module Octets exposing (bytesOf, fromHex, toHex)

{-| Bytes as a test writes and compares them. Elm's `==` finds any two
`Bytes` equal, so a test compares their hex; and it writes the bytes it reads
as hex, or as a list of octets.
-}

import Bytes exposing (Bytes)
import Bytes.Decode
import Bytes.Encode


{-| The bytes these octets are.
-}
bytesOf : List Int -> Bytes
bytesOf ints =
    Bytes.Encode.encode (Bytes.Encode.sequence (List.map Bytes.Encode.unsignedInt8 ints))


{-| Bytes in lower-case hex, two digits an octet.
-}
toHex : Bytes -> String
toHex input =
    Bytes.Decode.decode
        (Bytes.Decode.loop ( Bytes.width input, [] )
            (\( n, acc ) ->
                if n == 0 then
                    Bytes.Decode.succeed (Bytes.Decode.Done (String.concat (List.reverse acc)))

                else
                    Bytes.Decode.map (\b -> Bytes.Decode.Loop ( n - 1, hexByte b :: acc )) Bytes.Decode.unsignedInt8
            )
        )
        input
        |> Maybe.withDefault "?"


hexByte : Int -> String
hexByte b =
    String.fromList [ hexDigit (b // 16), hexDigit (modBy 16 b) ]


hexDigit : Int -> Char
hexDigit n =
    if n < 10 then
        Char.fromCode (48 + n)

    else
        Char.fromCode (87 + n)


{-| The bytes lower-case hex stands for. Spaces between its digits are
dropped, so that a test can set fields apart; any other character counts as
a zero, and an odd digit left at the end is dropped.
-}
fromHex : String -> Bytes
fromHex text =
    let
        value c =
            let
                code =
                    Char.toCode c
            in
            if code >= 97 && code <= 102 then
                code - 87

            else if code >= 48 && code <= 57 then
                code - 48

            else
                0

        go chars acc =
            case chars of
                hi :: lo :: rest ->
                    go rest (Bytes.Encode.unsignedInt8 (value hi * 16 + value lo) :: acc)

                _ ->
                    List.reverse acc
    in
    Bytes.Encode.encode (Bytes.Encode.sequence (go (String.toList (String.replace " " "" text)) []))
