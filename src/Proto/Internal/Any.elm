module Proto.Internal.Any exposing (Any(..), Payload(..), base64Of, emptyJson, emptyProto, jsonOf, nameOf)

{-| The `Any` type, defined here so that `Rpc` can build one from an error
detail, which `Proto.Any` exposes only opaquely.

The `codec` phantom says which payload an `Any` holds: one in `Json` holds
`InJson`, one in `Proto` holds `InProto`. Only this package's functions build
one, each in its own world, so a function on an `Any Proto` never meets
`InJson`, and the reverse.

-}

import Json.Encode


{-| A type URL and the packed message.
-}
type Any codec
    = Any String Payload


{-| The packed message: its proto3 JSON form (for a well-known type with a
JSON form of its own, that form, not the `"value"` object around it), or its
protobuf binary as base64. The binary is held as text, not `Bytes`, so that
`==` compares two `Any`s by their content.
-}
type Payload
    = InJson Json.Encode.Value
    | InProto String


{-| The empty `Any`, with no type URL, in each world.
-}
emptyJson : Any codec
emptyJson =
    Any "" (InJson (Json.Encode.object []))


emptyProto : Any codec
emptyProto =
    Any "" (InProto "")


{-| A message's full name from its type URL: the URL after its last `/`.
-}
nameOf : String -> String
nameOf url =
    String.split "/" url
        |> List.reverse
        |> List.head
        |> Maybe.withDefault url


{-| The packed message's JSON.
-}
jsonOf : Payload -> Json.Encode.Value
jsonOf payload =
    case payload of
        InJson json ->
            json

        InProto _ ->
            Json.Encode.null


{-| The packed message's binary, as base64.
-}
base64Of : Payload -> String
base64Of payload =
    case payload of
        InProto base64 ->
            base64

        InJson _ ->
            ""
