module Proto.Internal.Any exposing (Any(..), Payload(..), bytesOf, empty, nameOf, sameBytes)

{-| The `Any` type, defined here so that `Rpc` can build one from an error
detail, which `Proto.Any` exposes only opaquely.
-}

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
Elm's `==` finds any two `Bytes` equal, so two `Any`s of one type URL that
hold different binaries are `==`; `Proto.Any.equal` compares the binary.
-}
type Payload
    = Binary Bytes
    | Both Bytes Value
    | Json Value


{-| The empty `Any`, with no type URL.
-}
empty : Any
empty =
    Any "" (Binary Proto.Bytes.empty)


{-| The packed message's binary, unless it is held as JSON alone.
-}
bytesOf : Payload -> Maybe Bytes
bytesOf payload =
    case payload of
        Binary binary ->
            Just binary

        Both binary _ ->
            Just binary

        Json _ ->
            Nothing


{-| Whether two `Bytes` hold the same bytes, read four at a time.
-}
sameBytes : Bytes -> Bytes -> Bool
sameBytes left right =
    Bytes.width left
        == Bytes.width right
        && (Bytes.Decode.decode (words (Bytes.width left)) left == Bytes.Decode.decode (words (Bytes.width right)) right)


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
