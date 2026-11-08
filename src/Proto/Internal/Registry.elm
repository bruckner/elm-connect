module Proto.Internal.Registry exposing (Entry, Failure(..), Registry(..), member, toBytes, toJson)

{-| The `Registry` type, which `Proto.Registry` names by an alias. It is
defined here so that `Proto.Any` and `Proto.Json`, which `Proto.Registry`
builds its well-known entries from, can convert through one.

Each entry takes the registry it is called through, so a message holding an
`Any` converts that `Any` with the same table, however wide, at any depth,
and no entry refers to a table of its own.

-}

import Dict exposing (Dict)
import Json.Encode exposing (Value)


type Registry
    = Registry (Dict String Entry)


{-| A message's conversions: its binary, as the base64 text an `Any` holds,
to its proto3 JSON, and back, the latter failing with the JSON decoder's
error as text. They take and give the text, not `Bytes`, so that only a
program that registers a message reaches elm/bytes through them.
-}
type alias Entry =
    { toJson : Registry -> String -> Result Failure Value
    , toBytes : Registry -> Value -> Result String String
    }


{-| Why an entry could not write a message's binary as JSON: the bytes are
not the message, or the message holds an `Any` that cannot be written.
-}
type Failure
    = NotTheMessage
    | HoldsUnwritable


{-| A message's proto3 JSON from its binary as base64, by full name;
`Nothing` when the registry has no entry for it.
-}
toJson : Registry -> String -> String -> Maybe (Result Failure Value)
toJson ((Registry entries) as registry) name base64 =
    Dict.get name entries |> Maybe.map (\entry -> entry.toJson registry base64)


{-| A message's binary as base64 from its proto3 JSON, by full name;
`Nothing` when the registry has no entry for it.
-}
toBytes : Registry -> String -> Value -> Maybe (Result String String)
toBytes ((Registry entries) as registry) name json =
    Dict.get name entries |> Maybe.map (\entry -> entry.toBytes registry json)


{-| Whether the registry has an entry for a message, by full name.
-}
member : String -> Registry -> Bool
member name (Registry entries) =
    Dict.member name entries
