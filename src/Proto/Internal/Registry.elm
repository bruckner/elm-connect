module Proto.Internal.Registry exposing (Entry, Registry(..), toBytes, toJson)

{-| The `Registry` type, which `Proto.Registry` names by an alias. It is
defined here so that `Proto.Any` and `Proto.Json`, which `Proto.Registry`
builds its well-known entries from, can convert through one.

Each entry takes the registry it is called through, so a message holding an
`Any` converts that `Any` with the same table, however wide, at any depth,
and no entry refers to a table of its own.

-}

import Bytes exposing (Bytes)
import Dict exposing (Dict)
import Json.Encode exposing (Value)


type Registry
    = Registry (Dict String Entry)


type alias Entry =
    { toJson : Registry -> Bytes -> Maybe Value
    , toBytes : Registry -> Value -> Maybe Bytes
    }


{-| A message's proto3 JSON from its binary, by full name: `Nothing` when the
registry has no entry for it, the bytes are not the message, or the message
holds an `Any` that cannot be written.
-}
toJson : Registry -> String -> Bytes -> Maybe Value
toJson ((Registry entries) as registry) name bytes =
    Dict.get name entries |> Maybe.andThen (\entry -> entry.toJson registry bytes)


{-| A message's binary from its proto3 JSON, by full name: `Nothing` when the
registry has no entry for it or the JSON is not the message.
-}
toBytes : Registry -> String -> Value -> Maybe Bytes
toBytes ((Registry entries) as registry) name json =
    Dict.get name entries |> Maybe.andThen (\entry -> entry.toBytes registry json)
