module Proto.Internal.Any exposing (Any(..), Held(..), Payload(..), bytesOf, empty, held, heldOf, nameOf, sameHeld)

{-| The `Any` type, defined here so that `Rpc` can build one from an error
detail, which `Proto.Any` exposes only opaquely.
-}

import Bytes exposing (Bytes)
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
    = Binary Held
    | Both Held Value
    | Json Value


{-| A binary with its canonical base64 (the standard alphabet, padded, as
`Proto.Bytes.toBase64` writes it), taken when the `Any` is made. Elm's `==`
finds any two `Bytes` equal but sees the text, so `==` on two binaries is
exact; unpacking and the protobuf wire read the `Bytes` and never decode the
text.
-}
type Held
    = Held String Bytes


{-| A binary with its canonical base64.
-}
held : Bytes -> Held
held binary =
    Held (Proto.Bytes.toBase64 binary) binary


{-| The empty `Any`, with no type URL.
-}
empty : Any
empty =
    Any "" (Binary (held Proto.Bytes.empty))


{-| The packed message's binary, unless it is held as JSON alone.
-}
bytesOf : Payload -> Maybe Bytes
bytesOf payload =
    Maybe.map (\(Held _ binary) -> binary) (heldOf payload)


{-| The packed message's binary with its base64, unless it is held as JSON
alone.
-}
heldOf : Payload -> Maybe Held
heldOf payload =
    case payload of
        Binary binary ->
            Just binary

        Both binary _ ->
            Just binary

        Json _ ->
            Nothing


{-| Whether two binaries hold the same bytes, by their canonical base64.
-}
sameHeld : Held -> Held -> Bool
sameHeld (Held left _) (Held right _) =
    left == right


{-| A message's full name from its type URL: the URL after its last `/`.
-}
nameOf : String -> String
nameOf url =
    String.split "/" url
        |> List.reverse
        |> List.head
        |> Maybe.withDefault url
