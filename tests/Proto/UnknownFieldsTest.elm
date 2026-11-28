module Proto.UnknownFieldsTest exposing (suite)

{-| Messages generated under `unknown_fields=keep` (the codec corpus's `Keep`
set) keep the fields their schema does not know: read from binary and
written back, merged, compared with `==`, and left out of proto3 JSON.
-}

import Bytes.Encode
import Expect
import Generated.Codec.Keep.Codec.V1 as Keep
import Json.Decode
import Json.Encode
import Octets exposing (fromHex, toHex)
import Proto.Binary
import Proto.Json
import Proto.Unknown exposing (Value(..))
import Test exposing (Test, describe, test)


leaf : String -> Result String Keep.Leaf
leaf hex =
    Proto.Binary.decode Keep.decodeLeafBinary (fromHex hex) |> Result.mapError (\_ -> "does not decode")


rewritten : Proto.Binary.Decoder a -> (a -> Bytes.Encode.Encoder) -> String -> Result String String
rewritten decoder encoder hex =
    Proto.Binary.decode decoder (fromHex hex)
        |> Result.map (Proto.Binary.encode encoder >> toHex)
        |> Result.mapError (\_ -> "does not decode")


{-| Whether two inputs read as `==` leaves.
-}
same : String -> String -> Result String Bool
same a b =
    Result.map2 (==) (leaf a) (leaf b)


suite : Test
suite =
    describe "unknown_fields=keep"
        [ test "a message read and written back keeps them, after the known fields" <|
            \_ -> rewritten Keep.decodeLeafBinary Keep.encodeLeafBinary ("0a0161" ++ "1805" ++ "1007") |> Expect.equal (Ok ("0a0161" ++ "1007" ++ "1805"))
        , test "they are written by field number, in arrival order within one" <|
            \_ ->
                rewritten Keep.decodeLeafBinary Keep.encodeLeafBinary ("2d01020304" ++ "1802" ++ "2201ff" ++ "1801")
                    |> Expect.equal (Ok ("1802" ++ "1801" ++ "2201ff" ++ "2d01020304"))
        , test "they are held as data" <|
            \_ ->
                leaf ("1805" ++ "2203616263" ++ "2d01000000" ++ "310100000002000000" ++ "18ffffffffffffffffff01")
                    |> Result.map (.unknownFields_ >> Proto.Unknown.toList)
                    |> Expect.equal
                        (Ok
                            [ ( 3, Varint 0 5 )
                            , ( 3, Varint 4294967295 4294967295 )
                            , ( 4, Delimited "YWJj" )
                            , ( 5, Fixed32 1 )
                            , ( 6, Fixed64 2 1 )
                            ]
                        )
        , test "a message built in Elm holds none" <|
            \_ -> Keep.defaultLeaf.unknownFields_ |> Expect.equal Proto.Unknown.empty
        , test "a message read with none holds none" <|
            \_ -> leaf "0a0161" |> Result.map .unknownFields_ |> Expect.equal (Ok Proto.Unknown.empty)
        , test "a message read into one holding some keeps those first within a number" <|
            \_ ->
                let
                    held =
                        { name = "", count = 0, unknownFields_ = Proto.Unknown.fromList [ ( 5, Fixed32 7 ), ( 3, Varint 0 9 ) ] }
                in
                Proto.Binary.decode (Keep.mergeLeafBinary held) (fromHex ("1801" ++ "2201ff" ++ "1802"))
                    |> Result.map (.unknownFields_ >> Proto.Unknown.toList)
                    |> Expect.equal (Ok [ ( 3, Varint 0 9 ), ( 3, Varint 0 1 ), ( 3, Varint 0 2 ), ( 4, Delimited "/w==" ), ( 5, Fixed32 7 ) ])
        , test "a known field of a wire type it does not take is kept as unknown" <|
            \_ ->
                leaf "1201ff"
                    |> Result.map (\l -> ( l.count, Proto.Unknown.toList l.unknownFields_ ))
                    |> Expect.equal (Ok ( 0, [ ( 2, Delimited "/w==" ) ] ))
        , test "a message field read twice keeps both occurrences' unknown fields" <|
            \_ ->
                rewritten Keep.decodeOuterBinary Keep.encodeOuterBinary ("12021805" ++ "12021806")
                    |> Expect.equal (Ok "120418051806")
        , describe "== on messages"
            [ test "differing only in an unknown field: not equal" <|
                \_ -> same "0a01611805" "0a01611806" |> Expect.equal (Ok False)
            , test "the same unknown fields: equal" <|
                \_ -> same "0a01611805" "18050a0161" |> Expect.equal (Ok True)
            , test "fields of different numbers in another order: equal" <|
                \_ -> same ("1805" ++ "2201ff") ("2201ff" ++ "1805") |> Expect.equal (Ok True)
            , test "fields of one number in another order: not equal" <|
                \_ -> same ("1801" ++ "1802") ("1802" ++ "1801") |> Expect.equal (Ok False)
            , test "an overlong varint: equal to the shortest" <|
                \_ -> same "1801" "188100" |> Expect.equal (Ok True)
            , test "a nested unknown message whose fields are reordered: not equal" <|
                \_ -> same ("2204" ++ "0801" ++ "1002") ("2204" ++ "1002" ++ "0801") |> Expect.equal (Ok False)
            , test "packed against unpacked: not equal" <|
                \_ -> same "22020102" ("2001" ++ "2002") |> Expect.equal (Ok False)
            ]
        , test "proto3 JSON leaves them out" <|
            \_ ->
                leaf "0a01611805"
                    |> Result.map (Keep.encodeLeaf >> Proto.Json.encode >> Result.map (Json.Encode.encode 0) >> Result.withDefault "")
                    |> Expect.equal (Ok "{\"name\":\"a\"}")
        , test "proto3 JSON reads none" <|
            \_ ->
                Json.Decode.decodeString Keep.decodeLeaf "{\"name\":\"a\",\"zzz\":1}"
                    |> Result.map .unknownFields_
                    |> Expect.equal (Ok Proto.Unknown.empty)
        , test "a message built with some writes them after its known fields" <|
            \_ ->
                Proto.Binary.encode Keep.encodeLeafBinary { name = "a", count = 0, unknownFields_ = Proto.Unknown.fromList [ ( 9, Fixed64 0 1 ), ( 3, Varint 1 0 ) ] }
                    |> toHex
                    |> Expect.equal ("0a0161" ++ "188080808010" ++ "490100000000000000")
        , test "fromList sorts by number, keeping the list's order within one" <|
            \_ ->
                Proto.Unknown.fromList [ ( 9, Fixed32 1 ), ( 3, Varint 0 2 ), ( 9, Fixed32 0 ) ]
                    |> Proto.Unknown.toList
                    |> Expect.equal [ ( 3, Varint 0 2 ), ( 9, Fixed32 1 ), ( 9, Fixed32 0 ) ]
        ]
