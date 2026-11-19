module Proto.UnknownFieldsTest exposing (suite)

{-| Messages generated under `unknown_fields=keep` (the codec corpus's `Keep`
set) keep the fields their schema does not know: read from binary and
written back, merged, compared with `==`, and left out of proto3 JSON.
-}

import Bytes.Encode
import Codec.BinaryRoundTrip exposing (fromHex, toHex)
import Expect
import Generated.Codec.Keep.Codec.V1 as Keep
import Json.Decode
import Json.Encode
import Proto.Binary
import Proto.Unknown
import Test exposing (Test, describe, test)


leaf : String -> Result String Keep.Leaf
leaf hex =
    Proto.Binary.decode Keep.decodeLeafBytes (fromHex hex) |> Result.mapError (\_ -> "does not decode")


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
            \_ -> rewritten Keep.decodeLeafBytes Keep.encodeLeafBytes ("0a0161" ++ "1805" ++ "1007") |> Expect.equal (Ok ("0a0161" ++ "1007" ++ "1805"))
        , test "they are written by field number, in arrival order within one" <|
            \_ ->
                rewritten Keep.decodeLeafBytes Keep.encodeLeafBytes ("2d01020304" ++ "1802" ++ "2201ff" ++ "1801")
                    |> Expect.equal (Ok ("1802" ++ "1801" ++ "2201ff" ++ "2d01020304"))
        , test "a message built in Elm holds none" <|
            \_ -> Proto.Unknown.isEmpty Keep.defaultLeaf.unknownFields_ |> Expect.equal True
        , test "a known field of a wire type it does not take is kept as unknown" <|
            \_ -> rewritten Keep.decodeLeafBytes Keep.encodeLeafBytes "1201ff" |> Expect.equal (Ok "1201ff")
        , test "a message field read twice keeps both occurrences' unknown fields" <|
            \_ ->
                rewritten Keep.decodeOuterBytes Keep.encodeOuterBytes ("12021805" ++ "12021806")
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
            , test "an overlong varint: not equal to the shortest, as protobuf-go compares bytes" <|
                \_ -> same "1801" "188100" |> Expect.equal (Ok False)
            , test "a nested unknown message whose fields are reordered: not equal" <|
                \_ -> same ("2204" ++ "0801" ++ "1002") ("2204" ++ "1002" ++ "0801") |> Expect.equal (Ok False)
            , test "packed against unpacked: not equal" <|
                \_ -> same "22020102" ("2001" ++ "2002") |> Expect.equal (Ok False)
            ]
        , test "proto3 JSON leaves them out" <|
            \_ ->
                leaf "0a01611805"
                    |> Result.map (Keep.encodeLeaf >> Json.Encode.encode 0)
                    |> Expect.equal (Ok "{\"name\":\"a\"}")
        , test "proto3 JSON reads none" <|
            \_ ->
                Json.Decode.decodeString Keep.decodeLeaf "{\"name\":\"a\",\"zzz\":1}"
                    |> Result.map (.unknownFields_ >> Proto.Unknown.isEmpty)
                    |> Expect.equal (Ok True)
        ]
