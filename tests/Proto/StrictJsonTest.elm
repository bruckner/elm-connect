module Proto.StrictJsonTest exposing (suite)

{-| Decoders generated under `json_unknown=reject` (the codec corpus's
`Strict` set) fail on a key that names no field of their message, and read
every key that does, under its JSON name or its proto name.
-}

import Expect
import Generated.Codec.Strict.Codec.V1 as Strict
import Json.Decode
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "json_unknown=reject"
        [ test "a key naming no field fails, at that key, naming the message" <|
            \_ ->
                Json.Decode.decodeString Strict.decodeLeaf """{"name":"a","zzz":1}"""
                    |> Result.mapError Json.Decode.errorToString
                    |> Expect.equal (Err "Problem with the value at json.zzz:\n\n    1\n\nExpecting only the fields of codec.v1.Leaf")
        , test "the fields' names read as before" <|
            \_ ->
                Json.Decode.decodeString Strict.decodeNames """{"plain":"a","twoWords":"b","overridden":"c"}"""
                    |> Result.map .twoWords
                    |> Expect.equal (Ok "b")
        , test "a proto name reads as before" <|
            \_ ->
                Json.Decode.decodeString Strict.decodeNames """{"two_words":"b","with_override":"c"}"""
                    |> Result.map .withOverride
                    |> Expect.equal (Ok "c")
        , test "a oneof member's key is a field's" <|
            \_ ->
                Json.Decode.decodeString Strict.decodeChoice """{"before":"x","text":"t"}"""
                    |> Result.map .before
                    |> Expect.equal (Ok "x")
        , test "a nested message's unknown key fails too" <|
            \_ ->
                Json.Decode.decodeString Strict.decodeOuter """{"inner":{"note":"n","extra":true}}"""
                    |> Result.toMaybe
                    |> Expect.equal Nothing
        , test "not an object fails as before" <|
            \_ ->
                Json.Decode.decodeString Strict.decodeLeaf "[]"
                    |> Result.toMaybe
                    |> Expect.equal Nothing
        ]
