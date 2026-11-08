module Proto.Internal.Any exposing (Any(..), Blob(..), Payload(..), blob, blobOf, bytesOf, empty, nameOf, sameBlob)

{-| The `Any` type, defined here so that `Rpc` can build one from an error
detail, which `Proto.Any` exposes only opaquely.
-}

import Bitwise
import Bytes exposing (Bytes)
import Bytes.Decode
import Json.Encode exposing (Value)
import Proto.Bytes


{-| A type URL and the packed message.
-}
type Any
    = Any String Payload


{-| The packed message: its protobuf binary, alone or with the message's
proto3 JSON beside it, the JSON it was read from or packed with; or that
JSON alone, when a lenient registry read it without an entry for its type.
-}
type Payload
    = Binary Blob
    | Both Blob Value
    | Json Value


{-| A binary with its width and a 32-bit hash of its content, taken when the
`Any` is made. Elm's `==` finds any two `Bytes` equal, so `==` compares two
binaries by width and hash: two that differ are `==` only when their hashes
collide. `Proto.Any.equal` compares the bytes too.
-}
type Blob
    = Blob Int Int Bytes


{-| A binary with its width and content hash.
-}
blob : Bytes -> Blob
blob binary =
    let
        width =
            Bytes.width binary
    in
    Blob width (Maybe.withDefault offsetBasis (Bytes.Decode.decode (hash width) binary)) binary


{-| FNV-1a, 32-bit, taking a big-endian word of four bytes at a time and the
last one to three bytes one at a time.
-}
hash : Int -> Bytes.Decode.Decoder Int
hash width =
    Bytes.Decode.loop ( width, offsetBasis )
        (\( remaining, h ) ->
            if remaining >= 4 then
                Bytes.Decode.map (\w -> Bytes.Decode.Loop ( remaining - 4, mix h w )) (Bytes.Decode.unsignedInt32 Bytes.BE)

            else if remaining > 0 then
                Bytes.Decode.map (\b -> Bytes.Decode.Loop ( remaining - 1, mix h b )) Bytes.Decode.unsignedInt8

            else
                Bytes.Decode.succeed (Bytes.Decode.Done h)
        )


{-| One FNV-1a step: xor, then multiply by the prime 16777619 = 2^24 + 403
modulo 2^32, split so that no product passes 2^53.
-}
mix : Int -> Int -> Int
mix h value =
    let
        x =
            Bitwise.shiftRightZfBy 0 (Bitwise.xor h value)
    in
    Bitwise.shiftRightZfBy 0 (x * 403 + Bitwise.shiftLeftBy 24 x)


offsetBasis : Int
offsetBasis =
    2166136261


{-| The empty `Any`, with no type URL.
-}
empty : Any
empty =
    Any "" (Binary (blob Proto.Bytes.empty))


{-| The packed message's binary, unless it is held as JSON alone.
-}
bytesOf : Payload -> Maybe Bytes
bytesOf payload =
    Maybe.map (\(Blob _ _ binary) -> binary) (blobOf payload)


{-| The packed message's binary with its fingerprint, unless it is held as
JSON alone.
-}
blobOf : Payload -> Maybe Blob
blobOf payload =
    case payload of
        Binary binary ->
            Just binary

        Both binary _ ->
            Just binary

        Json _ ->
            Nothing


{-| Whether two binaries hold the same bytes: their widths and hashes first,
then the bytes four at a time.
-}
sameBlob : Blob -> Blob -> Bool
sameBlob (Blob leftWidth leftHash left) (Blob rightWidth rightHash right) =
    leftWidth
        == rightWidth
        && leftHash
        == rightHash
        && (Bytes.Decode.decode (words leftWidth) left == Bytes.Decode.decode (words rightWidth) right)


words : Int -> Bytes.Decode.Decoder (List Int)
words width =
    Bytes.Decode.loop ( width, [] )
        (\( remaining, acc ) ->
            if remaining >= 4 then
                Bytes.Decode.map (\w -> Bytes.Decode.Loop ( remaining - 4, w :: acc )) (Bytes.Decode.unsignedInt32 Bytes.BE)

            else if remaining > 0 then
                Bytes.Decode.map (\b -> Bytes.Decode.Loop ( remaining - 1, b :: acc )) Bytes.Decode.unsignedInt8

            else
                Bytes.Decode.succeed (Bytes.Decode.Done acc)
        )


{-| A message's full name from its type URL: the URL after its last `/`.
-}
nameOf : String -> String
nameOf url =
    String.split "/" url
        |> List.reverse
        |> List.head
        |> Maybe.withDefault url
