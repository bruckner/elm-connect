module Proto.Internal.Any exposing (Any(..), Payload(..), base64Of, empty, nameOf)

{-| The `Any` type, defined here so that `Rpc` can build one from an error
detail, which `Proto.Any` exposes only opaquely.
-}

import Json.Encode exposing (Value)


{-| A type URL and the packed message.
-}
type Any
    = Any String Payload


{-| The packed message: its protobuf binary, as base64, or, when a lenient
registry read it without an entry for its type, its proto3 JSON alone. The
binary is held as text, not `Bytes`, so that `==` compares two `Any`s by
their content. It is the one form a strict read gives, whether the `Any`
arrived as binary or as JSON, so that `==` on a message that reaches an `Any`
through any field compares content too; a second form beside it would make
`==` tell apart two `Any`s holding one message.
-}
type Payload
    = Binary String
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
