module Proto.Internal.Any exposing (Any(..), Payload(..))

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
its protobuf binary, base64-encoded, when nothing gave its JSON.
-}
type Payload
    = InJson Json.Encode.Value
    | InBinary String
