module Codec.RoundTripTest exposing (suite)

{-| The generated codecs of `conformance/codec/codec.proto`, under each option
set, run on the JSON prost-reflect wrote for every sample
(`crates/elm-connect-gen/tests/codec.rs`): each form decodes and re-encodes as
expected. The few differences the design allows between what the encoders
write and what prost-reflect writes are applied to the expectation there,
each listed with its section (`allowed_differences`). Then what the option
sets change, by hand.
-}

import Codec.RoundTrip exposing (Codec, codec, roundTrip)
import Expect
import Generated.Codec.BytesBytes.Codec.V1 as BytesBytes
import Generated.Codec.Codecs
import Generated.Codec.Data
import Generated.Codec.DataInt64Int
import Generated.Codec.Default.Codec.V1 as Default
import Generated.Codec.EnumZero.Codec.V1 as EnumZero
import Generated.Codec.Int64Int.Codec.V1 as Int64Int
import Json.Encode
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "the generated codecs against prost-reflect"
        [ Codec.RoundTrip.suite "default options" Generated.Codec.Codecs.default Generated.Codec.Data.samples
        , Codec.RoundTrip.suite "int64=int" Generated.Codec.Codecs.int64Int Generated.Codec.DataInt64Int.samples
        , Codec.RoundTrip.suite "enum_unknown=zero" Generated.Codec.Codecs.enumZero Generated.Codec.Data.samples
        , Codec.RoundTrip.suite "bytes=bytes" Generated.Codec.Codecs.bytesBytes Generated.Codec.Data.samples
        , options
        ]


scalars : { default : Codec, int64Int : Codec, enumZero : Codec, bytesBytes : Codec }
scalars =
    { default = codec Default.decodeScalars Default.encodeScalars
    , int64Int = codec Int64Int.decodeScalars Int64Int.encodeScalars
    , enumZero = codec EnumZero.decodeScalars EnumZero.encodeScalars
    , bytesBytes = codec BytesBytes.decodeScalars BytesBytes.encodeScalars
    }


fails : Codec -> String -> Expect.Expectation
fails run input =
    case run input of
        Err _ ->
            Expect.pass

        Ok value ->
            Expect.fail ("decodes, and re-encodes as " ++ Json.Encode.encode 0 value)


options : Test
options =
    describe "what the options change"
        [ describe "enum_unknown"
            [ test "an unknown name fails by default" <|
                \_ -> fails scalars.default """{"kind":"KIND_LATER"}"""
            , test "zero reads an unknown name as the zero value" <|
                \_ -> roundTrip scalars.enumZero """{"kind":"KIND_LATER"}""" "{}"
            , test "zero reads an unknown name in a list as the zero value" <|
                \_ ->
                    roundTrip (codec EnumZero.decodeRepeated EnumZero.encodeRepeated)
                        """{"kinds":["KIND_TEXT","KIND_LATER"]}"""
                        """{"kinds":["KIND_TEXT","KIND_UNSPECIFIED"]}"""
            , test "an unknown number reads as the zero value under either" <|
                \_ ->
                    Expect.all
                        [ \_ -> roundTrip scalars.default """{"kind":7}""" "{}"
                        , \_ -> roundTrip scalars.enumZero """{"kind":7}""" "{}"
                        ]
                        ()
            ]
        , describe "int64=int"
            [ test "reads a number, a string and exponent notation" <|
                \_ ->
                    Expect.all
                        [ \_ -> roundTrip scalars.int64Int """{"int64":42}""" """{"int64":"42"}"""
                        , \_ -> roundTrip scalars.int64Int """{"int64":"42"}""" """{"int64":"42"}"""
                        , \_ -> roundTrip scalars.int64Int """{"sint64":"-1e3"}""" """{"sint64":"-1000"}"""
                        , \_ -> roundTrip scalars.int64Int """{"uint64":9007199254740991}""" """{"uint64":"9007199254740991"}"""
                        ]
                        ()
            , test "refuses a value an Int does not hold exactly, which the default keeps" <|
                \_ ->
                    Expect.all
                        [ \_ -> fails scalars.int64Int """{"int64":"9007199254740992"}"""
                        , \_ -> roundTrip scalars.default """{"int64":"9007199254740992"}""" """{"int64":"9007199254740992"}"""
                        ]
                        ()
            ]
        , describe "bytes=bytes"
            [ test "writes the standard alphabet with padding, where the default keeps the text received" <|
                \_ ->
                    Expect.all
                        [ \_ -> roundTrip scalars.bytesBytes """{"bytes":"-_8"}""" """{"bytes":"+/8="}"""
                        , \_ -> roundTrip scalars.default """{"bytes":"-_8"}""" """{"bytes":"-_8"}"""
                        ]
                        ()
            , test "refuses what is not base64 under either" <|
                \_ ->
                    Expect.all
                        [ \_ -> fails scalars.bytesBytes """{"bytes":"a"}"""
                        , \_ -> fails scalars.default """{"bytes":"a"}"""
                        ]
                        ()
            ]
        ]
