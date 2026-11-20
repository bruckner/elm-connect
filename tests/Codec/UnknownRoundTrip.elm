module Codec.UnknownRoundTrip exposing (Codec, codec, suite)

{-| A message written under a newer schema, read under an older one that
keeps unknown fields, written again and read under the newer one, is the
message it was: `conformance/codec/codec.proto` is the newer schema, and the
older is it with about half its fields left out
(`crates/elm-connect-gen/tests/codec.rs`, `older_pool`), generated under
`unknown_fields=keep`. `Codec.UnknownRoundTripTest` runs it on every
sample's binary.
-}

import Bytes exposing (Bytes)
import Bytes.Encode
import Codec.BinaryRoundTrip
import Codec.RoundTrip exposing (Sample)
import Dict
import Expect
import Proto.Binary
import Test exposing (Test, describe, test)


{-| From the newer schema's bytes: what the newer schema writes after reading
the bytes the older schema wrote back, whether it read those as it read the
original (`==`), and whether the older schema reads its own bytes back as the
value it wrote.
-}
type alias Codec =
    Bytes -> Result String { rewritten : Bytes, same : Bool, stable : Bool }


codec : Proto.Binary.Decoder old -> (old -> Bytes.Encode.Encoder) -> Proto.Binary.Decoder new -> (new -> Bytes.Encode.Encoder) -> Codec
codec decodeOld encodeOld decodeNew encodeNew input =
    case ( Proto.Binary.decode decodeOld input, Proto.Binary.decode decodeNew input ) of
        ( Ok old, Ok original ) ->
            let
                rewritten =
                    Proto.Binary.encode encodeOld old
            in
            case Proto.Binary.decode decodeNew rewritten of
                Ok new ->
                    Ok
                        { rewritten = Proto.Binary.encode encodeNew new
                        , same =
                            -- A value holding NaN is not `==` to itself read
                            -- again; its bytes, compared below, stand for it.
                            new == original || Proto.Binary.decode decodeNew input /= Ok original
                        , stable =
                            Proto.Binary.decode decodeOld rewritten
                                == Ok old
                                || Proto.Binary.decode decodeOld input
                                /= Ok old
                        }

                Err _ ->
                    Err "the newer schema cannot read what the older wrote"

        _ ->
            Err "does not decode"


suite : List ( String, Codec ) -> List Sample -> Test
suite codecs samples =
    let
        table =
            Dict.fromList codecs
    in
    describe "through an older schema that keeps unknown fields"
        (List.map
            (\sample ->
                test sample.name <|
                    \_ ->
                        case Dict.get sample.message table of
                            Nothing ->
                                Expect.fail ("no codec for " ++ sample.message)

                            Just run ->
                                case run (Codec.BinaryRoundTrip.fromHex sample.binary) of
                                    Err problem ->
                                        Expect.fail problem

                                    Ok result ->
                                        Expect.all
                                            [ \r -> Expect.equal True r.same |> Expect.onFail "the newer schema reads another value"
                                            , \r -> Expect.equal True r.stable |> Expect.onFail "the older schema reads another value back"
                                            , \r -> Expect.equal sample.binary (Codec.BinaryRoundTrip.toHex r.rewritten)
                                            ]
                                            result
            )
            samples
        )
