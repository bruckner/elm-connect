module Proto.BytesTest exposing (suite)

{-| `Proto.Bytes` and the `Proto.Json` codecs for bytes held as `Bytes`.

Elm's `==` finds any two `Bytes` equal, so nothing here compares `Bytes`
directly: each expectation compares their contents as a list of integers.

-}

import Bytes exposing (Bytes)
import Bytes.Decode
import Bytes.Encode
import Expect exposing (Expectation)
import Fuzz exposing (Fuzzer)
import Fuzzers
import Json.Decode
import Json.Encode
import Proto.Bytes
import Proto.Json
import Test exposing (Test, describe, fuzz, test)


suite : Test
suite =
    describe "Proto.Bytes"
        [ fromBase64Tests
        , toBase64Tests
        , properties
        , largeTests
        , jsonTests
        , test "== does not look inside Bytes, as the module documentation says" <|
            \_ -> (fromList [ 1 ] == fromList [ 2 ]) |> Expect.equal True
        ]


fromList : List Int -> Bytes
fromList ints =
    Bytes.Encode.encode (Bytes.Encode.sequence (List.map Bytes.Encode.unsignedInt8 ints))


toList : Bytes -> List Int
toList bytes =
    let
        step ( remaining, done ) =
            if remaining == 0 then
                Bytes.Decode.succeed (Bytes.Decode.Done (List.reverse done))

            else
                Bytes.Decode.map (\int -> Bytes.Decode.Loop ( remaining - 1, int :: done )) Bytes.Decode.unsignedInt8
    in
    Bytes.Decode.decode (Bytes.Decode.loop ( Bytes.width bytes, [] ) step) bytes
        |> Maybe.withDefault []


{-| `text` is base64 holding `ints`.
-}
reads : String -> List Int -> Test
reads text ints =
    test ("reads \"" ++ text ++ "\"") <|
        \_ -> Proto.Bytes.fromBase64 text |> Maybe.map toList |> Expect.equal (Just ints)


rejects : String -> Test
rejects text =
    test ("rejects \"" ++ text ++ "\"") <|
        \_ -> Proto.Bytes.fromBase64 text |> Maybe.map toList |> Expect.equal Nothing


fromBase64Tests : Test
fromBase64Tests =
    describe "fromBase64"
        [ reads "" []
        , reads "aGk=" [ 0x68, 0x69 ]
        , reads "aGk" [ 0x68, 0x69 ]
        , reads "aA==" [ 0x68 ]
        , reads "aA" [ 0x68 ]
        , reads "aGVsbG8h" [ 0x68, 0x65, 0x6C, 0x6C, 0x6F, 0x21 ]
        , reads "+/+/" [ 0xFB, 0xFF, 0xBF ]
        , reads "-_-_" [ 0xFB, 0xFF, 0xBF ]
        , reads "-_8=" [ 0xFB, 0xFF ]
        , reads "+/8" [ 0xFB, 0xFF ]
        , reads "AAAA" [ 0, 0, 0 ]
        , reads "////" [ 0xFF, 0xFF, 0xFF ]
        , reads "____" [ 0xFF, 0xFF, 0xFF ]
        , rejects "a"
        , rejects "a="
        , rejects "aGVsbG8hA"
        , rejects "a==="
        , rejects "aGk=="
        , rejects "aA="
        , rejects "aGVs="
        , rejects "aGVsbG8h===="
        , rejects "="
        , rejects "=="
        , rejects "aG=k"
        , rejects "aG k"
        , rejects " aGk"
        , rejects "aGk!"
        , rejects "+/-_"
        , rejects "aGkß"
        ]


toBase64Tests : Test
toBase64Tests =
    let
        writes ints text =
            test ("writes " ++ Debug.toString ints ++ " as \"" ++ text ++ "\"") <|
                \_ -> Proto.Bytes.toBase64 (fromList ints) |> Expect.equal text
    in
    describe "toBase64"
        [ writes [] ""
        , writes [ 0x68 ] "aA=="
        , writes [ 0x68, 0x69 ] "aGk="
        , writes [ 0x68, 0x69, 0x21 ] "aGkh"
        , writes [ 0xFB, 0xFF, 0xBF ] "+/+/"
        , writes [ 0, 0, 0, 0 ] "AAAAAA=="
        , test "empty holds no bytes" <|
            \_ -> Proto.Bytes.empty |> Bytes.width |> Expect.equal 0
        ]


byteList : Fuzzer (List Int)
byteList =
    Fuzz.list (Fuzz.intRange 0 255)


{-| Text over base64's characters, padding and a few others, most of it not
base64.
-}
base64ish : Fuzzer String
base64ish =
    Fuzz.list (Fuzz.oneOfValues [ 'A', 'g', 'Z', '0', '9', '+', '/', '-', '_', '=', ' ', '!', '.' ])
        |> Fuzz.map String.fromList


properties : Test
properties =
    let
        urlSafe =
            String.map
                (\char ->
                    case char of
                        '+' ->
                            '-'

                        '/' ->
                            '_'

                        other ->
                            other
                )

        unpadded =
            String.filter ((/=) '=')
    in
    describe "properties"
        [ test "every length from 0 to 100 round-trips" <|
            \_ ->
                List.range 0 100
                    |> List.filter
                        (\length ->
                            let
                                ints =
                                    List.map (\i -> modBy 256 (i * 37 + length)) (List.range 1 length)
                            in
                            Proto.Bytes.fromBase64 (Proto.Bytes.toBase64 (fromList ints)) |> Maybe.map toList |> (/=) (Just ints)
                        )
                    |> Expect.equal []
        , fuzz byteList "toBase64 writes padded standard base64" <|
            \ints -> Proto.Bytes.toBase64 (fromList ints) |> Expect.equal (Fuzzers.base64 ints)
        , fuzz byteList "every alphabet and padding reads back as the same bytes" <|
            \ints ->
                let
                    text =
                        Fuzzers.base64 ints
                in
                [ text, urlSafe text, unpadded text, unpadded (urlSafe text) ]
                    |> List.map (Proto.Bytes.fromBase64 >> Maybe.map toList)
                    |> Expect.equal (List.repeat 4 (Just ints))
        , fuzz base64ish "accepts what Proto.Json.bytes accepts, and nothing else" <|
            \text ->
                isJust (Proto.Bytes.fromBase64 text)
                    |> Expect.equal (isJust (Result.toMaybe (Json.Decode.decodeValue Proto.Json.bytes (Json.Encode.string text))))
        , fuzz byteList "a character outside base64 fails" <|
            \ints ->
                let
                    text =
                        unpadded (Fuzzers.base64 ints) ++ "!"
                in
                Proto.Bytes.fromBase64 text |> Maybe.map toList |> Expect.equal Nothing
        ]


isJust : Maybe a -> Bool
isJust maybe =
    case maybe of
        Just _ ->
            True

        Nothing ->
            False


largeTests : Test
largeTests =
    let
        size =
            1024 * 1024

        large =
            List.range 0 (size - 1)
                |> List.map (\i -> Bytes.Encode.unsignedInt8 (modBy 251 i))
                |> Bytes.Encode.sequence
                |> Bytes.Encode.encode
    in
    test "a megabyte round-trips" <|
        \_ ->
            let
                text =
                    Proto.Bytes.toBase64 large
            in
            Expect.all
                [ \_ -> String.length text |> Expect.equal (4 * ((size + 2) // 3))
                , \_ ->
                    Proto.Bytes.fromBase64 text
                        |> Maybe.map Proto.Bytes.toBase64
                        |> Expect.equal (Just text)
                ]
                ()


jsonTests : Test
jsonTests =
    let
        decoded json =
            Json.Decode.decodeString Proto.Json.bytesAsBytes json |> Result.map toList
    in
    describe "Proto.Json"
        [ test "bytesAsBytes reads base64" <|
            \_ -> decoded "\"aGk\"" |> Expect.equal (Ok [ 0x68, 0x69 ])
        , test "bytesAsBytes says why it fails" <|
            \_ ->
                Json.Decode.decodeString Proto.Json.bytesAsBytes "\"a\""
                    |> Result.mapError (Json.Decode.errorToString >> String.contains "Expecting base64 (standard or URL-safe, padding optional), but got \"a\"")
                    |> Result.map toList
                    |> Expect.equal (Err True)
        , test "bytesAsBytes fails on a number" <|
            \_ -> decoded "1" |> Result.toMaybe |> Expect.equal Nothing
        , test "encodeBytesAsBytes writes padded standard base64" <|
            \_ -> Proto.Json.encodeBytesAsBytes (fromList [ 0xFB, 0xFF ]) |> Json.Encode.encode 0 |> Expect.equal "\"+/8=\""
        , test "implicitBytesField leaves out no bytes" <|
            \_ -> Proto.Json.implicitBytesField Proto.Bytes.empty |> Maybe.map (Json.Encode.encode 0) |> Expect.equal Nothing
        , test "implicitBytesField writes any bytes" <|
            \_ -> Proto.Json.implicitBytesField (fromList [ 0 ]) |> Maybe.map (Json.Encode.encode 0) |> Expect.equal (Just "\"AA==\"")
        ]
