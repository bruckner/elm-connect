module Proto.BinaryCorpus exposing (Case, Expected(..), Seed(..), cases, input, seedHex)

{-| Binary inputs that fail to decode, and a few that decode, with the
report each failure must give: 359 inputs.

The inputs are mutations of three seed messages (`bench.v1.Envelope`,
`bench.v1.Plain`, `protobuf_test_messages.proto3.TestAllTypesProto3`):
truncations, every invalid wire type and field number 0 at every field,
varints longer than ten bytes, lengths past the enclosing message, cut keys,
packed runs and map entries, 64-bit integers an `Int` cannot hold, and
strings that are not UTF-8, at every depth the seeds reach. Each case is
held as an edit of its seed: its first `prefix` bytes, then `middle` (hex),
then its last `suffix` bytes.

Generated once, by a script that is not kept, from the binary-report
spikes' validation set: the 263 inputs of its `corpus.py`, each with the
report a separately written decoder (the reader that carries its failure)
gave for it, validated against a generic walker over the same bytes; and 96
inputs (`utf8cases.py`) whose `bench.v1.Plain.id` holds one byte sequence,
valid or not, as Python's strict UTF-8 decoder judges it. A failure's
expected report was not taken from the decoder these cases test.

-}

import Bytes exposing (Bytes)
import Bytes.Decode
import Bytes.Encode
import Proto.Error exposing (Reason(..))


type Seed
    = Envelope
    | Plain
    | AllTypes


type Expected
    = Decodes
    | Fails Reason (List ( String, Int )) Int


type alias Case =
    { seed : Seed
    , label : String
    , prefix : Int
    , middle : String
    , suffix : Int
    , expected : Expected
    }


{-| A seed message's bytes, as hex.
-}
seedHex : Seed -> String
seedHex seed =
    case seed of
        Envelope ->
            envelopeSeed

        Plain ->
            plainSeed

        AllTypes ->
            allTypesSeed


{-| A case's input, from its seed and its edit; `fromHex` turns hex into
bytes.
-}
input : (String -> Bytes) -> Case -> Bytes
input fromHex c =
    let
        seed =
            fromHex (seedHex c.seed)

        width =
            Bytes.width seed
    in
    Bytes.Encode.encode
        (Bytes.Encode.sequence
            [ Bytes.Encode.bytes (part 0 c.prefix seed)
            , Bytes.Encode.bytes (fromHex c.middle)
            , Bytes.Encode.bytes (part (width - c.suffix) c.suffix seed)
            ]
        )


part : Int -> Int -> Bytes -> Bytes
part skip take bytes =
    Bytes.Decode.decode (Bytes.Decode.map2 (\_ b -> b) (Bytes.Decode.bytes skip) (Bytes.Decode.bytes take)) bytes
        |> Maybe.withDefault bytes


envelopeSeed : String
envelopeSeed =
    "0a0e656e76656c6f7065732f303030311205696e626f781207737461727265641aed020a24747970652e676f6f676c65617069732e636f6d2f62656e63682e76312e5061796c6f616412c4020a2841206e6f74652061626f757420746865207765656b6c7920706c616e6e696e67206d656574696e6712f8014c6f72656d20697073756d20646f6c6f722073697420616d65742c20636f6e73656374657475722061646970697363696e6720656c69742c2073656420646f20656975736d6f642074656d706f7220696e6369646964756e74207574206c61626f726520657420646f6c6f7265206d61676e6120616c697175612e204c6f72656d20697073756d20646f6c6f722073697420616d65742c20636f6e73656374657475722061646970697363696e6720656c69742c2073656420646f20656975736d6f642074656d706f7220696e6369646964756e74207574206c61626f726520657420646f6c6f7265206d61676e6120616c697175612e201a08706c616e6e696e671a067765656b6c791a047465616d20959aef3a2801221f666f727761726465642066726f6d207468652073686172656420696e626f78"


plainSeed : String
plainSeed =
    "0a0e656e76656c6f7065732f303030311205696e626f781207737461727265641ac4020a2841206e6f74652061626f757420746865207765656b6c7920706c616e6e696e67206d656574696e6712f8014c6f72656d20697073756d20646f6c6f722073697420616d65742c20636f6e73656374657475722061646970697363696e6720656c69742c2073656420646f20656975736d6f642074656d706f7220696e6369646964756e74207574206c61626f726520657420646f6c6f7265206d61676e6120616c697175612e204c6f72656d20697073756d20646f6c6f722073697420616d65742c20636f6e73656374657475722061646970697363696e6720656c69742c2073656420646f20656975736d6f642074656d706f7220696e6369646964756e74207574206c61626f726520657420646f6c6f7265206d61676e6120616c697175612e201a08706c616e6e696e671a067765656b6c791a047465616d20959aef3a2801221f666f727761726465642066726f6d207468652073686172656420696e626f78"


allTypesSeed : String
allTypesSeed =
    "082a10fbffffffffffffffff0161000000000000f83f720568656c6c6f7a0300010292010d0807120908087205696e6e6572fa0110019601e0a712ffffffffffffffffff01e2020161e20202626282030208018203020802c203040801100ac2030408021014ba04070a016b12020805920518010000000000000002000000000000000300000000000000d20c020805ea120508901c1005f212080880e2cfaa06100082130a0a080a016b12031a01739213022001"


cases : List Case
cases =
    [ { seed = Envelope, label = "control: seed", prefix = 433, middle = "", suffix = 0, expected = Decodes }
    , { seed = Plain, label = "control: seed", prefix = 392, middle = "", suffix = 0, expected = Decodes }
    , { seed = AllTypes, label = "control: seed", prefix = 181, middle = "", suffix = 0, expected = Decodes }
    , { seed = Envelope, label = "truncated at 1 of 433", prefix = 1, middle = "", suffix = 0, expected = Fails Truncated [ ( "bench.v1.Envelope", 1 ) ] 1 }
    , { seed = Envelope, label = "truncated at 15 of 433", prefix = 15, middle = "", suffix = 0, expected = Fails Truncated [ ( "bench.v1.Envelope", 1 ) ] 1 }
    , { seed = Envelope, label = "truncated at 29 of 433", prefix = 29, middle = "", suffix = 0, expected = Fails Truncated [ ( "bench.v1.Envelope", 2 ) ] 24 }
    , { seed = Envelope, label = "truncated at 43 of 433", prefix = 43, middle = "", suffix = 0, expected = Fails Truncated [ ( "bench.v1.Envelope", 3 ) ] 33 }
    , { seed = Envelope, label = "truncated at 57 of 433", prefix = 57, middle = "", suffix = 0, expected = Fails Truncated [ ( "bench.v1.Envelope", 3 ) ] 33 }
    , { seed = Envelope, label = "truncated at 71 of 433", prefix = 71, middle = "", suffix = 0, expected = Fails Truncated [ ( "bench.v1.Envelope", 3 ) ] 33 }
    , { seed = Envelope, label = "truncated at 85 of 433", prefix = 85, middle = "", suffix = 0, expected = Fails Truncated [ ( "bench.v1.Envelope", 3 ) ] 33 }
    , { seed = Envelope, label = "truncated at 99 of 433", prefix = 99, middle = "", suffix = 0, expected = Fails Truncated [ ( "bench.v1.Envelope", 3 ) ] 33 }
    , { seed = Envelope, label = "truncated at 113 of 433", prefix = 113, middle = "", suffix = 0, expected = Fails Truncated [ ( "bench.v1.Envelope", 3 ) ] 33 }
    , { seed = Envelope, label = "truncated at 127 of 433", prefix = 127, middle = "", suffix = 0, expected = Fails Truncated [ ( "bench.v1.Envelope", 3 ) ] 33 }
    , { seed = Envelope, label = "truncated at 141 of 433", prefix = 141, middle = "", suffix = 0, expected = Fails Truncated [ ( "bench.v1.Envelope", 3 ) ] 33 }
    , { seed = Envelope, label = "truncated at 155 of 433", prefix = 155, middle = "", suffix = 0, expected = Fails Truncated [ ( "bench.v1.Envelope", 3 ) ] 33 }
    , { seed = Envelope, label = "truncated at 169 of 433", prefix = 169, middle = "", suffix = 0, expected = Fails Truncated [ ( "bench.v1.Envelope", 3 ) ] 33 }
    , { seed = Envelope, label = "truncated at 183 of 433", prefix = 183, middle = "", suffix = 0, expected = Fails Truncated [ ( "bench.v1.Envelope", 3 ) ] 33 }
    , { seed = Envelope, label = "truncated at 197 of 433", prefix = 197, middle = "", suffix = 0, expected = Fails Truncated [ ( "bench.v1.Envelope", 3 ) ] 33 }
    , { seed = Envelope, label = "truncated at 211 of 433", prefix = 211, middle = "", suffix = 0, expected = Fails Truncated [ ( "bench.v1.Envelope", 3 ) ] 33 }
    , { seed = Envelope, label = "truncated at 225 of 433", prefix = 225, middle = "", suffix = 0, expected = Fails Truncated [ ( "bench.v1.Envelope", 3 ) ] 33 }
    , { seed = Envelope, label = "truncated at 239 of 433", prefix = 239, middle = "", suffix = 0, expected = Fails Truncated [ ( "bench.v1.Envelope", 3 ) ] 33 }
    , { seed = Envelope, label = "truncated at 253 of 433", prefix = 253, middle = "", suffix = 0, expected = Fails Truncated [ ( "bench.v1.Envelope", 3 ) ] 33 }
    , { seed = Envelope, label = "truncated at 267 of 433", prefix = 267, middle = "", suffix = 0, expected = Fails Truncated [ ( "bench.v1.Envelope", 3 ) ] 33 }
    , { seed = Envelope, label = "truncated at 281 of 433", prefix = 281, middle = "", suffix = 0, expected = Fails Truncated [ ( "bench.v1.Envelope", 3 ) ] 33 }
    , { seed = Envelope, label = "truncated at 295 of 433", prefix = 295, middle = "", suffix = 0, expected = Fails Truncated [ ( "bench.v1.Envelope", 3 ) ] 33 }
    , { seed = Envelope, label = "truncated at 309 of 433", prefix = 309, middle = "", suffix = 0, expected = Fails Truncated [ ( "bench.v1.Envelope", 3 ) ] 33 }
    , { seed = Envelope, label = "truncated at 323 of 433", prefix = 323, middle = "", suffix = 0, expected = Fails Truncated [ ( "bench.v1.Envelope", 3 ) ] 33 }
    , { seed = Envelope, label = "truncated at 337 of 433", prefix = 337, middle = "", suffix = 0, expected = Fails Truncated [ ( "bench.v1.Envelope", 3 ) ] 33 }
    , { seed = Envelope, label = "truncated at 351 of 433", prefix = 351, middle = "", suffix = 0, expected = Fails Truncated [ ( "bench.v1.Envelope", 3 ) ] 33 }
    , { seed = Envelope, label = "truncated at 365 of 433", prefix = 365, middle = "", suffix = 0, expected = Fails Truncated [ ( "bench.v1.Envelope", 3 ) ] 33 }
    , { seed = Envelope, label = "truncated at 379 of 433", prefix = 379, middle = "", suffix = 0, expected = Fails Truncated [ ( "bench.v1.Envelope", 3 ) ] 33 }
    , { seed = Envelope, label = "truncated at 393 of 433", prefix = 393, middle = "", suffix = 0, expected = Fails Truncated [ ( "bench.v1.Envelope", 3 ) ] 33 }
    , { seed = Envelope, label = "truncated at 407 of 433", prefix = 407, middle = "", suffix = 0, expected = Fails Truncated [ ( "bench.v1.Envelope", 4 ) ] 401 }
    , { seed = Envelope, label = "truncated at 421 of 433", prefix = 421, middle = "", suffix = 0, expected = Fails Truncated [ ( "bench.v1.Envelope", 4 ) ] 401 }
    , { seed = Envelope, label = "truncated at 432 of 433", prefix = 432, middle = "", suffix = 0, expected = Fails Truncated [ ( "bench.v1.Envelope", 4 ) ] 401 }
    , { seed = Envelope, label = "wire 3 at (0,)", prefix = 0, middle = "0b0102", suffix = 417, expected = Fails (InvalidWireType 3) [ ( "bench.v1.Envelope", 1 ) ] 0 }
    , { seed = Envelope, label = "field 0 at (0,)", prefix = 0, middle = "0201", suffix = 417, expected = Fails InvalidTag [ ( "bench.v1.Envelope", 0 ) ] 0 }
    , { seed = Envelope, label = "wire 4 at (1,)", prefix = 16, middle = "140102", suffix = 410, expected = Fails (InvalidWireType 4) [ ( "bench.v1.Envelope", 2 ) ] 16 }
    , { seed = Envelope, label = "wire 6 at (2,)", prefix = 23, middle = "160102", suffix = 401, expected = Fails (InvalidWireType 6) [ ( "bench.v1.Envelope", 2 ) ] 23 }
    , { seed = Envelope, label = "wire 7 at (3,)", prefix = 32, middle = "1f0102", suffix = 33, expected = Fails (InvalidWireType 7) [ ( "bench.v1.Envelope", 3 ) ] 32 }
    , { seed = Envelope, label = "field 0 at (3,)", prefix = 32, middle = "02", suffix = 34, expected = Fails InvalidTag [ ( "bench.v1.Envelope", 0 ) ] 32 }
    , { seed = Envelope, label = "wire 3 at (3, 0)", prefix = 33, middle = "ca020b0102", suffix = 360, expected = Fails (InvalidWireType 3) [ ( "bench.v1.Envelope", 3 ), ( "google.protobuf.Any", 1 ) ] 35 }
    , { seed = Envelope, label = "overrun at (3, 0)", prefix = 36, middle = "27747970652e676f6f676c65617069732e636f6d2f62656e63682e76312e5061796c6f616412c4020a2841206e6f74652061626f757420746865207765656b6c7920706c616e6e696e67206d656574696e6712f8014c6f72656d20697073756d20646f6c6f722073697420616d65742c20636f6e73656374657475722061646970697363696e6720656c69742c2073656420646f20656975736d6f642074656d706f7220696e6369646964756e74207574206c61626f726520657420646f6c6f7265206d61676e6120616c697175612e204c6f72656d20697073756d20646f6c6f722073697420616d65742c20636f6e73656374657475722061646970697363696e6720656c69742c2073656420646f20656975736d6f642074656d706f7220696e6369646964756e74207574206c61626f726520657420646f6c6f7265206d61676e6120616c697175612e201a08706c616e6e696e671a067765656b6c791a047465616d20959aef3a2801221f666f727761726465642066726f6d207468652073686172656420696e626f782214747261696c696e67206279746573206166746572", suffix = 0, expected = Fails InvalidUtf8 [ ( "bench.v1.Envelope", 3 ), ( "google.protobuf.Any", 1 ) ] 36 }
    , { seed = Envelope, label = "wire 4 at (3, 1)", prefix = 33, middle = "290a24747970652e676f6f676c65617069732e636f6d2f62656e63682e76312e5061796c6f6164140102", suffix = 33, expected = Fails (InvalidWireType 4) [ ( "bench.v1.Envelope", 3 ), ( "google.protobuf.Any", 2 ) ] 72 }
    , { seed = Envelope, label = "overrun at (3, 1)", prefix = 74, middle = "c7020a2841206e6f74652061626f757420746865207765656b6c7920706c616e6e696e67206d656574696e6712f8014c6f72656d20697073756d20646f6c6f722073697420616d65742c20636f6e73656374657475722061646970697363696e6720656c69742c2073656420646f20656975736d6f642074656d706f7220696e6369646964756e74207574206c61626f726520657420646f6c6f7265206d61676e6120616c697175612e204c6f72656d20697073756d20646f6c6f722073697420616d65742c20636f6e73656374657475722061646970697363696e6720656c69742c2073656420646f20656975736d6f642074656d706f7220696e6369646964756e74207574206c61626f726520657420646f6c6f7265206d61676e6120616c697175612e201a08706c616e6e696e671a067765656b6c791a047465616d20959aef3a2801221f666f727761726465642066726f6d207468652073686172656420696e626f782214747261696c696e67206279746573206166746572", suffix = 0, expected = Fails LengthOverrun [ ( "bench.v1.Envelope", 3 ), ( "google.protobuf.Any", 2 ) ] 74 }
    , { seed = Envelope, label = "wire 6 at (4,)", prefix = 400, middle = "260102", suffix = 0, expected = Fails (InvalidWireType 6) [ ( "bench.v1.Envelope", 4 ) ] 400 }
    , { seed = Envelope, label = "field 0 at (4,)", prefix = 400, middle = "0201", suffix = 0, expected = Fails InvalidTag [ ( "bench.v1.Envelope", 0 ) ] 400 }
    , { seed = Envelope, label = "key cut at end", prefix = 433, middle = "80", suffix = 0, expected = Fails Truncated [] 433 }
    , { seed = Envelope, label = "long key at end", prefix = 433, middle = "8080808080808080808080", suffix = 0, expected = Fails MalformedVarint [] 433 }
    , { seed = Envelope, label = "unknown field length past end", prefix = 433, middle = "4ae807616263", suffix = 0, expected = Fails Truncated [ ( "bench.v1.Envelope", 9 ) ] 434 }
    , { seed = Envelope, label = "group start at end", prefix = 433, middle = "4b", suffix = 0, expected = Fails (InvalidWireType 3) [ ( "bench.v1.Envelope", 9 ) ] 433 }
    , { seed = Envelope, label = "fixed64 cut at end", prefix = 433, middle = "490102", suffix = 0, expected = Fails Truncated [ ( "bench.v1.Envelope", 9 ) ] 434 }
    , { seed = Plain, label = "truncated at 1 of 392", prefix = 1, middle = "", suffix = 0, expected = Fails Truncated [ ( "bench.v1.Plain", 1 ) ] 1 }
    , { seed = Plain, label = "truncated at 14 of 392", prefix = 14, middle = "", suffix = 0, expected = Fails Truncated [ ( "bench.v1.Plain", 1 ) ] 1 }
    , { seed = Plain, label = "truncated at 27 of 392", prefix = 27, middle = "", suffix = 0, expected = Fails Truncated [ ( "bench.v1.Plain", 2 ) ] 24 }
    , { seed = Plain, label = "truncated at 40 of 392", prefix = 40, middle = "", suffix = 0, expected = Fails Truncated [ ( "bench.v1.Plain", 3 ) ] 33 }
    , { seed = Plain, label = "truncated at 53 of 392", prefix = 53, middle = "", suffix = 0, expected = Fails Truncated [ ( "bench.v1.Plain", 3 ) ] 33 }
    , { seed = Plain, label = "truncated at 66 of 392", prefix = 66, middle = "", suffix = 0, expected = Fails Truncated [ ( "bench.v1.Plain", 3 ) ] 33 }
    , { seed = Plain, label = "truncated at 79 of 392", prefix = 79, middle = "", suffix = 0, expected = Fails Truncated [ ( "bench.v1.Plain", 3 ) ] 33 }
    , { seed = Plain, label = "truncated at 92 of 392", prefix = 92, middle = "", suffix = 0, expected = Fails Truncated [ ( "bench.v1.Plain", 3 ) ] 33 }
    , { seed = Plain, label = "truncated at 105 of 392", prefix = 105, middle = "", suffix = 0, expected = Fails Truncated [ ( "bench.v1.Plain", 3 ) ] 33 }
    , { seed = Plain, label = "truncated at 118 of 392", prefix = 118, middle = "", suffix = 0, expected = Fails Truncated [ ( "bench.v1.Plain", 3 ) ] 33 }
    , { seed = Plain, label = "truncated at 131 of 392", prefix = 131, middle = "", suffix = 0, expected = Fails Truncated [ ( "bench.v1.Plain", 3 ) ] 33 }
    , { seed = Plain, label = "truncated at 144 of 392", prefix = 144, middle = "", suffix = 0, expected = Fails Truncated [ ( "bench.v1.Plain", 3 ) ] 33 }
    , { seed = Plain, label = "truncated at 157 of 392", prefix = 157, middle = "", suffix = 0, expected = Fails Truncated [ ( "bench.v1.Plain", 3 ) ] 33 }
    , { seed = Plain, label = "truncated at 170 of 392", prefix = 170, middle = "", suffix = 0, expected = Fails Truncated [ ( "bench.v1.Plain", 3 ) ] 33 }
    , { seed = Plain, label = "truncated at 183 of 392", prefix = 183, middle = "", suffix = 0, expected = Fails Truncated [ ( "bench.v1.Plain", 3 ) ] 33 }
    , { seed = Plain, label = "truncated at 196 of 392", prefix = 196, middle = "", suffix = 0, expected = Fails Truncated [ ( "bench.v1.Plain", 3 ) ] 33 }
    , { seed = Plain, label = "truncated at 209 of 392", prefix = 209, middle = "", suffix = 0, expected = Fails Truncated [ ( "bench.v1.Plain", 3 ) ] 33 }
    , { seed = Plain, label = "truncated at 222 of 392", prefix = 222, middle = "", suffix = 0, expected = Fails Truncated [ ( "bench.v1.Plain", 3 ) ] 33 }
    , { seed = Plain, label = "truncated at 235 of 392", prefix = 235, middle = "", suffix = 0, expected = Fails Truncated [ ( "bench.v1.Plain", 3 ) ] 33 }
    , { seed = Plain, label = "truncated at 248 of 392", prefix = 248, middle = "", suffix = 0, expected = Fails Truncated [ ( "bench.v1.Plain", 3 ) ] 33 }
    , { seed = Plain, label = "truncated at 261 of 392", prefix = 261, middle = "", suffix = 0, expected = Fails Truncated [ ( "bench.v1.Plain", 3 ) ] 33 }
    , { seed = Plain, label = "truncated at 274 of 392", prefix = 274, middle = "", suffix = 0, expected = Fails Truncated [ ( "bench.v1.Plain", 3 ) ] 33 }
    , { seed = Plain, label = "truncated at 287 of 392", prefix = 287, middle = "", suffix = 0, expected = Fails Truncated [ ( "bench.v1.Plain", 3 ) ] 33 }
    , { seed = Plain, label = "truncated at 300 of 392", prefix = 300, middle = "", suffix = 0, expected = Fails Truncated [ ( "bench.v1.Plain", 3 ) ] 33 }
    , { seed = Plain, label = "truncated at 313 of 392", prefix = 313, middle = "", suffix = 0, expected = Fails Truncated [ ( "bench.v1.Plain", 3 ) ] 33 }
    , { seed = Plain, label = "truncated at 326 of 392", prefix = 326, middle = "", suffix = 0, expected = Fails Truncated [ ( "bench.v1.Plain", 3 ) ] 33 }
    , { seed = Plain, label = "truncated at 339 of 392", prefix = 339, middle = "", suffix = 0, expected = Fails Truncated [ ( "bench.v1.Plain", 3 ) ] 33 }
    , { seed = Plain, label = "truncated at 352 of 392", prefix = 352, middle = "", suffix = 0, expected = Fails Truncated [ ( "bench.v1.Plain", 3 ) ] 33 }
    , { seed = Plain, label = "truncated at 365 of 392", prefix = 365, middle = "", suffix = 0, expected = Fails Truncated [ ( "bench.v1.Plain", 4 ) ] 360 }
    , { seed = Plain, label = "truncated at 378 of 392", prefix = 378, middle = "", suffix = 0, expected = Fails Truncated [ ( "bench.v1.Plain", 4 ) ] 360 }
    , { seed = Plain, label = "truncated at 391 of 392", prefix = 391, middle = "", suffix = 0, expected = Fails Truncated [ ( "bench.v1.Plain", 4 ) ] 360 }
    , { seed = Plain, label = "wire 3 at (0,)", prefix = 0, middle = "0b0102", suffix = 376, expected = Fails (InvalidWireType 3) [ ( "bench.v1.Plain", 1 ) ] 0 }
    , { seed = Plain, label = "field 0 at (0,)", prefix = 0, middle = "0201", suffix = 376, expected = Fails InvalidTag [ ( "bench.v1.Plain", 0 ) ] 0 }
    , { seed = Plain, label = "wire 4 at (1,)", prefix = 16, middle = "140102", suffix = 369, expected = Fails (InvalidWireType 4) [ ( "bench.v1.Plain", 2 ) ] 16 }
    , { seed = Plain, label = "wire 6 at (2,)", prefix = 23, middle = "160102", suffix = 360, expected = Fails (InvalidWireType 6) [ ( "bench.v1.Plain", 2 ) ] 23 }
    , { seed = Plain, label = "wire 7 at (3,)", prefix = 32, middle = "1f0102", suffix = 33, expected = Fails (InvalidWireType 7) [ ( "bench.v1.Plain", 3 ) ] 32 }
    , { seed = Plain, label = "field 0 at (3,)", prefix = 32, middle = "02", suffix = 34, expected = Fails InvalidTag [ ( "bench.v1.Plain", 0 ) ] 32 }
    , { seed = Plain, label = "wire 3 at (3, 0)", prefix = 33, middle = "9d020b0102", suffix = 315, expected = Fails (InvalidWireType 3) [ ( "bench.v1.Plain", 3 ), ( "bench.v1.Payload", 1 ) ] 35 }
    , { seed = Plain, label = "overrun at (3, 0)", prefix = 36, middle = "2b41206e6f74652061626f757420746865207765656b6c7920706c616e6e696e67206d656574696e6712f8014c6f72656d20697073756d20646f6c6f722073697420616d65742c20636f6e73656374657475722061646970697363696e6720656c69742c2073656420646f20656975736d6f642074656d706f7220696e6369646964756e74207574206c61626f726520657420646f6c6f7265206d61676e6120616c697175612e204c6f72656d20697073756d20646f6c6f722073697420616d65742c20636f6e73656374657475722061646970697363696e6720656c69742c2073656420646f20656975736d6f642074656d706f7220696e6369646964756e74207574206c61626f726520657420646f6c6f7265206d61676e6120616c697175612e201a08706c616e6e696e671a067765656b6c791a047465616d20959aef3a2801221f666f727761726465642066726f6d207468652073686172656420696e626f782214747261696c696e67206279746573206166746572", suffix = 0, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 3 ), ( "bench.v1.Payload", 1 ) ] 36 }
    , { seed = Plain, label = "wire 4 at (3, 1)", prefix = 33, middle = "4c0a2841206e6f74652061626f757420746865207765656b6c7920706c616e6e696e67206d656574696e67140102", suffix = 64, expected = Fails (InvalidWireType 4) [ ( "bench.v1.Plain", 3 ), ( "bench.v1.Payload", 2 ) ] 76 }
    , { seed = Plain, label = "overrun at (3, 1)", prefix = 78, middle = "fb014c6f72656d20697073756d20646f6c6f722073697420616d65742c20636f6e73656374657475722061646970697363696e6720656c69742c2073656420646f20656975736d6f642074656d706f7220696e6369646964756e74207574206c61626f726520657420646f6c6f7265206d61676e6120616c697175612e204c6f72656d20697073756d20646f6c6f722073697420616d65742c20636f6e73656374657475722061646970697363696e6720656c69742c2073656420646f20656975736d6f642074656d706f7220696e6369646964756e74207574206c61626f726520657420646f6c6f7265206d61676e6120616c697175612e201a08706c616e6e696e671a067765656b6c791a047465616d20959aef3a2801221f666f727761726465642066726f6d207468652073686172656420696e626f782214747261696c696e67206279746573206166746572", suffix = 0, expected = Fails (InvalidWireType 4) [ ( "bench.v1.Plain", 3 ), ( "bench.v1.Payload", 13 ) ] 331 }
    , { seed = Plain, label = "wire 6 at (3, 2)", prefix = 33, middle = "bd020a2841206e6f74652061626f757420746865207765656b6c7920706c616e6e696e67206d656574696e6712f8014c6f72656d20697073756d20646f6c6f722073697420616d65742c20636f6e73656374657475722061646970697363696e6720656c69742c2073656420646f20656975736d6f642074656d706f7220696e6369646964756e74207574206c61626f726520657420646f6c6f7265206d61676e6120616c697175612e204c6f72656d20697073756d20646f6c6f722073697420616d65742c20636f6e73656374657475722061646970697363696e6720656c69742c2073656420646f20656975736d6f642074656d706f7220696e6369646964756e74207574206c61626f726520657420646f6c6f7265206d61676e6120616c697175612e201e0102", suffix = 54, expected = Fails (InvalidWireType 6) [ ( "bench.v1.Plain", 3 ), ( "bench.v1.Payload", 3 ) ] 328 }
    , { seed = Plain, label = "field 0 at (3, 2)", prefix = 33, middle = "bc020a2841206e6f74652061626f757420746865207765656b6c7920706c616e6e696e67206d656574696e6712f8014c6f72656d20697073756d20646f6c6f722073697420616d65742c20636f6e73656374657475722061646970697363696e6720656c69742c2073656420646f20656975736d6f642074656d706f7220696e6369646964756e74207574206c61626f726520657420646f6c6f7265206d61676e6120616c697175612e204c6f72656d20697073756d20646f6c6f722073697420616d65742c20636f6e73656374657475722061646970697363696e6720656c69742c2073656420646f20656975736d6f642074656d706f7220696e6369646964756e74207574206c61626f726520657420646f6c6f7265206d61676e6120616c697175612e200201", suffix = 54, expected = Fails InvalidTag [ ( "bench.v1.Plain", 3 ), ( "bench.v1.Payload", 0 ) ] 328 }
    , { seed = Plain, label = "overrun at (3, 2)", prefix = 329, middle = "0b706c616e6e696e671a067765656b6c791a047465616d20959aef3a2801221f666f727761726465642066726f6d207468652073686172656420696e626f782214747261696c696e67206279746573206166746572", suffix = 0, expected = Decodes }
    , { seed = Plain, label = "wire 7 at (3, 3)", prefix = 33, middle = "bf020a2841206e6f74652061626f757420746865207765656b6c7920706c616e6e696e67206d656574696e6712f8014c6f72656d20697073756d20646f6c6f722073697420616d65742c20636f6e73656374657475722061646970697363696e6720656c69742c2073656420646f20656975736d6f642074656d706f7220696e6369646964756e74207574206c61626f726520657420646f6c6f7265206d61676e6120616c697175612e204c6f72656d20697073756d20646f6c6f722073697420616d65742c20636f6e73656374657475722061646970697363696e6720656c69742c2073656420646f20656975736d6f642074656d706f7220696e6369646964756e74207574206c61626f726520657420646f6c6f7265206d61676e6120616c697175612e201a08706c616e6e696e671f0102", suffix = 46, expected = Fails (InvalidWireType 7) [ ( "bench.v1.Plain", 3 ), ( "bench.v1.Payload", 3 ) ] 338 }
    , { seed = Plain, label = "overrun at (3, 3)", prefix = 339, middle = "097765656b6c791a047465616d20959aef3a2801221f666f727761726465642066726f6d207468652073686172656420696e626f782214747261696c696e67206279746573206166746572", suffix = 0, expected = Fails LengthOverrun [ ( "bench.v1.Plain", 3 ), ( "bench.v1.Payload", 120563 ) ] 357 }
    , { seed = Plain, label = "wire 3 at (3, 4)", prefix = 33, middle = "c1020a2841206e6f74652061626f757420746865207765656b6c7920706c616e6e696e67206d656574696e6712f8014c6f72656d20697073756d20646f6c6f722073697420616d65742c20636f6e73656374657475722061646970697363696e6720656c69742c2073656420646f20656975736d6f642074656d706f7220696e6369646964756e74207574206c61626f726520657420646f6c6f7265206d61676e6120616c697175612e204c6f72656d20697073756d20646f6c6f722073697420616d65742c20636f6e73656374657475722061646970697363696e6720656c69742c2073656420646f20656975736d6f642074656d706f7220696e6369646964756e74207574206c61626f726520657420646f6c6f7265206d61676e6120616c697175612e201a08706c616e6e696e671a067765656b6c791b0102", suffix = 40, expected = Fails (InvalidWireType 3) [ ( "bench.v1.Plain", 3 ), ( "bench.v1.Payload", 3 ) ] 346 }
    , { seed = Plain, label = "overrun at (3, 4)", prefix = 347, middle = "077465616d20959aef3a2801221f666f727761726465642066726f6d207468652073686172656420696e626f782214747261696c696e67206279746573206166746572", suffix = 0, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 3 ), ( "bench.v1.Payload", 3 ) ] 347 }
    , { seed = Plain, label = "wire 4 at (3, 5)", prefix = 33, middle = "c2020a2841206e6f74652061626f757420746865207765656b6c7920706c616e6e696e67206d656574696e6712f8014c6f72656d20697073756d20646f6c6f722073697420616d65742c20636f6e73656374657475722061646970697363696e6720656c69742c2073656420646f20656975736d6f642074656d706f7220696e6369646964756e74207574206c61626f726520657420646f6c6f7265206d61676e6120616c697175612e204c6f72656d20697073756d20646f6c6f722073697420616d65742c20636f6e73656374657475722061646970697363696e6720656c69742c2073656420646f20656975736d6f642074656d706f7220696e6369646964756e74207574206c61626f726520657420646f6c6f7265206d61676e6120616c697175612e201a08706c616e6e696e671a067765656b6c791a047465616d240102", suffix = 35, expected = Fails (InvalidWireType 4) [ ( "bench.v1.Plain", 3 ), ( "bench.v1.Payload", 4 ) ] 352 }
    , { seed = Plain, label = "field 0 at (3, 5)", prefix = 33, middle = "c1020a2841206e6f74652061626f757420746865207765656b6c7920706c616e6e696e67206d656574696e6712f8014c6f72656d20697073756d20646f6c6f722073697420616d65742c20636f6e73656374657475722061646970697363696e6720656c69742c2073656420646f20656975736d6f642074656d706f7220696e6369646964756e74207574206c61626f726520657420646f6c6f7265206d61676e6120616c697175612e204c6f72656d20697073756d20646f6c6f722073697420616d65742c20636f6e73656374657475722061646970697363696e6720656c69742c2073656420646f20656975736d6f642074656d706f7220696e6369646964756e74207574206c61626f726520657420646f6c6f7265206d61676e6120616c697175612e201a08706c616e6e696e671a067765656b6c791a047465616d0001", suffix = 35, expected = Fails InvalidTag [ ( "bench.v1.Plain", 3 ), ( "bench.v1.Payload", 0 ) ] 352 }
    , { seed = Plain, label = "long varint at (3, 5)", prefix = 33, middle = "cb020a2841206e6f74652061626f757420746865207765656b6c7920706c616e6e696e67206d656574696e6712f8014c6f72656d20697073756d20646f6c6f722073697420616d65742c20636f6e73656374657475722061646970697363696e6720656c69742c2073656420646f20656975736d6f642074656d706f7220696e6369646964756e74207574206c61626f726520657420646f6c6f7265206d61676e6120616c697175612e204c6f72656d20697073756d20646f6c6f722073697420616d65742c20636f6e73656374657475722061646970697363696e6720656c69742c2073656420646f20656975736d6f642074656d706f7220696e6369646964756e74207574206c61626f726520657420646f6c6f7265206d61676e6120616c697175612e201a08706c616e6e696e671a067765656b6c791a047465616d208080808080808080808001", suffix = 35, expected = Fails MalformedVarint [ ( "bench.v1.Plain", 3 ), ( "bench.v1.Payload", 4 ) ] 353 }
    , { seed = Plain, label = "wire 6 at (3, 6)", prefix = 33, middle = "c5020a2841206e6f74652061626f757420746865207765656b6c7920706c616e6e696e67206d656574696e6712f8014c6f72656d20697073756d20646f6c6f722073697420616d65742c20636f6e73656374657475722061646970697363696e6720656c69742c2073656420646f20656975736d6f642074656d706f7220696e6369646964756e74207574206c61626f726520657420646f6c6f7265206d61676e6120616c697175612e204c6f72656d20697073756d20646f6c6f722073697420616d65742c20636f6e73656374657475722061646970697363696e6720656c69742c2073656420646f20656975736d6f642074656d706f7220696e6369646964756e74207574206c61626f726520657420646f6c6f7265206d61676e6120616c697175612e201a08706c616e6e696e671a067765656b6c791a047465616d20959aef3a2e0102", suffix = 33, expected = Fails (InvalidWireType 6) [ ( "bench.v1.Plain", 3 ), ( "bench.v1.Payload", 5 ) ] 357 }
    , { seed = Plain, label = "long varint at (3, 6)", prefix = 33, middle = "ce020a2841206e6f74652061626f757420746865207765656b6c7920706c616e6e696e67206d656574696e6712f8014c6f72656d20697073756d20646f6c6f722073697420616d65742c20636f6e73656374657475722061646970697363696e6720656c69742c2073656420646f20656975736d6f642074656d706f7220696e6369646964756e74207574206c61626f726520657420646f6c6f7265206d61676e6120616c697175612e204c6f72656d20697073756d20646f6c6f722073697420616d65742c20636f6e73656374657475722061646970697363696e6720656c69742c2073656420646f20656975736d6f642074656d706f7220696e6369646964756e74207574206c61626f726520657420646f6c6f7265206d61676e6120616c697175612e201a08706c616e6e696e671a067765656b6c791a047465616d20959aef3a2880808080808080808080", suffix = 34, expected = Fails MalformedVarint [ ( "bench.v1.Plain", 3 ), ( "bench.v1.Payload", 5 ) ] 358 }
    , { seed = Plain, label = "wire 7 at (4,)", prefix = 359, middle = "270102", suffix = 0, expected = Fails (InvalidWireType 7) [ ( "bench.v1.Plain", 4 ) ] 359 }
    , { seed = Plain, label = "key cut at end", prefix = 392, middle = "80", suffix = 0, expected = Fails Truncated [] 392 }
    , { seed = Plain, label = "long key at end", prefix = 392, middle = "8080808080808080808080", suffix = 0, expected = Fails MalformedVarint [] 392 }
    , { seed = Plain, label = "unknown field length past end", prefix = 392, middle = "4ae807616263", suffix = 0, expected = Fails Truncated [ ( "bench.v1.Plain", 9 ) ] 393 }
    , { seed = Plain, label = "group start at end", prefix = 392, middle = "4b", suffix = 0, expected = Fails (InvalidWireType 3) [ ( "bench.v1.Plain", 9 ) ] 392 }
    , { seed = Plain, label = "fixed64 cut at end", prefix = 392, middle = "490102", suffix = 0, expected = Fails Truncated [ ( "bench.v1.Plain", 9 ) ] 393 }
    , { seed = AllTypes, label = "truncated at 1 of 181", prefix = 1, middle = "", suffix = 0, expected = Fails Truncated [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 1 ) ] 1 }
    , { seed = AllTypes, label = "truncated at 5 of 181", prefix = 5, middle = "", suffix = 0, expected = Fails Truncated [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 2 ) ] 3 }
    , { seed = AllTypes, label = "truncated at 9 of 181", prefix = 9, middle = "", suffix = 0, expected = Fails Truncated [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 2 ) ] 3 }
    , { seed = AllTypes, label = "truncated at 13 of 181", prefix = 13, middle = "", suffix = 0, expected = Decodes }
    , { seed = AllTypes, label = "truncated at 17 of 181", prefix = 17, middle = "", suffix = 0, expected = Fails Truncated [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 12 ) ] 14 }
    , { seed = AllTypes, label = "truncated at 21 of 181", prefix = 21, middle = "", suffix = 0, expected = Fails Truncated [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 12 ) ] 14 }
    , { seed = AllTypes, label = "truncated at 25 of 181", prefix = 25, middle = "", suffix = 0, expected = Fails Truncated [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 14 ) ] 23 }
    , { seed = AllTypes, label = "truncated at 29 of 181", prefix = 29, middle = "", suffix = 0, expected = Decodes }
    , { seed = AllTypes, label = "truncated at 33 of 181", prefix = 33, middle = "", suffix = 0, expected = Fails Truncated [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 15 ) ] 30 }
    , { seed = AllTypes, label = "truncated at 37 of 181", prefix = 37, middle = "", suffix = 0, expected = Fails Truncated [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 18 ) ] 36 }
    , { seed = AllTypes, label = "truncated at 41 of 181", prefix = 41, middle = "", suffix = 0, expected = Fails Truncated [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 18 ) ] 36 }
    , { seed = AllTypes, label = "truncated at 45 of 181", prefix = 45, middle = "", suffix = 0, expected = Fails Truncated [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 18 ) ] 36 }
    , { seed = AllTypes, label = "truncated at 49 of 181", prefix = 49, middle = "", suffix = 0, expected = Fails Truncated [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 18 ) ] 36 }
    , { seed = AllTypes, label = "truncated at 53 of 181", prefix = 53, middle = "", suffix = 0, expected = Fails Truncated [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 31 ) ] 52 }
    , { seed = AllTypes, label = "truncated at 57 of 181", prefix = 57, middle = "", suffix = 0, expected = Fails Truncated [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 31 ) ] 52 }
    , { seed = AllTypes, label = "truncated at 61 of 181", prefix = 61, middle = "", suffix = 0, expected = Fails Truncated [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 31 ) ] 52 }
    , { seed = AllTypes, label = "truncated at 65 of 181", prefix = 65, middle = "", suffix = 0, expected = Fails Truncated [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 31 ) ] 52 }
    , { seed = AllTypes, label = "truncated at 69 of 181", prefix = 69, middle = "", suffix = 0, expected = Decodes }
    , { seed = AllTypes, label = "truncated at 73 of 181", prefix = 73, middle = "", suffix = 0, expected = Decodes }
    , { seed = AllTypes, label = "truncated at 77 of 181", prefix = 77, middle = "", suffix = 0, expected = Fails Truncated [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 44 ) ] 75 }
    , { seed = AllTypes, label = "truncated at 81 of 181", prefix = 81, middle = "", suffix = 0, expected = Fails Truncated [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 48 ) ] 80 }
    , { seed = AllTypes, label = "truncated at 85 of 181", prefix = 85, middle = "", suffix = 0, expected = Fails Truncated [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 48 ) ] 85 }
    , { seed = AllTypes, label = "truncated at 89 of 181", prefix = 89, middle = "", suffix = 0, expected = Fails Truncated [] 88 }
    , { seed = AllTypes, label = "truncated at 93 of 181", prefix = 93, middle = "", suffix = 0, expected = Fails Truncated [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 56 ) ] 90 }
    , { seed = AllTypes, label = "truncated at 97 of 181", prefix = 97, middle = "", suffix = 0, expected = Fails Truncated [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 56 ) ] 97 }
    , { seed = AllTypes, label = "truncated at 101 of 181", prefix = 101, middle = "", suffix = 0, expected = Fails Truncated [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 56 ) ] 97 }
    , { seed = AllTypes, label = "truncated at 105 of 181", prefix = 105, middle = "", suffix = 0, expected = Fails Truncated [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 71 ) ] 104 }
    , { seed = AllTypes, label = "truncated at 109 of 181", prefix = 109, middle = "", suffix = 0, expected = Fails Truncated [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 71 ) ] 104 }
    , { seed = AllTypes, label = "truncated at 113 of 181", prefix = 113, middle = "", suffix = 0, expected = Fails Truncated [] 112 }
    , { seed = AllTypes, label = "truncated at 117 of 181", prefix = 117, middle = "", suffix = 0, expected = Fails Truncated [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 82 ) ] 114 }
    , { seed = AllTypes, label = "truncated at 121 of 181", prefix = 121, middle = "", suffix = 0, expected = Fails Truncated [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 82 ) ] 114 }
    , { seed = AllTypes, label = "truncated at 125 of 181", prefix = 125, middle = "", suffix = 0, expected = Fails Truncated [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 82 ) ] 114 }
    , { seed = AllTypes, label = "truncated at 129 of 181", prefix = 129, middle = "", suffix = 0, expected = Fails Truncated [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 82 ) ] 114 }
    , { seed = AllTypes, label = "truncated at 133 of 181", prefix = 133, middle = "", suffix = 0, expected = Fails Truncated [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 82 ) ] 114 }
    , { seed = AllTypes, label = "truncated at 137 of 181", prefix = 137, middle = "", suffix = 0, expected = Fails Truncated [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 82 ) ] 114 }
    , { seed = AllTypes, label = "truncated at 141 of 181", prefix = 141, middle = "", suffix = 0, expected = Fails Truncated [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 202 ) ] 141 }
    , { seed = AllTypes, label = "truncated at 145 of 181", prefix = 145, middle = "", suffix = 0, expected = Fails Truncated [] 144 }
    , { seed = AllTypes, label = "truncated at 149 of 181", prefix = 149, middle = "", suffix = 0, expected = Fails Truncated [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 301 ) ] 146 }
    , { seed = AllTypes, label = "truncated at 153 of 181", prefix = 153, middle = "", suffix = 0, expected = Fails Truncated [] 152 }
    , { seed = AllTypes, label = "truncated at 157 of 181", prefix = 157, middle = "", suffix = 0, expected = Fails Truncated [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 302 ) ] 154 }
    , { seed = AllTypes, label = "truncated at 161 of 181", prefix = 161, middle = "", suffix = 0, expected = Fails Truncated [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 302 ) ] 154 }
    , { seed = AllTypes, label = "truncated at 165 of 181", prefix = 165, middle = "", suffix = 0, expected = Fails Truncated [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 304 ) ] 165 }
    , { seed = AllTypes, label = "truncated at 169 of 181", prefix = 169, middle = "", suffix = 0, expected = Fails Truncated [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 304 ) ] 165 }
    , { seed = AllTypes, label = "truncated at 173 of 181", prefix = 173, middle = "", suffix = 0, expected = Fails Truncated [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 304 ) ] 165 }
    , { seed = AllTypes, label = "truncated at 177 of 181", prefix = 177, middle = "", suffix = 0, expected = Fails Truncated [] 176 }
    , { seed = AllTypes, label = "truncated at 180 of 181", prefix = 180, middle = "", suffix = 0, expected = Fails Truncated [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 306 ) ] 178 }
    , { seed = AllTypes, label = "wire 3 at (0,)", prefix = 0, middle = "0b0102", suffix = 179, expected = Fails (InvalidWireType 3) [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 1 ) ] 0 }
    , { seed = AllTypes, label = "field 0 at (0,)", prefix = 0, middle = "0001", suffix = 179, expected = Fails InvalidTag [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 0 ) ] 0 }
    , { seed = AllTypes, label = "long varint at (0,)", prefix = 1, middle = "8080808080808080808001", suffix = 179, expected = Fails MalformedVarint [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 1 ) ] 1 }
    , { seed = AllTypes, label = "wire 4 at (1,)", prefix = 2, middle = "140102", suffix = 168, expected = Fails (InvalidWireType 4) [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 2 ) ] 2 }
    , { seed = AllTypes, label = "long varint at (1,)", prefix = 3, middle = "80808080808080808080", suffix = 169, expected = Fails MalformedVarint [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 2 ) ] 3 }
    , { seed = AllTypes, label = "wire 6 at (2,)", prefix = 13, middle = "660102", suffix = 159, expected = Fails (InvalidWireType 6) [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 12 ) ] 13 }
    , { seed = AllTypes, label = "wire 7 at (3,)", prefix = 22, middle = "770102", suffix = 152, expected = Fails (InvalidWireType 7) [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 14 ) ] 22 }
    , { seed = AllTypes, label = "field 0 at (3,)", prefix = 22, middle = "0201", suffix = 152, expected = Fails InvalidTag [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 0 ) ] 22 }
    , { seed = AllTypes, label = "wire 3 at (4,)", prefix = 29, middle = "7b", suffix = 149, expected = Fails (InvalidWireType 3) [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 15 ) ] 29 }
    , { seed = AllTypes, label = "wire 4 at (5,)", prefix = 34, middle = "94010102", suffix = 131, expected = Fails (InvalidWireType 4) [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 18 ) ] 34 }
    , { seed = AllTypes, label = "wire 6 at (5, 0)", prefix = 36, middle = "0e0e0102", suffix = 142, expected = Fails (InvalidWireType 6) [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 18 ), ( "protobuf_test_messages.proto3.TestAllTypesProto3.NestedMessage", 1 ) ] 37 }
    , { seed = AllTypes, label = "field 0 at (5, 0)", prefix = 37, middle = "0001", suffix = 142, expected = Fails InvalidTag [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 18 ), ( "protobuf_test_messages.proto3.TestAllTypesProto3.NestedMessage", 0 ) ] 37 }
    , { seed = AllTypes, label = "long varint at (5, 0)", prefix = 36, middle = "17088080808080808080808001", suffix = 142, expected = Fails MalformedVarint [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 18 ), ( "protobuf_test_messages.proto3.TestAllTypesProto3.NestedMessage", 1 ) ] 38 }
    , { seed = AllTypes, label = "wire 7 at (5, 1)", prefix = 36, middle = "050807170102", suffix = 131, expected = Fails (InvalidWireType 7) [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 18 ), ( "protobuf_test_messages.proto3.TestAllTypesProto3.NestedMessage", 2 ) ] 39 }
    , { seed = AllTypes, label = "wire 3 at (5, 1, 0)", prefix = 36, middle = "0e0807120a0b0102", suffix = 138, expected = Fails (InvalidWireType 3) [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 18 ), ( "protobuf_test_messages.proto3.TestAllTypesProto3.NestedMessage", 2 ), ( "protobuf_test_messages.proto3.TestAllTypesProto3", 1 ) ] 41 }
    , { seed = AllTypes, label = "long varint at (5, 1, 0)", prefix = 36, middle = "1708071213088080808080808080808001", suffix = 138, expected = Fails MalformedVarint [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 18 ), ( "protobuf_test_messages.proto3.TestAllTypesProto3.NestedMessage", 2 ), ( "protobuf_test_messages.proto3.TestAllTypesProto3", 1 ) ] 42 }
    , { seed = AllTypes, label = "wire 4 at (5, 1, 1)", prefix = 36, middle = "09080712050808740102", suffix = 131, expected = Fails (InvalidWireType 4) [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 18 ), ( "protobuf_test_messages.proto3.TestAllTypesProto3.NestedMessage", 2 ), ( "protobuf_test_messages.proto3.TestAllTypesProto3", 14 ) ] 43 }
    , { seed = AllTypes, label = "field 0 at (5, 1, 1)", prefix = 36, middle = "080807120408080201", suffix = 131, expected = Fails InvalidTag [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 18 ), ( "protobuf_test_messages.proto3.TestAllTypesProto3.NestedMessage", 2 ), ( "protobuf_test_messages.proto3.TestAllTypesProto3", 0 ) ] 43 }
    , { seed = AllTypes, label = "overrun at (5, 1, 1)", prefix = 44, middle = "08696e6e6572fa0110019601e0a712ffffffffffffffffff01e2020161e20202626282030208018203020802c203040801100ac2030408021014ba04070a016b12020805920518010000000000000002000000000000000300000000000000d20c020805ea120508901c1005f212080880e2cfaa06100082130a0a080a016b12031a017392130220017a14747261696c696e67206279746573206166746572", suffix = 0, expected = Fails LengthOverrun [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 18 ), ( "protobuf_test_messages.proto3.TestAllTypesProto3.NestedMessage", 2 ), ( "protobuf_test_messages.proto3.TestAllTypesProto3", 14 ) ] 44 }
    , { seed = AllTypes, label = "wire 6 at (6,)", prefix = 50, middle = "fe010102", suffix = 112, expected = Fails (InvalidWireType 6) [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 31 ) ] 50 }
    , { seed = AllTypes, label = "wire 7 at (7,)", prefix = 69, middle = "e7020102", suffix = 108, expected = Fails (InvalidWireType 7) [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 44 ) ] 69 }
    , { seed = AllTypes, label = "wire 3 at (8,)", prefix = 73, middle = "e3020102", suffix = 103, expected = Fails (InvalidWireType 3) [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 44 ) ] 73 }
    , { seed = AllTypes, label = "field 0 at (8,)", prefix = 73, middle = "0201", suffix = 103, expected = Fails InvalidTag [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 0 ) ] 73 }
    , { seed = AllTypes, label = "wire 4 at (9,)", prefix = 78, middle = "84030102", suffix = 98, expected = Fails (InvalidWireType 4) [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 48 ) ] 78 }
    , { seed = AllTypes, label = "wire 6 at (9, 0)", prefix = 80, middle = "030e0102", suffix = 98, expected = Fails (InvalidWireType 6) [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 48 ), ( "protobuf_test_messages.proto3.TestAllTypesProto3.NestedMessage", 1 ) ] 81 }
    , { seed = AllTypes, label = "long varint at (9, 0)", prefix = 80, middle = "0c0880808080808080808080", suffix = 99, expected = Fails MalformedVarint [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 48 ), ( "protobuf_test_messages.proto3.TestAllTypesProto3.NestedMessage", 1 ) ] 82 }
    , { seed = AllTypes, label = "wire 7 at (10,)", prefix = 83, middle = "870301", suffix = 94, expected = Fails (InvalidWireType 7) [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 48 ) ] 83 }
    , { seed = AllTypes, label = "field 0 at (10,)", prefix = 83, middle = "0201", suffix = 93, expected = Fails InvalidTag [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 0 ) ] 83 }
    , { seed = AllTypes, label = "wire 3 at (10, 0)", prefix = 85, middle = "030b01", suffix = 94, expected = Fails (InvalidWireType 3) [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 48 ), ( "protobuf_test_messages.proto3.TestAllTypesProto3.NestedMessage", 1 ) ] 86 }
    , { seed = AllTypes, label = "long varint at (10, 0)", prefix = 85, middle = "0c088080808080808080808001", suffix = 93, expected = Fails MalformedVarint [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 48 ), ( "protobuf_test_messages.proto3.TestAllTypesProto3.NestedMessage", 1 ) ] 87 }
    , { seed = AllTypes, label = "wire 4 at (11,)", prefix = 88, middle = "c4030102", suffix = 86, expected = Fails (InvalidWireType 4) [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 56 ) ] 88 }
    , { seed = AllTypes, label = "wire 6 at (11, 0)", prefix = 90, middle = "050e0102", suffix = 88, expected = Fails (InvalidWireType 6) [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 56 ) ] 91 }
    , { seed = AllTypes, label = "field 0 at (11, 0)", prefix = 91, middle = "00", suffix = 89, expected = Fails InvalidTag [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 56 ) ] 91 }
    , { seed = AllTypes, label = "long varint at (11, 0)", prefix = 90, middle = "0e0880808080808080808080", suffix = 89, expected = Fails MalformedVarint [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 56 ) ] 92 }
    , { seed = AllTypes, label = "wire 7 at (11, 1)", prefix = 90, middle = "050801170102", suffix = 86, expected = Fails (InvalidWireType 7) [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 56 ) ] 93 }
    , { seed = AllTypes, label = "long varint at (11, 1)", prefix = 90, middle = "0e0801108080808080808080808001", suffix = 86, expected = Fails MalformedVarint [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 56 ) ] 94 }
    , { seed = AllTypes, label = "wire 3 at (12,)", prefix = 95, middle = "c3030102", suffix = 79, expected = Fails (InvalidWireType 3) [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 56 ) ] 95 }
    , { seed = AllTypes, label = "wire 4 at (12, 0)", prefix = 97, middle = "050c01", suffix = 82, expected = Fails (InvalidWireType 4) [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 56 ) ] 98 }
    , { seed = AllTypes, label = "field 0 at (12, 0)", prefix = 98, middle = "0001", suffix = 81, expected = Fails InvalidTag [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 56 ) ] 98 }
    , { seed = AllTypes, label = "long varint at (12, 0)", prefix = 97, middle = "0e088080808080808080808001", suffix = 81, expected = Fails MalformedVarint [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 56 ) ] 99 }
    , { seed = AllTypes, label = "wire 6 at (12, 1)", prefix = 97, middle = "050802160102", suffix = 79, expected = Fails (InvalidWireType 6) [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 56 ) ] 100 }
    , { seed = AllTypes, label = "long varint at (12, 1)", prefix = 97, middle = "0e0802108080808080808080808001", suffix = 79, expected = Fails MalformedVarint [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 56 ) ] 101 }
    , { seed = AllTypes, label = "wire 7 at (13,)", prefix = 102, middle = "bf040102", suffix = 69, expected = Fails (InvalidWireType 7) [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 71 ) ] 102 }
    , { seed = AllTypes, label = "wire 3 at (13, 0)", prefix = 105, middle = "0b0102", suffix = 73, expected = Fails (InvalidWireType 3) [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 71 ) ] 105 }
    , { seed = AllTypes, label = "field 0 at (13, 0)", prefix = 104, middle = "060201", suffix = 73, expected = Fails InvalidTag [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 71 ) ] 105 }
    , { seed = AllTypes, label = "overrun at (13, 0)", prefix = 106, middle = "046b12020805920518010000000000000002000000000000000300000000000000d20c020805ea120508901c1005f212080880e2cfaa06100082130a0a080a016b12031a017392130220017a14747261696c696e67206279746573206166746572", suffix = 0, expected = Fails InvalidTag [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 71 ) ] 111 }
    , { seed = AllTypes, label = "wire 4 at (13, 1)", prefix = 104, middle = "060a016b140102", suffix = 69, expected = Fails (InvalidWireType 4) [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 71 ) ] 108 }
    , { seed = AllTypes, label = "wire 6 at (13, 1, 0)", prefix = 104, middle = "080a016b12030e0102", suffix = 69, expected = Fails (InvalidWireType 6) [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 71 ), ( "protobuf_test_messages.proto3.TestAllTypesProto3.NestedMessage", 1 ) ] 110 }
    , { seed = AllTypes, label = "long varint at (13, 1, 0)", prefix = 104, middle = "110a016b120c088080808080808080808001", suffix = 69, expected = Fails MalformedVarint [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 71 ), ( "protobuf_test_messages.proto3.TestAllTypesProto3.NestedMessage", 1 ) ] 111 }
    , { seed = AllTypes, label = "wire 7 at (14,)", prefix = 112, middle = "97050102", suffix = 42, expected = Fails (InvalidWireType 7) [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 82 ) ] 112 }
    , { seed = AllTypes, label = "field 0 at (14,)", prefix = 112, middle = "0201", suffix = 42, expected = Fails InvalidTag [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 0 ) ] 112 }
    , { seed = AllTypes, label = "wire 3 at (15,)", prefix = 139, middle = "d30c0102", suffix = 37, expected = Fails (InvalidWireType 3) [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 202 ) ] 139 }
    , { seed = AllTypes, label = "wire 4 at (15, 0)", prefix = 141, middle = "030c0102", suffix = 37, expected = Fails (InvalidWireType 4) [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 202 ), ( "google.protobuf.Int32Value", 1 ) ] 142 }
    , { seed = AllTypes, label = "long varint at (15, 0)", prefix = 141, middle = "0c088080808080808080808001", suffix = 37, expected = Fails MalformedVarint [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 202 ), ( "google.protobuf.Int32Value", 1 ) ] 143 }
    , { seed = AllTypes, label = "wire 6 at (16,)", prefix = 144, middle = "ee120102", suffix = 29, expected = Fails (InvalidWireType 6) [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 301 ) ] 144 }
    , { seed = AllTypes, label = "field 0 at (16,)", prefix = 144, middle = "0201", suffix = 29, expected = Fails InvalidTag [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 0 ) ] 144 }
    , { seed = AllTypes, label = "wire 7 at (16, 0)", prefix = 147, middle = "0f0102", suffix = 31, expected = Fails (InvalidWireType 7) [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 301 ), ( "google.protobuf.Duration", 1 ) ] 147 }
    , { seed = AllTypes, label = "long varint at (16, 0)", prefix = 146, middle = "0e088080808080808080808001", suffix = 31, expected = Fails MalformedVarint [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 301 ), ( "google.protobuf.Duration", 1 ) ] 148 }
    , { seed = AllTypes, label = "wire 3 at (16, 1)", prefix = 146, middle = "0608901c130102", suffix = 29, expected = Fails (InvalidWireType 3) [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 301 ), ( "google.protobuf.Duration", 2 ) ] 150 }
    , { seed = AllTypes, label = "long varint at (16, 1)", prefix = 146, middle = "0f08901c108080808080808080808001", suffix = 29, expected = Fails MalformedVarint [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 301 ), ( "google.protobuf.Duration", 2 ) ] 151 }
    , { seed = AllTypes, label = "wire 4 at (17,)", prefix = 152, middle = "f4120102", suffix = 18, expected = Fails (InvalidWireType 4) [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 302 ) ] 152 }
    , { seed = AllTypes, label = "field 0 at (17,)", prefix = 152, middle = "0201", suffix = 18, expected = Fails InvalidTag [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 0 ) ] 152 }
    , { seed = AllTypes, label = "wire 6 at (17, 0)", prefix = 154, middle = "050e0102", suffix = 20, expected = Fails (InvalidWireType 6) [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 302 ), ( "google.protobuf.Timestamp", 1 ) ] 155 }
    , { seed = AllTypes, label = "long varint at (17, 0)", prefix = 154, middle = "0e088080808080808080808001", suffix = 20, expected = Fails MalformedVarint [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 302 ), ( "google.protobuf.Timestamp", 1 ) ] 156 }
    , { seed = AllTypes, label = "wire 7 at (17, 1)", prefix = 154, middle = "090880e2cfaa06170102", suffix = 18, expected = Fails (InvalidWireType 7) [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 302 ), ( "google.protobuf.Timestamp", 2 ) ] 161 }
    , { seed = AllTypes, label = "long varint at (17, 1)", prefix = 154, middle = "120880e2cfaa06108080808080808080808001", suffix = 18, expected = Fails MalformedVarint [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 302 ), ( "google.protobuf.Timestamp", 2 ) ] 162 }
    , { seed = AllTypes, label = "wire 3 at (18,)", prefix = 163, middle = "83130102", suffix = 5, expected = Fails (InvalidWireType 3) [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 304 ) ] 163 }
    , { seed = AllTypes, label = "field 0 at (18,)", prefix = 163, middle = "0201", suffix = 5, expected = Fails InvalidTag [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 0 ) ] 163 }
    , { seed = AllTypes, label = "wire 4 at (18, 0)", prefix = 165, middle = "030c0102", suffix = 5, expected = Fails (InvalidWireType 4) [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 304 ), ( "google.protobuf.Struct", 1 ) ] 166 }
    , { seed = AllTypes, label = "wire 6 at (18, 0, 0)", prefix = 168, middle = "0e0102", suffix = 10, expected = Fails (InvalidWireType 6) [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 304 ), ( "google.protobuf.Struct", 1 ) ] 168 }
    , { seed = AllTypes, label = "overrun at (18, 0, 0)", prefix = 169, middle = "046b12031a017392130220017a14747261696c696e67206279746573206166746572", suffix = 0, expected = Fails InvalidTag [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 304 ), ( "google.protobuf.Struct", 1 ) ] 174 }
    , { seed = AllTypes, label = "wire 7 at (18, 0, 1)", prefix = 165, middle = "080a060a016b170102", suffix = 5, expected = Fails (InvalidWireType 7) [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 304 ), ( "google.protobuf.Struct", 1 ) ] 171 }
    , { seed = AllTypes, label = "field 0 at (18, 0, 1)", prefix = 165, middle = "070a050a016b0201", suffix = 5, expected = Fails InvalidTag [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 304 ), ( "google.protobuf.Struct", 1 ) ] 171 }
    , { seed = AllTypes, label = "wire 3 at (18, 0, 1, 0)", prefix = 173, middle = "1b0102", suffix = 5, expected = Fails (InvalidWireType 3) [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 304 ), ( "google.protobuf.Struct", 1 ), ( "google.protobuf.Value", 3 ) ] 173 }
    , { seed = AllTypes, label = "overrun at (18, 0, 1, 0)", prefix = 174, middle = "047392130220017a14747261696c696e67206279746573206166746572", suffix = 0, expected = Fails LengthOverrun [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 304 ), ( "google.protobuf.Struct", 1 ), ( "google.protobuf.Value", 3 ) ] 174 }
    , { seed = AllTypes, label = "wire 4 at (19,)", prefix = 176, middle = "94130102", suffix = 0, expected = Fails (InvalidWireType 4) [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 306 ) ] 176 }
    , { seed = AllTypes, label = "wire 6 at (19, 0)", prefix = 178, middle = "03260102", suffix = 0, expected = Fails (InvalidWireType 6) [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 306 ), ( "google.protobuf.Value", 4 ) ] 179 }
    , { seed = AllTypes, label = "field 0 at (19, 0)", prefix = 179, middle = "00", suffix = 1, expected = Fails InvalidTag [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 306 ), ( "google.protobuf.Value", 0 ) ] 179 }
    , { seed = AllTypes, label = "long varint at (19, 0)", prefix = 178, middle = "0c2080808080808080808080", suffix = 1, expected = Fails MalformedVarint [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 306 ), ( "google.protobuf.Value", 4 ) ] 180 }
    , { seed = AllTypes, label = "key cut at end", prefix = 181, middle = "80", suffix = 0, expected = Fails Truncated [] 181 }
    , { seed = AllTypes, label = "long key at end", prefix = 181, middle = "8080808080808080808080", suffix = 0, expected = Fails MalformedVarint [] 181 }
    , { seed = AllTypes, label = "unknown field length past end", prefix = 181, middle = "4ae807616263", suffix = 0, expected = Fails Truncated [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 9 ) ] 182 }
    , { seed = AllTypes, label = "group start at end", prefix = 181, middle = "4b", suffix = 0, expected = Fails (InvalidWireType 3) [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 9 ) ] 181 }
    , { seed = AllTypes, label = "fixed64 cut at end", prefix = 181, middle = "490102", suffix = 0, expected = Fails Truncated [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 9 ) ] 182 }
    , { seed = Plain, label = "key cut at nested end", prefix = 33, middle = "c5020a2841206e6f74652061626f757420746865207765656b6c7920706c616e6e696e67206d656574696e6712f8014c6f72656d20697073756d20646f6c6f722073697420616d65742c20636f6e73656374657475722061646970697363696e6720656c69742c2073656420646f20656975736d6f642074656d706f7220696e6369646964756e74207574206c61626f726520657420646f6c6f7265206d61676e6120616c697175612e204c6f72656d20697073756d20646f6c6f722073697420616d65742c20636f6e73656374657475722061646970697363696e6720656c69742c2073656420646f20656975736d6f642074656d706f7220696e6369646964756e74207574206c61626f726520657420646f6c6f7265206d61676e6120616c697175612e201a08706c616e6e696e671a067765656b6c791a047465616d20959aef3a280180", suffix = 33, expected = Fails LengthOverrun [ ( "bench.v1.Plain", 3 ) ] 359 }
    , { seed = Plain, label = "fixed64 cut by nested end", prefix = 33, middle = "c8020a2841206e6f74652061626f757420746865207765656b6c7920706c616e6e696e67206d656574696e6712f8014c6f72656d20697073756d20646f6c6f722073697420616d65742c20636f6e73656374657475722061646970697363696e6720656c69742c2073656420646f20656975736d6f642074656d706f7220696e6369646964756e74207574206c61626f726520657420646f6c6f7265206d61676e6120616c697175612e204c6f72656d20697073756d20646f6c6f722073697420616d65742c20636f6e73656374657475722061646970697363696e6720656c69742c2073656420646f20656975736d6f642074656d706f7220696e6369646964756e74207574206c61626f726520657420646f6c6f7265206d61676e6120616c697175612e201a08706c616e6e696e671a067765656b6c791a047465616d20959aef3a280149010203", suffix = 33, expected = Fails LengthOverrun [ ( "bench.v1.Plain", 3 ), ( "bench.v1.Payload", 9 ) ] 360 }
    , { seed = Envelope, label = "wire 7 in Any", prefix = 33, middle = "ee020a24747970652e676f6f676c65617069732e636f6d2f62656e63682e76312e5061796c6f616412c4020a2841206e6f74652061626f757420746865207765656b6c7920706c616e6e696e67206d656574696e6712f8014c6f72656d20697073756d20646f6c6f722073697420616d65742c20636f6e73656374657475722061646970697363696e6720656c69742c2073656420646f20656975736d6f642074656d706f7220696e6369646964756e74207574206c61626f726520657420646f6c6f7265206d61676e6120616c697175612e204c6f72656d20697073756d20646f6c6f722073697420616d65742c20636f6e73656374657475722061646970697363696e6720656c69742c2073656420646f20656975736d6f642074656d706f7220696e6369646964756e74207574206c61626f726520657420646f6c6f7265206d61676e6120616c697175612e201a08706c616e6e696e671a067765656b6c791a047465616d20959aef3a28011f", suffix = 33, expected = Fails (InvalidWireType 7) [ ( "bench.v1.Envelope", 3 ), ( "google.protobuf.Any", 3 ) ] 400 }
    , { seed = Envelope, label = "long varint in Any", prefix = 33, middle = "f9020a24747970652e676f6f676c65617069732e636f6d2f62656e63682e76312e5061796c6f616412c4020a2841206e6f74652061626f757420746865207765656b6c7920706c616e6e696e67206d656574696e6712f8014c6f72656d20697073756d20646f6c6f722073697420616d65742c20636f6e73656374657475722061646970697363696e6720656c69742c2073656420646f20656975736d6f642074656d706f7220696e6369646964756e74207574206c61626f726520657420646f6c6f7265206d61676e6120616c697175612e204c6f72656d20697073756d20646f6c6f722073697420616d65742c20636f6e73656374657475722061646970697363696e6720656c69742c2073656420646f20656975736d6f642074656d706f7220696e6369646964756e74207574206c61626f726520657420646f6c6f7265206d61676e6120616c697175612e201a08706c616e6e696e671a067765656b6c791a047465616d20959aef3a280118ffffffffffffffffffff", suffix = 34, expected = Fails MalformedVarint [ ( "bench.v1.Envelope", 3 ), ( "google.protobuf.Any", 3 ) ] 401 }
    , { seed = AllTypes, label = "packed varint cut by run end", prefix = 52, middle = "11019601e0a712ffffffffffffffffff0180", suffix = 112, expected = Fails LengthOverrun [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 31 ) ] 69 }
    , { seed = AllTypes, label = "packed long varint", prefix = 52, middle = "1b019601e0a712ffffffffffffffffff0180808080808080808080", suffix = 113, expected = Fails MalformedVarint [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 31 ) ] 69 }
    , { seed = AllTypes, label = "packed fixed64 cut by run end", prefix = 114, middle = "1a0100000000000000020000000000000003000000000000000102", suffix = 42, expected = Fails LengthOverrun [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 82 ) ] 139 }
    , { seed = AllTypes, label = "wire 7 in map entry", prefix = 97, middle = "03080117", suffix = 79, expected = Fails (InvalidWireType 7) [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 56 ) ] 100 }
    , { seed = AllTypes, label = "field 0 in map entry", prefix = 99, middle = "010001", suffix = 79, expected = Fails InvalidTag [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 56 ) ] 100 }
    , { seed = AllTypes, label = "map value cut by entry end", prefix = 97, middle = "03080110", suffix = 79, expected = Fails LengthOverrun [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 56 ) ] 101 }
    , { seed = AllTypes, label = "wire 6 in map value message", prefix = 104, middle = "080a016b1203080516", suffix = 69, expected = Fails (InvalidWireType 6) [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 71 ), ( "protobuf_test_messages.proto3.TestAllTypesProto3.NestedMessage", 2 ) ] 112 }
    , { seed = AllTypes, label = "wire 3 in Struct value", prefix = 165, middle = "0b0a090a016b12041a01732b", suffix = 5, expected = Fails (InvalidWireType 3) [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 304 ), ( "google.protobuf.Struct", 1 ), ( "google.protobuf.Value", 5 ) ] 176 }
    , { seed = AllTypes, label = "Timestamp seconds 2^60", prefix = 154, middle = "0a08808080808080808010", suffix = 18, expected = Fails IntOutOfRange [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 302 ), ( "google.protobuf.Timestamp", 1 ) ] 156 }
    , { seed = AllTypes, label = "Duration seconds -2^60", prefix = 146, middle = "0b088080808080808080f001", suffix = 29, expected = Fails IntOutOfRange [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 301 ), ( "google.protobuf.Duration", 1 ) ] 148 }
    , { seed = AllTypes, label = "Timestamp seconds 2^53", prefix = 154, middle = "09088080808080808010", suffix = 18, expected = Fails IntOutOfRange [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 302 ), ( "google.protobuf.Timestamp", 1 ) ] 156 }
    , { seed = AllTypes, label = "control: Timestamp seconds 2^53 - 1", prefix = 154, middle = "0908ffffffffffffff0f", suffix = 18, expected = Decodes }
    , { seed = AllTypes, label = "control: Duration seconds -(2^53 - 1)", prefix = 146, middle = "0b0881808080808080f0ff01", suffix = 29, expected = Decodes }
    , { seed = AllTypes, label = "Timestamp out of range two deep", prefix = 36, middle = "130807120f0808f2120a08808080808080808010", suffix = 131, expected = Fails IntOutOfRange [ ( "protobuf_test_messages.proto3.TestAllTypesProto3", 18 ), ( "protobuf_test_messages.proto3.TestAllTypesProto3.NestedMessage", 2 ), ( "protobuf_test_messages.proto3.TestAllTypesProto3", 302 ), ( "google.protobuf.Timestamp", 1 ) ] 47 }
    , { seed = AllTypes, label = "control: int64 -1", prefix = 3, middle = "ff", suffix = 177, expected = Decodes }
    , { seed = Plain, label = "utf8: lead byte at end of input", prefix = 360, middle = "036162c3", suffix = 0, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 4 ) ] 360 }
    , { seed = Plain, label = "utf8: lead byte mid message", prefix = 1, middle = "036162e2", suffix = 376, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 1 ) ] 1 }
    , { seed = Plain, label = "utf8: lead byte mid nested", prefix = 33, middle = "9e020a0278f0", suffix = 315, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 3 ), ( "bench.v1.Payload", 1 ) ] 36 }
    , { seed = Plain, label = "utf8: ascii mid", prefix = 0, middle = "0a05616278636422026f6b", suffix = 0, expected = Decodes }
    , { seed = Plain, label = "utf8: ascii end", prefix = 0, middle = "0a0361627822026f6b", suffix = 0, expected = Decodes }
    , { seed = Plain, label = "utf8: ascii long", prefix = 0, middle = "0a256162636465666768696a6b6c6d6e6f70717872737475767778797a3031323334353637383922026f6b", suffix = 0, expected = Decodes }
    , { seed = Plain, label = "utf8: U+00E9 mid", prefix = 0, middle = "0a066162c3a9636422026f6b", suffix = 0, expected = Decodes }
    , { seed = Plain, label = "utf8: U+00E9 end", prefix = 0, middle = "0a046162c3a922026f6b", suffix = 0, expected = Decodes }
    , { seed = Plain, label = "utf8: U+00E9 long", prefix = 0, middle = "0a266162636465666768696a6b6c6d6e6f7071c3a972737475767778797a3031323334353637383922026f6b", suffix = 0, expected = Decodes }
    , { seed = Plain, label = "utf8: U+0800 mid", prefix = 0, middle = "0a076162e0a080636422026f6b", suffix = 0, expected = Decodes }
    , { seed = Plain, label = "utf8: U+0800 end", prefix = 0, middle = "0a056162e0a08022026f6b", suffix = 0, expected = Decodes }
    , { seed = Plain, label = "utf8: U+0800 long", prefix = 0, middle = "0a276162636465666768696a6b6c6d6e6f7071e0a08072737475767778797a3031323334353637383922026f6b", suffix = 0, expected = Decodes }
    , { seed = Plain, label = "utf8: U+D7FF mid", prefix = 0, middle = "0a076162ed9fbf636422026f6b", suffix = 0, expected = Decodes }
    , { seed = Plain, label = "utf8: U+D7FF end", prefix = 0, middle = "0a056162ed9fbf22026f6b", suffix = 0, expected = Decodes }
    , { seed = Plain, label = "utf8: U+D7FF long", prefix = 0, middle = "0a276162636465666768696a6b6c6d6e6f7071ed9fbf72737475767778797a3031323334353637383922026f6b", suffix = 0, expected = Decodes }
    , { seed = Plain, label = "utf8: U+E000 mid", prefix = 0, middle = "0a076162ee8080636422026f6b", suffix = 0, expected = Decodes }
    , { seed = Plain, label = "utf8: U+E000 end", prefix = 0, middle = "0a056162ee808022026f6b", suffix = 0, expected = Decodes }
    , { seed = Plain, label = "utf8: U+E000 long", prefix = 0, middle = "0a276162636465666768696a6b6c6d6e6f7071ee808072737475767778797a3031323334353637383922026f6b", suffix = 0, expected = Decodes }
    , { seed = Plain, label = "utf8: U+FFFF mid", prefix = 0, middle = "0a076162efbfbf636422026f6b", suffix = 0, expected = Decodes }
    , { seed = Plain, label = "utf8: U+FFFF end", prefix = 0, middle = "0a056162efbfbf22026f6b", suffix = 0, expected = Decodes }
    , { seed = Plain, label = "utf8: U+FFFF long", prefix = 0, middle = "0a276162636465666768696a6b6c6d6e6f7071efbfbf72737475767778797a3031323334353637383922026f6b", suffix = 0, expected = Decodes }
    , { seed = Plain, label = "utf8: U+10000 mid", prefix = 0, middle = "0a086162f0908080636422026f6b", suffix = 0, expected = Decodes }
    , { seed = Plain, label = "utf8: U+10000 end", prefix = 0, middle = "0a066162f090808022026f6b", suffix = 0, expected = Decodes }
    , { seed = Plain, label = "utf8: U+10000 long", prefix = 0, middle = "0a286162636465666768696a6b6c6d6e6f7071f090808072737475767778797a3031323334353637383922026f6b", suffix = 0, expected = Decodes }
    , { seed = Plain, label = "utf8: U+1F600 mid", prefix = 0, middle = "0a086162f09f9880636422026f6b", suffix = 0, expected = Decodes }
    , { seed = Plain, label = "utf8: U+1F600 end", prefix = 0, middle = "0a066162f09f988022026f6b", suffix = 0, expected = Decodes }
    , { seed = Plain, label = "utf8: U+1F600 long", prefix = 0, middle = "0a286162636465666768696a6b6c6d6e6f7071f09f988072737475767778797a3031323334353637383922026f6b", suffix = 0, expected = Decodes }
    , { seed = Plain, label = "utf8: U+10FFFF mid", prefix = 0, middle = "0a086162f48fbfbf636422026f6b", suffix = 0, expected = Decodes }
    , { seed = Plain, label = "utf8: U+10FFFF end", prefix = 0, middle = "0a066162f48fbfbf22026f6b", suffix = 0, expected = Decodes }
    , { seed = Plain, label = "utf8: U+10FFFF long", prefix = 0, middle = "0a286162636465666768696a6b6c6d6e6f7071f48fbfbf72737475767778797a3031323334353637383922026f6b", suffix = 0, expected = Decodes }
    , { seed = Plain, label = "utf8: overlong 2 (C0 80) mid", prefix = 0, middle = "0a066162c080636422026f6b", suffix = 0, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 1 ) ] 1 }
    , { seed = Plain, label = "utf8: overlong 2 (C0 80) end", prefix = 0, middle = "0a046162c08022026f6b", suffix = 0, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 1 ) ] 1 }
    , { seed = Plain, label = "utf8: overlong 2 (C0 80) long", prefix = 0, middle = "0a266162636465666768696a6b6c6d6e6f7071c08072737475767778797a3031323334353637383922026f6b", suffix = 0, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 1 ) ] 1 }
    , { seed = Plain, label = "utf8: overlong 2 (C1 BF) mid", prefix = 0, middle = "0a066162c1bf636422026f6b", suffix = 0, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 1 ) ] 1 }
    , { seed = Plain, label = "utf8: overlong 2 (C1 BF) end", prefix = 0, middle = "0a046162c1bf22026f6b", suffix = 0, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 1 ) ] 1 }
    , { seed = Plain, label = "utf8: overlong 2 (C1 BF) long", prefix = 0, middle = "0a266162636465666768696a6b6c6d6e6f7071c1bf72737475767778797a3031323334353637383922026f6b", suffix = 0, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 1 ) ] 1 }
    , { seed = Plain, label = "utf8: overlong 3 (E0 80 80) mid", prefix = 0, middle = "0a076162e08080636422026f6b", suffix = 0, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 1 ) ] 1 }
    , { seed = Plain, label = "utf8: overlong 3 (E0 80 80) end", prefix = 0, middle = "0a056162e0808022026f6b", suffix = 0, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 1 ) ] 1 }
    , { seed = Plain, label = "utf8: overlong 3 (E0 80 80) long", prefix = 0, middle = "0a276162636465666768696a6b6c6d6e6f7071e0808072737475767778797a3031323334353637383922026f6b", suffix = 0, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 1 ) ] 1 }
    , { seed = Plain, label = "utf8: overlong 3 (E0 9F BF) mid", prefix = 0, middle = "0a076162e09fbf636422026f6b", suffix = 0, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 1 ) ] 1 }
    , { seed = Plain, label = "utf8: overlong 3 (E0 9F BF) end", prefix = 0, middle = "0a056162e09fbf22026f6b", suffix = 0, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 1 ) ] 1 }
    , { seed = Plain, label = "utf8: overlong 3 (E0 9F BF) long", prefix = 0, middle = "0a276162636465666768696a6b6c6d6e6f7071e09fbf72737475767778797a3031323334353637383922026f6b", suffix = 0, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 1 ) ] 1 }
    , { seed = Plain, label = "utf8: overlong 4 (F0 80 80 80) mid", prefix = 0, middle = "0a086162f0808080636422026f6b", suffix = 0, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 1 ) ] 1 }
    , { seed = Plain, label = "utf8: overlong 4 (F0 80 80 80) end", prefix = 0, middle = "0a066162f080808022026f6b", suffix = 0, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 1 ) ] 1 }
    , { seed = Plain, label = "utf8: overlong 4 (F0 80 80 80) long", prefix = 0, middle = "0a286162636465666768696a6b6c6d6e6f7071f080808072737475767778797a3031323334353637383922026f6b", suffix = 0, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 1 ) ] 1 }
    , { seed = Plain, label = "utf8: overlong 4 (F0 8F BF BF) mid", prefix = 0, middle = "0a086162f08fbfbf636422026f6b", suffix = 0, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 1 ) ] 1 }
    , { seed = Plain, label = "utf8: overlong 4 (F0 8F BF BF) end", prefix = 0, middle = "0a066162f08fbfbf22026f6b", suffix = 0, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 1 ) ] 1 }
    , { seed = Plain, label = "utf8: overlong 4 (F0 8F BF BF) long", prefix = 0, middle = "0a286162636465666768696a6b6c6d6e6f7071f08fbfbf72737475767778797a3031323334353637383922026f6b", suffix = 0, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 1 ) ] 1 }
    , { seed = Plain, label = "utf8: high surrogate (ED A0 80) mid", prefix = 0, middle = "0a076162eda080636422026f6b", suffix = 0, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 1 ) ] 1 }
    , { seed = Plain, label = "utf8: high surrogate (ED A0 80) end", prefix = 0, middle = "0a056162eda08022026f6b", suffix = 0, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 1 ) ] 1 }
    , { seed = Plain, label = "utf8: high surrogate (ED A0 80) long", prefix = 0, middle = "0a276162636465666768696a6b6c6d6e6f7071eda08072737475767778797a3031323334353637383922026f6b", suffix = 0, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 1 ) ] 1 }
    , { seed = Plain, label = "utf8: low surrogate (ED B0 80) mid", prefix = 0, middle = "0a076162edb080636422026f6b", suffix = 0, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 1 ) ] 1 }
    , { seed = Plain, label = "utf8: low surrogate (ED B0 80) end", prefix = 0, middle = "0a056162edb08022026f6b", suffix = 0, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 1 ) ] 1 }
    , { seed = Plain, label = "utf8: low surrogate (ED B0 80) long", prefix = 0, middle = "0a276162636465666768696a6b6c6d6e6f7071edb08072737475767778797a3031323334353637383922026f6b", suffix = 0, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 1 ) ] 1 }
    , { seed = Plain, label = "utf8: low surrogate (ED BF BF) mid", prefix = 0, middle = "0a076162edbfbf636422026f6b", suffix = 0, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 1 ) ] 1 }
    , { seed = Plain, label = "utf8: low surrogate (ED BF BF) end", prefix = 0, middle = "0a056162edbfbf22026f6b", suffix = 0, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 1 ) ] 1 }
    , { seed = Plain, label = "utf8: low surrogate (ED BF BF) long", prefix = 0, middle = "0a276162636465666768696a6b6c6d6e6f7071edbfbf72737475767778797a3031323334353637383922026f6b", suffix = 0, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 1 ) ] 1 }
    , { seed = Plain, label = "utf8: surrogate pair, CESU (ED A0 BD ED B8 80) mid", prefix = 0, middle = "0a0a6162eda0bdedb880636422026f6b", suffix = 0, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 1 ) ] 1 }
    , { seed = Plain, label = "utf8: surrogate pair, CESU (ED A0 BD ED B8 80) end", prefix = 0, middle = "0a086162eda0bdedb88022026f6b", suffix = 0, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 1 ) ] 1 }
    , { seed = Plain, label = "utf8: surrogate pair, CESU (ED A0 BD ED B8 80) long", prefix = 0, middle = "0a2a6162636465666768696a6b6c6d6e6f7071eda0bdedb88072737475767778797a3031323334353637383922026f6b", suffix = 0, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 1 ) ] 1 }
    , { seed = Plain, label = "utf8: past U+10FFFF (F4 90 80 80) mid", prefix = 0, middle = "0a086162f4908080636422026f6b", suffix = 0, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 1 ) ] 1 }
    , { seed = Plain, label = "utf8: past U+10FFFF (F4 90 80 80) end", prefix = 0, middle = "0a066162f490808022026f6b", suffix = 0, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 1 ) ] 1 }
    , { seed = Plain, label = "utf8: past U+10FFFF (F4 90 80 80) long", prefix = 0, middle = "0a286162636465666768696a6b6c6d6e6f7071f490808072737475767778797a3031323334353637383922026f6b", suffix = 0, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 1 ) ] 1 }
    , { seed = Plain, label = "utf8: lead F5 (F5 80 80 80) mid", prefix = 0, middle = "0a086162f5808080636422026f6b", suffix = 0, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 1 ) ] 1 }
    , { seed = Plain, label = "utf8: lead F5 (F5 80 80 80) end", prefix = 0, middle = "0a066162f580808022026f6b", suffix = 0, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 1 ) ] 1 }
    , { seed = Plain, label = "utf8: lead F5 (F5 80 80 80) long", prefix = 0, middle = "0a286162636465666768696a6b6c6d6e6f7071f580808072737475767778797a3031323334353637383922026f6b", suffix = 0, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 1 ) ] 1 }
    , { seed = Plain, label = "utf8: lone continuation (80) mid", prefix = 0, middle = "0a05616280636422026f6b", suffix = 0, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 1 ) ] 1 }
    , { seed = Plain, label = "utf8: lone continuation (80) end", prefix = 0, middle = "0a0361628022026f6b", suffix = 0, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 1 ) ] 1 }
    , { seed = Plain, label = "utf8: lone continuation (80) long", prefix = 0, middle = "0a256162636465666768696a6b6c6d6e6f70718072737475767778797a3031323334353637383922026f6b", suffix = 0, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 1 ) ] 1 }
    , { seed = Plain, label = "utf8: two continuations (80 BF) mid", prefix = 0, middle = "0a06616280bf636422026f6b", suffix = 0, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 1 ) ] 1 }
    , { seed = Plain, label = "utf8: two continuations (80 BF) end", prefix = 0, middle = "0a04616280bf22026f6b", suffix = 0, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 1 ) ] 1 }
    , { seed = Plain, label = "utf8: two continuations (80 BF) long", prefix = 0, middle = "0a266162636465666768696a6b6c6d6e6f707180bf72737475767778797a3031323334353637383922026f6b", suffix = 0, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 1 ) ] 1 }
    , { seed = Plain, label = "utf8: bad continuation (C3 41) mid", prefix = 0, middle = "0a066162c341636422026f6b", suffix = 0, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 1 ) ] 1 }
    , { seed = Plain, label = "utf8: bad continuation (C3 41) end", prefix = 0, middle = "0a046162c34122026f6b", suffix = 0, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 1 ) ] 1 }
    , { seed = Plain, label = "utf8: bad continuation (C3 41) long", prefix = 0, middle = "0a266162636465666768696a6b6c6d6e6f7071c34172737475767778797a3031323334353637383922026f6b", suffix = 0, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 1 ) ] 1 }
    , { seed = Plain, label = "utf8: bad continuation (E2 82 41) mid", prefix = 0, middle = "0a076162e28241636422026f6b", suffix = 0, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 1 ) ] 1 }
    , { seed = Plain, label = "utf8: bad continuation (E2 82 41) end", prefix = 0, middle = "0a056162e2824122026f6b", suffix = 0, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 1 ) ] 1 }
    , { seed = Plain, label = "utf8: bad continuation (E2 82 41) long", prefix = 0, middle = "0a276162636465666768696a6b6c6d6e6f7071e2824172737475767778797a3031323334353637383922026f6b", suffix = 0, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 1 ) ] 1 }
    , { seed = Plain, label = "utf8: bad continuation (F0 9F 98 41) mid", prefix = 0, middle = "0a086162f09f9841636422026f6b", suffix = 0, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 1 ) ] 1 }
    , { seed = Plain, label = "utf8: bad continuation (F0 9F 98 41) end", prefix = 0, middle = "0a066162f09f984122026f6b", suffix = 0, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 1 ) ] 1 }
    , { seed = Plain, label = "utf8: bad continuation (F0 9F 98 41) long", prefix = 0, middle = "0a286162636465666768696a6b6c6d6e6f7071f09f984172737475767778797a3031323334353637383922026f6b", suffix = 0, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 1 ) ] 1 }
    , { seed = Plain, label = "utf8: continuation C0-range (C3 C3) mid", prefix = 0, middle = "0a066162c3c3636422026f6b", suffix = 0, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 1 ) ] 1 }
    , { seed = Plain, label = "utf8: continuation C0-range (C3 C3) end", prefix = 0, middle = "0a046162c3c322026f6b", suffix = 0, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 1 ) ] 1 }
    , { seed = Plain, label = "utf8: continuation C0-range (C3 C3) long", prefix = 0, middle = "0a266162636465666768696a6b6c6d6e6f7071c3c372737475767778797a3031323334353637383922026f6b", suffix = 0, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 1 ) ] 1 }
    , { seed = Plain, label = "utf8: cut 3-byte (E2 82) mid", prefix = 0, middle = "0a066162e282636422026f6b", suffix = 0, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 1 ) ] 1 }
    , { seed = Plain, label = "utf8: cut 3-byte (E2 82) end", prefix = 0, middle = "0a046162e28222026f6b", suffix = 0, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 1 ) ] 1 }
    , { seed = Plain, label = "utf8: cut 3-byte (E2 82) long", prefix = 0, middle = "0a266162636465666768696a6b6c6d6e6f7071e28272737475767778797a3031323334353637383922026f6b", suffix = 0, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 1 ) ] 1 }
    , { seed = Plain, label = "utf8: cut 4-byte (F0 9F 98) mid", prefix = 0, middle = "0a076162f09f98636422026f6b", suffix = 0, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 1 ) ] 1 }
    , { seed = Plain, label = "utf8: cut 4-byte (F0 9F 98) end", prefix = 0, middle = "0a056162f09f9822026f6b", suffix = 0, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 1 ) ] 1 }
    , { seed = Plain, label = "utf8: cut 4-byte (F0 9F 98) long", prefix = 0, middle = "0a276162636465666768696a6b6c6d6e6f7071f09f9872737475767778797a3031323334353637383922026f6b", suffix = 0, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 1 ) ] 1 }
    , { seed = Plain, label = "utf8: lead alone (C3) mid", prefix = 0, middle = "0a056162c3636422026f6b", suffix = 0, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 1 ) ] 1 }
    , { seed = Plain, label = "utf8: lead alone (C3) end", prefix = 0, middle = "0a036162c322026f6b", suffix = 0, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 1 ) ] 1 }
    , { seed = Plain, label = "utf8: lead alone (C3) long", prefix = 0, middle = "0a256162636465666768696a6b6c6d6e6f7071c372737475767778797a3031323334353637383922026f6b", suffix = 0, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 1 ) ] 1 }
    , { seed = Plain, label = "utf8: FE mid", prefix = 0, middle = "0a056162fe636422026f6b", suffix = 0, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 1 ) ] 1 }
    , { seed = Plain, label = "utf8: FE end", prefix = 0, middle = "0a036162fe22026f6b", suffix = 0, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 1 ) ] 1 }
    , { seed = Plain, label = "utf8: FE long", prefix = 0, middle = "0a256162636465666768696a6b6c6d6e6f7071fe72737475767778797a3031323334353637383922026f6b", suffix = 0, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 1 ) ] 1 }
    , { seed = Plain, label = "utf8: FF mid", prefix = 0, middle = "0a056162ff636422026f6b", suffix = 0, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 1 ) ] 1 }
    , { seed = Plain, label = "utf8: FF end", prefix = 0, middle = "0a036162ff22026f6b", suffix = 0, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 1 ) ] 1 }
    , { seed = Plain, label = "utf8: FF long", prefix = 0, middle = "0a256162636465666768696a6b6c6d6e6f7071ff72737475767778797a3031323334353637383922026f6b", suffix = 0, expected = Fails InvalidUtf8 [ ( "bench.v1.Plain", 1 ) ] 1 }
    ]
