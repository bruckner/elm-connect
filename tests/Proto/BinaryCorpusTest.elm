module Proto.BinaryCorpusTest exposing (suite)

{-| The binary decoder over [`Proto.BinaryCorpus`](Proto-BinaryCorpus): for
every input, its two readers fail on the same inputs, and a failure's report
(reason, path, offset) is the one the corpus expects. The decoders are
written in the generated shape for the fields the corpus reaches, with the
codecs generated code uses for them.
-}

import Bytes exposing (Bytes)
import Bytes.Decode
import Bytes.Encode
import Expect
import Proto.Binary as B
import Proto.BinaryCorpus as Corpus exposing (Case, Expected(..), Seed(..))
import Proto.Error exposing (Reason(..))
import Proto.Internal.Binary
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "Proto.Binary over the corpus"
        [ test "the fast reader fails exactly where the locating reader does" <|
            \_ ->
                List.filter (\c -> fastFails c /= locatedFails c) Corpus.cases
                    |> List.map .label
                    |> Expect.equal []
        , test "each input decodes, or fails with the report expected" <|
            \_ ->
                List.filter (\c -> outcome c /= expected c) Corpus.cases
                    |> List.map (\c -> ( c.label, outcome c ))
                    |> Expect.equal []
        , test "every reason but Unlocated is reached" <|
            \_ ->
                [ Truncated, LengthOverrun, InvalidTag, InvalidWireType 3, InvalidWireType 4, InvalidWireType 6, InvalidWireType 7, MalformedVarint, OutOfRange, InvalidUtf8 ]
                    |> List.filter (\reason -> not (List.any (\c -> reasonOf c == Just reason) Corpus.cases))
                    |> Expect.equal []
        ]


type alias Outcome =
    Result Proto.Error.Binary ()


outcome : Case -> Outcome
outcome c =
    B.decode (decoderOf c.seed) (inputOf c)


expected : Case -> Outcome
expected c =
    case c.expected of
        Decodes ->
            Ok ()

        Fails reason path offset ->
            Err { typeName = typeNameOf c.seed, reason = reason, path = path, offset = offset }


reasonOf : Case -> Maybe Reason
reasonOf c =
    case c.expected of
        Decodes ->
            Nothing

        Fails reason _ _ ->
            Just reason


fastFails : Case -> Bool
fastFails c =
    case decoderOf c.seed of
        Proto.Internal.Binary.Decoder d ->
            Bytes.Decode.decode (d.fast (Bytes.width (inputOf c))) (inputOf c) == Nothing


locatedFails : Case -> Bool
locatedFails c =
    case decoderOf c.seed of
        Proto.Internal.Binary.Decoder d ->
            case Bytes.Decode.decode (d.located (Bytes.width (inputOf c))) (inputOf c) of
                Just (Ok ()) ->
                    False

                _ ->
                    True


inputOf : Case -> Bytes
inputOf =
    Corpus.input fromHex


typeNameOf : Seed -> String
typeNameOf seed =
    case seed of
        Envelope ->
            "bench.v1.Envelope"

        Plain ->
            "bench.v1.Plain"

        AllTypes ->
            "protobuf_test_messages.proto3.TestAllTypesProto3"


decoderOf : Seed -> B.Decoder ()
decoderOf seed =
    case seed of
        Envelope ->
            envelope

        Plain ->
            plain

        AllTypes ->
            allTypes ()



-- DECODERS
--
-- Each counts nothing and keeps nothing: what fails, and where, depends only
-- on the fields' codecs.


one : B.Codec v -> Int -> a -> B.Field a
one codec wire value =
    B.field codec (\_ -> value) wire value


many : B.Codec v -> Int -> a -> B.Field a
many codec wire value =
    B.repeated codec (\_ -> value) [] wire value


message : String -> (Int -> Int -> () -> B.Field ()) -> B.Decoder ()
message name step =
    B.merge name step identity ()


embedded : (() -> B.Decoder ()) -> B.Codec ()
embedded decoder =
    B.embedded (\() -> B.sequence []) (\_ -> decoder ()) ()


payload : () -> B.Decoder ()
payload () =
    message "bench.v1.Payload"
        (\number wire value ->
            case number of
                1 ->
                    one B.string wire value

                2 ->
                    one B.string wire value

                3 ->
                    many B.string wire value

                4 ->
                    one B.int64 wire value

                5 ->
                    one B.bool wire value

                _ ->
                    B.skip wire value
        )


envelope : B.Decoder ()
envelope =
    message "bench.v1.Envelope"
        (\number wire value ->
            case number of
                1 ->
                    one B.string wire value

                2 ->
                    many B.string wire value

                3 ->
                    one B.any wire value

                4 ->
                    one B.string wire value

                _ ->
                    B.skip wire value
        )


plain : B.Decoder ()
plain =
    message "bench.v1.Plain"
        (\number wire value ->
            case number of
                1 ->
                    one B.string wire value

                2 ->
                    many B.string wire value

                3 ->
                    one (embedded payload) wire value

                4 ->
                    one B.string wire value

                _ ->
                    B.skip wire value
        )


nested : () -> B.Decoder ()
nested () =
    message "protobuf_test_messages.proto3.TestAllTypesProto3.NestedMessage"
        (\number wire value ->
            case number of
                1 ->
                    one B.int32 wire value

                2 ->
                    one (embedded allTypes) wire value

                _ ->
                    B.skip wire value
        )


allTypes : () -> B.Decoder ()
allTypes () =
    message "protobuf_test_messages.proto3.TestAllTypesProto3"
        (\number wire value ->
            case number of
                1 ->
                    one B.int32 wire value

                2 ->
                    one B.int64 wire value

                12 ->
                    one B.double wire value

                14 ->
                    one B.string wire value

                15 ->
                    one B.bytes wire value

                18 ->
                    one (embedded nested) wire value

                31 ->
                    many B.int32 wire value

                44 ->
                    many B.string wire value

                48 ->
                    many (embedded nested) wire value

                56 ->
                    B.mapEntry B.int32 B.int32 (\_ _ -> value) wire value

                71 ->
                    B.mapEntry B.string (embedded nested) (\_ _ -> value) wire value

                82 ->
                    many B.fixed64 wire value

                202 ->
                    one B.int32Value wire value

                301 ->
                    one B.duration wire value

                302 ->
                    one B.timestamp wire value

                304 ->
                    one B.struct wire value

                306 ->
                    one B.value wire value

                _ ->
                    B.skip wire value
        )


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
    Bytes.Encode.encode (Bytes.Encode.sequence (go (String.toList text) []))
