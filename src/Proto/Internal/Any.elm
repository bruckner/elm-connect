module Proto.Internal.Any exposing (Any(..), Payload(..), base64Of, empty, nameOf)

{-| The `Any` type, defined here so that `Rpc` can build one from an error
detail, which `Proto.Any` exposes only opaquely.
-}

import Json.Encode exposing (Value)


{-| A type URL and the packed message.
-}
type Any
    = Any String Payload


{-| The packed message: its protobuf binary, as base64, alone or with the
message's proto3 JSON beside it, the JSON it was read from or packed with;
or that JSON alone, when a lenient registry read it without an entry for
its type. The binary is held as text, not `Bytes`, so that `==` compares two
`Any`s by their content. `==` compares the JSON too, so an `Any` read from
binary and the same one read from JSON differ; `Proto.Any.equal` compares
the binary alone.
-}
type Payload
    = Binary String
    | Both String Value
    | Json Value


{-| The empty `Any`, with no type URL.
-}
empty : Any
empty =
    Any "" (Binary "")


{-| The packed message's binary, as base64, unless it is held as JSON alone.
-}
base64Of : Payload -> Maybe String
base64Of payload =
    case payload of
        Binary base64 ->
            Just base64

        Both base64 _ ->
            Just base64

        Json _ ->
            Nothing


{-| A message's full name from its type URL: the URL after its last `/`.
-}
nameOf : String -> String
nameOf url =
    String.split "/" url
        |> List.reverse
        |> List.head
        |> Maybe.withDefault url
