module Proto.Internal.Any exposing (Any(..), empty, nameOf)

{-| The `Any` type, defined here so that `Rpc` can build one from an error
detail, which `Proto.Any` exposes only opaquely.
-}


{-| A type URL and the packed message's protobuf binary, as base64. The binary
is held as text, not `Bytes`, so that `==` compares two `Any`s by their
content.
-}
type Any
    = Any String String


{-| The empty `Any`, with no type URL.
-}
empty : Any
empty =
    Any "" ""


{-| A message's full name from its type URL: the URL after its last `/`.
-}
nameOf : String -> String
nameOf url =
    String.split "/" url
        |> List.reverse
        |> List.head
        |> Maybe.withDefault url
