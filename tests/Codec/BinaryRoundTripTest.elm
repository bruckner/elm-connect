module Codec.BinaryRoundTripTest exposing (suite)

{-| The generated binary codecs of `conformance/codec/codec.proto`, under each
option set that has them, run on the protobuf binary of every sample, which
`crates/elm-connect-gen/tests/codec.rs` checks prost-reflect reads back as
the sample (`Codec.BinaryRoundTrip` lists what each sample's tests check).
-}

import Codec.BinaryRoundTrip
import Generated.Codec.Codecs
import Generated.Codec.Data
import Generated.Codec.DataInt64Int
import Test exposing (Test, describe)


suite : Test
suite =
    describe "the generated binary codecs against prost-reflect"
        [ Codec.BinaryRoundTrip.suite "codec=both" Generated.Codec.Codecs.bothBinary Generated.Codec.Data.samples
        , Codec.BinaryRoundTrip.suite "codec=both, int64=int" Generated.Codec.Codecs.bothInt64IntBinary Generated.Codec.DataInt64Int.samples
        , Codec.BinaryRoundTrip.suite "codec=both, bytes=bytes" Generated.Codec.Codecs.bothBytesBytesBinary Generated.Codec.Data.samples
        , Codec.BinaryRoundTrip.suite "codec=binary" Generated.Codec.Codecs.binaryBinary Generated.Codec.Data.samples
        ]
