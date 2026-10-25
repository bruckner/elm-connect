module Proto.BinaryTest exposing (suite)

{-| `Proto.Binary`: each wire type's bytes, as protobuf's encoding guide
and protoc write them, and a hand-written message codec in the generated
shape for what a message decoder does (field order, last wins, packed and
unpacked, maps, oneofs, unknown fields, groups, truncation).

Elm's `==` finds any two `Bytes` equal, so bytes are compared as hex.

-}

import Bytes exposing (Bytes)
import Bytes.Decode
import Bytes.Encode
import Dict exposing (Dict)
import Expect exposing (Expectation)
import Fuzz
import Json.Encode
import Proto.Any
import Proto.Binary as B
import Proto.Duration
import Proto.Json
import Proto.Message
import Proto.WellKnown
import Test exposing (Test, describe, fuzz, test)
import Time


suite : Test
suite =
    describe "Proto.Binary"
        [ varints
        , zigzag
        , fixed
        , floats
        , delimited
        , repeatedFields
        , maps
        , messages
        , wellKnown
        , properties
        ]



-- HEX


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
    String.fromList [ digit (b // 16), digit (modBy 16 b) ]


digit : Int -> Char
digit n =
    String.toList "0123456789abcdef" |> List.drop n |> List.head |> Maybe.withDefault '?'


fromHex : String -> Bytes
fromHex text =
    let
        value c =
            String.toList "0123456789abcdef" |> List.indexedMap Tuple.pair |> List.filter (\( _, d ) -> d == c) |> List.head |> Maybe.map Tuple.first |> Maybe.withDefault 0

        go chars acc =
            case chars of
                hi :: lo :: rest ->
                    go rest (Bytes.Encode.unsignedInt8 (value hi * 16 + value lo) :: acc)

                _ ->
                    List.reverse acc
    in
    Bytes.Encode.encode (Bytes.Encode.sequence (go (String.toList (String.replace " " "" text)) []))


{-| A one-field message whose field 1 is of `codec`, as generated code
writes it.
-}
single : B.Codec a -> a -> { encode : a -> Bytes.Encode.Encoder, decode : B.Decoder a }
single codec zero =
    { encode = B.present codec 1
    , decode =
        B.merge
            (\number wireType current ->
                if number == 1 then
                    B.field codec identity wireType current

                else
                    B.skip wireType current
            )
            identity
            zero
    }


{-| `value` as field 1 of `codec` writes `hex`, and `hex` reads back as
`value`, compared by `show`.
-}
wire : B.Codec a -> a -> (a -> String) -> a -> String -> Expectation
wire codec zero show value hex =
    let
        one =
            single codec zero
    in
    Expect.all
        [ \_ -> toHex (B.encode one.encode value) |> Expect.equal (String.replace " " "" hex)
        , \_ -> B.decode one.decode (fromHex hex) |> Maybe.map show |> Expect.equal (Just (show value))
        ]
        ()


reads : B.Codec a -> a -> (a -> String) -> String -> Maybe String -> Expectation
reads codec zero show hex expected =
    B.decode (single codec zero).decode (fromHex hex) |> Maybe.map show |> Expect.equal expected



-- VARINTS


varints : Test
varints =
    describe "varints"
        [ test "int32 0, 1, 150, 300" <|
            \_ ->
                Expect.all
                    [ \_ -> wire B.int32 0 String.fromInt 0 "0800"
                    , \_ -> wire B.int32 0 String.fromInt 1 "0801"
                    , \_ -> wire B.int32 0 String.fromInt 150 "089601"
                    , \_ -> wire B.int32 0 String.fromInt 300 "08ac02"
                    ]
                    ()
        , test "a negative int32 is ten bytes, sign-extended" <|
            \_ ->
                Expect.all
                    [ \_ -> wire B.int32 0 String.fromInt -1 "08 ffffffffffffffffff01"
                    , \_ -> wire B.int32 0 String.fromInt -2147483648 "08 80808080f8ffffffff01"
                    ]
                    ()
        , test "an int32 read from five bytes, as some writers send it" <|
            \_ -> reads B.int32 0 String.fromInt "08ffffffff0f" (Just "-1")
        , test "uint32 to 2^32 - 1" <|
            \_ ->
                Expect.all
                    [ \_ -> wire B.uint32 0 String.fromInt 4294967295 "08ffffffff0f"
                    , \_ -> wire B.uint32 0 String.fromInt 2147483648 "088080808008"
                    ]
                    ()
        , test "int64 at its bounds and past 2^53, as text" <|
            \_ ->
                Expect.all
                    [ \_ -> wire B.int64 "0" identity "9223372036854775807" "08 ffffffffffffffff7f"
                    , \_ -> wire B.int64 "0" identity "-9223372036854775808" "08 80808080808080808001"
                    , \_ -> wire B.int64 "0" identity "-1" "08 ffffffffffffffffff01"
                    , \_ -> wire B.int64 "0" identity "9007199254740993" "08 8180808080808010"
                    , \_ -> wire B.int64 "0" identity "4294967296" "08 8080808010"
                    , \_ -> wire B.int64 "0" identity "-4294967296" "08 80808080f0ffffffff01"
                    ]
                    ()
        , test "uint64 to 2^64 - 1" <|
            \_ ->
                Expect.all
                    [ \_ -> wire B.uint64 "0" identity "18446744073709551615" "08 ffffffffffffffffff01"
                    , \_ -> wire B.uint64 "0" identity "9223372036854775808" "08 80808080808080808001"
                    , \_ -> wire B.uint64 "0" identity "12345678901234567890" "08 d295fcd8ceb1aaaaab01"
                    ]
                    ()
        , test "int64 as an Int within ±(2^53 - 1), failing past it" <|
            \_ ->
                Expect.all
                    [ \_ -> wire B.int64AsInt 0 String.fromInt 9007199254740991 "08 ffffffffffffff0f"
                    , \_ -> wire B.int64AsInt 0 String.fromInt -9007199254740991 "08 81808080808080f0ff01"
                    , \_ -> reads B.int64AsInt 0 String.fromInt "08 8080808080808010" Nothing
                    , \_ -> reads B.int64AsInt 0 String.fromInt "08 80808080808080f0ff01" Nothing
                    , \_ -> reads B.uint64AsInt 0 String.fromInt "08 ffffffffffffffffff01" Nothing
                    ]
                    ()
        , test "bool, any non-zero varint reading true" <|
            \_ ->
                Expect.all
                    [ \_ -> wire B.bool False boolText True "0801"
                    , \_ -> reads B.bool False boolText "0802" (Just "True")
                    , \_ -> reads B.bool False boolText "08 80808080808080808001" (Just "True")
                    ]
                    ()
        , test "a varint longer than ten bytes fails" <|
            \_ -> reads B.uint64 "0" identity "08 ffffffffffffffffffff01" Nothing
        ]


boolText : Bool -> String
boolText b =
    if b then
        "True"

    else
        "False"



-- ZIGZAG


zigzag : Test
zigzag =
    describe "zigzag"
        [ test "sint32" <|
            \_ ->
                Expect.all
                    [ \_ -> wire B.sint32 0 String.fromInt 0 "0800"
                    , \_ -> wire B.sint32 0 String.fromInt -1 "0801"
                    , \_ -> wire B.sint32 0 String.fromInt 1 "0802"
                    , \_ -> wire B.sint32 0 String.fromInt -2 "0803"
                    , \_ -> wire B.sint32 0 String.fromInt 2147483647 "08feffffff0f"
                    , \_ -> wire B.sint32 0 String.fromInt -2147483648 "08ffffffff0f"
                    ]
                    ()
        , test "sint64" <|
            \_ ->
                Expect.all
                    [ \_ -> wire B.sint64 "0" identity "-1" "0801"
                    , \_ -> wire B.sint64 "0" identity "1" "0802"
                    , \_ -> wire B.sint64 "0" identity "-2147483649" "08 8180808010"
                    , \_ -> wire B.sint64 "0" identity "9223372036854775807" "08 feffffffffffffffff01"
                    , \_ -> wire B.sint64 "0" identity "-9223372036854775808" "08 ffffffffffffffffff01"
                    , \_ -> wire B.sint64AsInt 0 String.fromInt -9007199254740991 "08 fdffffffffffff1f"
                    ]
                    ()
        ]



-- FIXED


fixed : Test
fixed =
    describe "fixed32 and fixed64"
        [ test "fixed32 and sfixed32, little-endian" <|
            \_ ->
                Expect.all
                    [ \_ -> wire B.fixed32 0 String.fromInt 4294967295 "0d ffffffff"
                    , \_ -> wire B.fixed32 0 String.fromInt 1 "0d 01000000"
                    , \_ -> wire B.sfixed32 0 String.fromInt -2 "0d feffffff"
                    ]
                    ()
        , test "fixed64 and sfixed64" <|
            \_ ->
                Expect.all
                    [ \_ -> wire B.fixed64 "0" identity "18446744073709551615" "09 ffffffffffffffff"
                    , \_ -> wire B.fixed64 "0" identity "4294967296" "09 0000000001000000"
                    , \_ -> wire B.sfixed64 "0" identity "-9223372036854775808" "09 0000000000000080"
                    , \_ -> wire B.sfixed64 "0" identity "-1" "09 ffffffffffffffff"
                    , \_ -> wire B.sfixed64AsInt 0 String.fromInt -2 "09 feffffffffffffff"
                    , \_ -> wire B.fixed64AsInt 0 String.fromInt 9007199254740991 "09 ffffffffffff1f00"
                    ]
                    ()
        ]



-- FLOATS


floatText : Float -> String
floatText x =
    if isNaN x then
        "NaN"

    else if x == 0 && 1 / x < 0 then
        "-0"

    else
        String.fromFloat x


{-| elm-format writes a literal `-0` as `0`.
-}
negativeZero : Float
negativeZero =
    -1 / (1 / 0)


floats : Test
floats =
    describe "float and double"
        [ test "double, NaN, the infinities and -0 by their bits" <|
            \_ ->
                Expect.all
                    [ \_ -> wire B.double 0 floatText 1.5 "09 000000000000f83f"
                    , \_ -> wire B.double 0 floatText (0 / 0) "09 000000000000f87f"
                    , \_ -> wire B.double 0 floatText (1 / 0) "09 000000000000f07f"
                    , \_ -> wire B.double 0 floatText (-1 / 0) "09 000000000000f0ff"
                    , \_ -> wire B.double 0 floatText negativeZero "09 0000000000000080"
                    ]
                    ()
        , test "float, four bytes" <|
            \_ ->
                Expect.all
                    [ \_ -> wire B.float 0 floatText 1.5 "0d 0000c03f"
                    , \_ -> wire B.float 0 floatText (0 / 0) "0d 0000c07f"
                    , \_ -> wire B.float 0 floatText (-1 / 0) "0d 000080ff"
                    ]
                    ()
        , test "an implicit float is left out at 0 and -0, written at NaN" <|
            \_ ->
                Expect.all
                    [ \_ -> toHex (B.encode (B.implicit B.double 1) 0) |> Expect.equal ""
                    , \_ -> toHex (B.encode (B.implicit B.double 1) negativeZero) |> Expect.equal ""
                    , \_ -> toHex (B.encode (B.implicit B.double 1) (0 / 0)) |> Expect.equal "09000000000000f87f"
                    , \_ -> toHex (B.encode (B.implicit B.float 1) (0 / 0)) |> Expect.equal "0d0000c07f"
                    ]
                    ()
        ]



-- LENGTH-DELIMITED


delimited : Test
delimited =
    describe "length-delimited"
        [ test "a string, UTF-8" <|
            \_ ->
                Expect.all
                    [ \_ -> wire B.string "" identity "testing" "0a 07 74657374696e67"
                    , \_ -> wire B.string "" identity "é😀" "0a 06 c3a9f09f9880"
                    , \_ -> wire B.string "" identity "" "0a 00"
                    ]
                    ()
        , test "bytes, as base64 text and as Bytes" <|
            \_ ->
                Expect.all
                    [ \_ -> wire B.bytes "" identity "+/8=" "0a 02 fbff"
                    , \_ -> reads B.bytesAsBytes (Bytes.Encode.encode (Bytes.Encode.sequence [])) toHex "0a 03 fbff00" (Just "fbff00")
                    ]
                    ()
        , test "a string whose length runs past the input fails" <|
            \_ -> reads B.string "" identity "0a 08 74657374696e67" Nothing
        , test "a nested message, length-prefixed" <|
            \_ ->
                -- Message { 3: Leaf { 1: 150 } }, from the encoding guide.
                toHex (B.encode encodeSample { sampleDefault | leaf = Just { leafDefault | count = 150 } })
                    |> Expect.equal "1a03089601"
        , test "a field of the wrong wire type is skipped, as an unknown field" <|
            \_ -> reads B.string "" identity "08 01" (Just "")
        ]



-- A MESSAGE IN THE GENERATED SHAPE


type alias Sample =
    { number : Int
    , name : String
    , leaf : Maybe Leaf
    , counts : List Int
    , names : List String
    , table : Dict String Int
    , flags : List ( Bool, String )
    , pick : Pick
    }


type alias Leaf =
    { count : Int
    , marks : List Int
    }


leafDefault : Leaf
leafDefault =
    { count = 0, marks = [] }


type Pick
    = PickUnset
    | PickText String
    | PickBig String
    | PickNothing


sampleDefault : Sample
sampleDefault =
    { number = 0, name = "", leaf = Nothing, counts = [], names = [], table = Dict.empty, flags = [], pick = PickUnset }


encodeLeaf : Leaf -> Bytes.Encode.Encoder
encodeLeaf value =
    Bytes.Encode.sequence [ B.implicit B.int32 1 value.count, B.list B.int32 2 value.marks ]


mergeLeaf : Leaf -> B.Decoder Leaf
mergeLeaf =
    B.merge
        (\number wireType value ->
            case number of
                1 ->
                    B.field B.int32 (\v -> { value | count = v }) wireType value

                2 ->
                    B.repeated B.int32 (\v -> { value | marks = v }) value.marks wireType value

                _ ->
                    B.skip wireType value
        )
        (\value -> { value | marks = List.reverse value.marks })


encodeSample : Sample -> Bytes.Encode.Encoder
encodeSample value =
    Bytes.Encode.sequence
        [ B.implicit B.int32 1 value.number
        , B.implicit B.string 2 value.name
        , B.optional (B.embedded encodeLeaf mergeLeaf leafDefault) 3 value.leaf
        , B.list B.int32 4 value.counts
        , B.list B.string 5 value.names
        , B.dict B.string B.int32 6 value.table
        , B.boolMap B.string 7 value.flags
        , encodePick value.pick
        ]


encodePick : Pick -> Bytes.Encode.Encoder
encodePick pick =
    case pick of
        PickUnset ->
            Bytes.Encode.sequence []

        PickText member ->
            B.present B.string 8 member

        PickBig member ->
            B.present B.int64 9 member

        PickNothing ->
            B.present B.empty 10 ()


decodeSample : B.Decoder Sample
decodeSample =
    B.merge
        (\number wireType value ->
            case number of
                1 ->
                    B.field B.int32 (\v -> { value | number = v }) wireType value

                2 ->
                    B.field B.string (\v -> { value | name = v }) wireType value

                3 ->
                    B.fieldInto (B.embedded encodeLeaf mergeLeaf leafDefault) value.leaf (\v -> { value | leaf = Just v }) wireType value

                4 ->
                    B.repeated B.int32 (\v -> { value | counts = v }) value.counts wireType value

                5 ->
                    B.repeated B.string (\v -> { value | names = v }) value.names wireType value

                6 ->
                    B.mapEntry B.string B.int32 (\k v -> { value | table = Dict.insert k v value.table }) wireType value

                7 ->
                    B.mapEntry B.bool B.string (\k v -> { value | flags = B.insertBool k v value.flags }) wireType value

                8 ->
                    B.field B.string (\v -> { value | pick = PickText v }) wireType value

                9 ->
                    B.field B.int64 (\v -> { value | pick = PickBig v }) wireType value

                10 ->
                    B.field B.empty (\_ -> { value | pick = PickNothing }) wireType value

                _ ->
                    B.skip wireType value
        )
        (\value -> { value | counts = List.reverse value.counts, names = List.reverse value.names, flags = List.reverse value.flags })
        sampleDefault


showSample : Sample -> String
showSample s =
    String.join " | "
        [ String.fromInt s.number
        , s.name
        , Maybe.withDefault "-" (Maybe.map (\leaf -> String.fromInt leaf.count ++ "/" ++ String.join "," (List.map String.fromInt leaf.marks)) s.leaf)
        , String.join "," (List.map String.fromInt s.counts)
        , String.join "," s.names
        , String.join "," (List.map (\( k, v ) -> k ++ "=" ++ String.fromInt v) (Dict.toList s.table))
        , String.join "," (List.map (\( k, v ) -> boolText k ++ "=" ++ v) s.flags)
        , case s.pick of
            PickUnset ->
                "unset"

            PickText t ->
                "text " ++ t

            PickBig b ->
                "big " ++ b

            PickNothing ->
                "nothing"
        ]


decodesAs : String -> Sample -> Expectation
decodesAs hex expected =
    B.decode decodeSample (fromHex hex) |> Maybe.map showSample |> Expect.equal (Just (showSample expected))


repeatedFields : Test
repeatedFields =
    describe "repeated fields"
        [ test "scalars are written packed" <|
            \_ ->
                toHex (B.encode encodeSample { sampleDefault | counts = [ 3, 270, 86942 ] })
                    |> Expect.equal "2206038e029ea705"
        , test "packed and unpacked both read, and accumulate in order" <|
            \_ -> decodesAs "2203038e02 209ea705 2001" { sampleDefault | counts = [ 3, 270, 86942, 1 ] }
        , test "strings and messages are one field per element" <|
            \_ ->
                toHex (B.encode encodeSample { sampleDefault | names = [ "a", "", "b" ] })
                    |> Expect.equal "2a01612a002a0162"
        , test "listUnpacked writes one field key per element, where list packs them" <|
            \_ ->
                ( toHex (B.encode (B.listUnpacked B.int32 1) [ 1, 2 ])
                , toHex (B.encode (B.list B.int32 1) [ 1, 2 ])
                , toHex (B.encode (B.listUnpacked B.int32 1) [])
                )
                    |> Expect.equal ( "08010802", "0a020102", "" )
        , test "an empty list is left out" <|
            \_ -> toHex (B.encode encodeSample sampleDefault) |> Expect.equal ""
        , test "a packed run whose elements overrun its length fails" <|
            \_ -> B.decode decodeSample (fromHex "2201ac02") |> Expect.equal Nothing
        ]


maps : Test
maps =
    describe "maps"
        [ test "entries in key order, defaults inside an entry left out" <|
            \_ ->
                toHex (B.encode encodeSample { sampleDefault | table = Dict.fromList [ ( "b", 2 ), ( "", 1 ), ( "a", 0 ) ] })
                    |> Expect.equal "3202100132030a016132050a01621002"
        , test "an entry missing its key or value reads them as defaults; a later key wins" <|
            \_ -> decodesAs "3200 32030a0161 32050a01611005" { sampleDefault | table = Dict.fromList [ ( "", 0 ), ( "a", 5 ) ] }
        , test "an entry's fields in either order, and unknown ones skipped" <|
            \_ -> decodesAs "3207 1007 1801 0a0163" { sampleDefault | table = Dict.fromList [ ( "c", 7 ) ] }
        , test "a bool-keyed map writes its False entry first" <|
            \_ ->
                toHex (B.encode encodeSample { sampleDefault | flags = [ ( True, "t" ), ( False, "f" ) ] })
                    |> Expect.equal "3a031201663a050801120174"
        ]


messages : Test
messages =
    describe "messages"
        [ test "fields in number order, defaults left out" <|
            \_ ->
                toHex (B.encode encodeSample { sampleDefault | number = 150, name = "x", pick = PickText "" })
                    |> Expect.equal "0896011201784200"
        , test "fields read in any order" <|
            \_ -> decodesAs "120178 089601" { sampleDefault | number = 150, name = "x" }
        , test "the last of a repeated singular field wins" <|
            \_ -> decodesAs "0801 0802 0803" { sampleDefault | number = 3 }
        , test "a message field arriving twice is merged: scalars the last, lists joined" <|
            \_ -> decodesAs "1a05 0801 120101 1a03 120103 1a00" { sampleDefault | leaf = Just { count = 1, marks = [ 1, 3 ] } }
        , test "a message field read after another is merged into it, a later scalar winning" <|
            \_ -> decodesAs "1a02 0805 1a02 0807" { sampleDefault | leaf = Just { count = 7, marks = [] } }
        , test "a field of a wire type its declaration does not take is skipped" <|
            \_ ->
                Expect.all
                    [ \_ -> decodesAs "0d01020304 1201 78" { sampleDefault | name = "x" }
                    , \_ -> decodesAs "0802 0a020304" { sampleDefault | number = 2 }
                    , \_ -> decodesAs "3207 0d61626364 1005" { sampleDefault | table = Dict.fromList [ ( "", 5 ) ] }
                    ]
                    ()
        , test "a bool-keyed map's later entry for a key replaces the earlier" <|
            \_ -> decodesAs "3a05 0801 120161 3a05 0801 120162" { sampleDefault | flags = [ ( True, "b" ) ] }
        , test "the last oneof member wins" <|
            \_ -> decodesAs "4201 61 4801 5200 4202 6263" { sampleDefault | pick = PickText "bc" }
        , test "an Empty member is written, and reads as set" <|
            \_ ->
                Expect.all
                    [ \_ -> toHex (B.encode encodeSample { sampleDefault | pick = PickNothing }) |> Expect.equal "5200"
                    , \_ -> decodesAs "5200" { sampleDefault | pick = PickNothing }
                    ]
                    ()
        , test "unknown fields of every wire type are skipped" <|
            \_ ->
                decodesAs "f80601 f906 0102030405060708 fa0603 616263 fd06 01020304 0801"
                    { sampleDefault | number = 1 }
        , test "a group fails" <|
            \_ ->
                Expect.all
                    [ \_ -> B.decode decodeSample (fromHex "fb06 fc06") |> Expect.equal Nothing
                    , \_ -> B.decode decodeSample (fromHex "fc06") |> Expect.equal Nothing
                    ]
                    ()
        , test "field number zero fails" <|
            \_ -> B.decode decodeSample (fromHex "0001") |> Expect.equal Nothing
        , test "the empty message is no bytes, and no bytes read as the default" <|
            \_ ->
                Expect.all
                    [ \_ -> toHex (B.encode encodeSample sampleDefault) |> Expect.equal ""
                    , \_ -> decodesAs "" sampleDefault
                    ]
                    ()
        , test "truncated input fails: in a key, a varint, a length, a fixed value" <|
            \_ ->
                Expect.all
                    (List.map (\hex -> \_ -> B.decode decodeSample (fromHex hex) |> Expect.equal Nothing)
                        [ "f8", "0896", "12", "1205 7878", "1a03 0896", "f906 0102" ]
                    )
                    ()
        , test "a nested message whose length runs past its parent's fails" <|
            \_ -> B.decode decodeSample (fromHex "1a05089601") |> Expect.equal Nothing
        ]



-- WELL-KNOWN TYPES


wellKnown : Test
wellKnown =
    describe "well-known types"
        [ test "Timestamp, to the millisecond, nanoseconds past it dropped" <|
            \_ ->
                Expect.all
                    [ \_ -> wire B.timestamp (Time.millisToPosix 0) posixText (Time.millisToPosix 1500) "0a08 0801 1080cab5ee01"
                    , \_ -> wire B.timestamp (Time.millisToPosix 0) posixText (Time.millisToPosix -1) "0a11 08ffffffffffffffffff01 10c08faedc03"
                    , \_ -> reads B.timestamp (Time.millisToPosix 0) posixText "0a08 0801 1081cab5ee01" (Just "1500")
                    , \_ -> wire B.timestamp (Time.millisToPosix 0) posixText (Time.millisToPosix 0) "0a00"
                    ]
                    ()
        , test "Duration, exact, both parts signed" <|
            \_ ->
                Expect.all
                    [ \_ -> wire B.duration (Proto.Duration.fromParts 0 0) Proto.Duration.toString (Proto.Duration.fromParts -1 -500000000) "0a16 08ffffffffffffffffff01 1080b6ca91feffffffff01"
                    , \_ -> reads B.duration (Proto.Duration.fromParts 0 0) Proto.Duration.toString "0a08 0801 1080cab5ee01" (Just "1.500s")
                    , \_ -> reads B.duration (Proto.Duration.fromParts 0 0) Proto.Duration.toString "0a06 1081cab5ee01" (Just "0.500000001s")
                    ]
                    ()
        , test "Value, Struct and ListValue as JSON, an object's members in key order" <|
            \_ ->
                let
                    json =
                        Json.Encode.object
                            [ ( "b", Json.Encode.list identity [ Json.Encode.null, Json.Encode.bool True ] )
                            , ( "a", Json.Encode.float 1.5 )
                            , ( "c", Json.Encode.string "x" )
                            ]
                in
                Expect.all
                    [ \_ -> toHex (B.encode (B.present B.value 1) json) |> Expect.equal "0a2d2a2b0a0e0a0161120911000000000000f83f0a0f0a0162120a32080a0208000a0220010a080a016312031a0178"
                    , \_ -> reads B.value Json.Encode.null (Json.Encode.encode 0) "0a2d2a2b0a0e0a0161120911000000000000f83f0a0f0a0162120a32080a0208000a0220010a080a016312031a0178" (Just """{"a":1.5,"b":[null,true],"c":"x"}""")
                    , \_ -> reads B.value Json.Encode.null (Json.Encode.encode 0) "0a00" (Just "null")
                    ]
                    ()
        , test "Any holds the packed message's binary, and writes it back" <|
            \_ ->
                let
                    one =
                        single B.any (Proto.Message.default Proto.WellKnown.any)

                    hex =
                        "0a0d0a07612f622e632e4412020801"

                    decoded =
                        B.decode one.decode (fromHex hex)
                in
                Expect.all
                    [ \_ -> decoded |> Maybe.map anyText |> Expect.equal (Just """{"type":"b.c.D","value":"CAE="}""")
                    , \_ -> decoded |> Maybe.map (toHex << B.encode one.encode) |> Expect.equal (Just hex)
                    ]
                    ()
        , test "a wrapper writes its value's default as an empty message" <|
            \_ ->
                Expect.all
                    [ \_ -> toHex (B.encode (B.present B.int32Value 1) 0) |> Expect.equal "0a00"
                    , \_ -> wire B.int64Value "0" identity "-1" "0a0b 08ffffffffffffffffff01"
                    , \_ -> reads B.int64Value "0" identity "0a00" (Just "0")
                    ]
                    ()
        , test "a field mask's paths" <|
            \_ -> wire B.fieldMask [] (String.join ",") [ "a.b_c", "d" ] "0a0a 0a05612e625f63 0a0164"
        ]


posixText : Time.Posix -> String
posixText =
    String.fromInt << Time.posixToMillis


anyText : Proto.Any.Any -> String
anyText =
    Json.Encode.encode 0 << Proto.Json.encodeAny



-- PROPERTIES


properties : Test
properties =
    describe "round trips"
        [ fuzz (Fuzz.intRange -2147483648 2147483647) "int32, sint32, sfixed32" <|
            \n ->
                Expect.all
                    [ \_ -> roundTrip B.int32 0 String.fromInt n
                    , \_ -> roundTrip B.sint32 0 String.fromInt n
                    , \_ -> roundTrip B.sfixed32 0 String.fromInt n
                    ]
                    ()
        , fuzz (Fuzz.intRange 0 4294967295) "uint32, fixed32" <|
            \n ->
                Expect.all
                    [ \_ -> roundTrip B.uint32 0 String.fromInt n
                    , \_ -> roundTrip B.fixed32 0 String.fromInt n
                    ]
                    ()
        , fuzz (Fuzz.intRange -9007199254740991 9007199254740991) "64-bit as Int, and as text" <|
            \n ->
                Expect.all
                    [ \_ -> roundTrip B.int64AsInt 0 String.fromInt n
                    , \_ -> roundTrip B.sint64AsInt 0 String.fromInt n
                    , \_ -> roundTrip B.sfixed64AsInt 0 String.fromInt n
                    , \_ -> roundTrip B.int64 "0" identity (String.fromInt n)
                    , \_ -> roundTrip B.sint64 "0" identity (String.fromInt n)
                    , \_ -> roundTrip B.sfixed64 "0" identity (String.fromInt n)
                    , \_ ->
                        B.decode (single B.int64 "0").decode (B.encode (single B.int64AsInt 0).encode n)
                            |> Expect.equal (Just (String.fromInt n))
                    ]
                    ()
        , fuzz (Fuzz.map2 Tuple.pair (Fuzz.intRange 1 92233) (Fuzz.intRange 0 99999999999999)) "64-bit text past 2^53" <|
            \( high, low ) ->
                let
                    text =
                        String.fromInt high ++ String.padLeft 14 '0' (String.fromInt low)
                in
                Expect.all
                    [ \_ -> roundTrip B.int64 "0" identity text
                    , \_ -> roundTrip B.int64 "0" identity ("-" ++ text)
                    , \_ -> roundTrip B.uint64 "0" identity text
                    , \_ -> roundTrip B.fixed64 "0" identity text
                    , \_ -> roundTrip B.sint64 "0" identity ("-" ++ text)
                    ]
                    ()
        , fuzz Fuzz.niceFloat "double" <|
            \x -> roundTrip B.double 0 floatText x
        , fuzz Fuzz.string "string" <|
            \s -> roundTrip B.string "" identity s
        ]


roundTrip : B.Codec a -> a -> (a -> String) -> a -> Expectation
roundTrip codec zero show v =
    let
        one =
            single codec zero
    in
    B.decode one.decode (B.encode one.encode v) |> Maybe.map show |> Expect.equal (Just (show v))
