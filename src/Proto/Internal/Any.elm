module Proto.Internal.Any exposing (Any(..), Payload(..), jsonOf, nameOf)

{-| The `Any` type, defined here so that `Rpc` can build one from a Connect
error detail, which `Proto.Any` exposes only opaquely.
-}

import Json.Encode


{-| A type URL and the packed message.
-}
type Any
    = Any String Payload


{-| The packed message: its proto3 JSON form (for a well-known type with a
JSON form of its own, that form, not the `"value"` object around it), or only
its protobuf binary, base64-encoded, when nothing gave its JSON, or both, when
it was packed from a value whose message has binary codecs.
-}
type Payload
    = InJson Json.Encode.Value
    | InBinary String
    | InBoth Json.Encode.Value String


{-| A message's full name from its type URL: the URL after its last `/`.
-}
nameOf : String -> String
nameOf url =
    String.split "/" url
        |> List.reverse
        |> List.head
        |> Maybe.withDefault url


{-| The packed message's JSON, `null` when only its binary arrived.
-}
jsonOf : Payload -> Json.Encode.Value
jsonOf payload =
    case payload of
        InJson json ->
            json

        InBoth json _ ->
            json

        InBinary _ ->
            Json.Encode.null
