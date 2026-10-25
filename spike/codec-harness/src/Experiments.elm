module Experiments exposing (decodeRepeatedHoisted, decodeRepeatedInline, encodeRepeatedSized)

{-| Hand-written variants of the generated `codec.v1.Repeated` codecs for its
`leaves` field alone, the only field the 1,000-leaf payload sets:

  - `encodeRepeatedSized` writes each leaf's length from a size function
    (protobuf's `encoded_len`), so no leaf is encoded twice, against the
    generated encoder, whose `delimited` encodes each leaf to `Bytes` and
    copies it in;
  - `decodeRepeatedHoisted` reads leaves with one top-level `Codec`,
    against `decodeRepeatedInline`, which builds it at each read as the
    generated decoder does.

-}

import Bitwise
import Bytes.Decode
import Bytes.Encode as E
import Generated.Codec.Both.Codec.V1 as V1
import Proto.Binary


varintWidth : Int -> Int
varintWidth n =
    if n < 0 then
        10

    else if n < 128 then
        1

    else if n < 16384 then
        2

    else if n < 2097152 then
        3

    else if n < 268435456 then
        4

    else
        5


writeVarint : Int -> E.Encoder
writeVarint n =
    if n < 128 then
        E.unsignedInt8 n

    else
        E.sequence [ E.unsignedInt8 (Bitwise.or 0x80 (Bitwise.and 0x7F n)), writeVarint (Bitwise.shiftRightZfBy 7 n) ]


sizeLeaf : V1.Leaf -> Int
sizeLeaf leaf =
    (if leaf.name == "" then
        0

     else
        let
            length =
                E.getStringWidth leaf.name
        in
        1 + varintWidth length + length
    )
        + (if leaf.count == 0 then
            0

           else
            1 + varintWidth leaf.count
          )


encodeRepeatedSized : V1.Repeated -> E.Encoder
encodeRepeatedSized value =
    E.sequence
        (List.map
            (\leaf -> E.sequence [ E.unsignedInt8 0x5A, writeVarint (sizeLeaf leaf), V1.encodeLeafBytes leaf ])
            value.leaves
        )


leafCodec : Proto.Binary.Codec V1.Leaf
leafCodec =
    Proto.Binary.embedded V1.encodeLeafBytes V1.decodeLeafBytes V1.defaultLeaf


decodeRepeatedHoisted : Int -> Bytes.Decode.Decoder V1.Repeated
decodeRepeatedHoisted =
    Proto.Binary.message V1.defaultRepeated
        (\number wire value ->
            case number of
                11 ->
                    Proto.Binary.repeated leafCodec (\v -> { value | leaves = v }) value.leaves wire

                _ ->
                    Proto.Binary.skip wire value
        )
        (\value -> { value | leaves = List.reverse value.leaves })


decodeRepeatedInline : Int -> Bytes.Decode.Decoder V1.Repeated
decodeRepeatedInline =
    Proto.Binary.message V1.defaultRepeated
        (\number wire value ->
            case number of
                11 ->
                    Proto.Binary.repeated (Proto.Binary.embedded V1.encodeLeafBytes V1.decodeLeafBytes V1.defaultLeaf) (\v -> { value | leaves = v }) value.leaves wire

                _ ->
                    Proto.Binary.skip wire value
        )
        (\value -> { value | leaves = List.reverse value.leaves })
