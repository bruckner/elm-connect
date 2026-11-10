module Proto.Internal.Registry exposing (Entry, Failure(..), Leniency(..), Registry(..), isLenient, member, strict, toBytes, toJson, writesJsonAlone)

{-| The `Registry` type, which `Proto.Registry` names by an alias. It is
defined here so that `Proto.Any` and `Proto.Json` can convert through one
with the functions below, which `Proto.Registry` does not expose.

Each entry takes the registry it is called through, so a message holding an
`Any` converts that `Any` with the same table, however wide, at any depth,
and no entry refers to a table of its own.

-}

import Dict exposing (Dict)
import Json.Encode exposing (Value)


{-| How it reads an `Any` of a type it has no entry for, and its entries.
-}
type Registry
    = Registry Leniency (Dict String Entry)


{-| `Strict` fails to read an `Any` of a type the registry has no entry for,
and `Lenient` reads it as that `Any`'s JSON alone. `Lossless` is strict and
also refuses to write an `Any` held as JSON alone, as JSON: `Proto.Any.pack`
writes a message through it to find whether the message's binary would lose
such an `Any`. No public function builds one.
-}
type Leniency
    = Strict
    | Lenient
    | Lossless


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
toJson ((Registry _ entries) as registry) name base64 =
    Dict.get name entries |> Maybe.map (\entry -> entry.toJson registry base64)


{-| A message's binary as base64 from its proto3 JSON, by full name;
`Nothing` when the registry has no entry for it.
-}
toBytes : Registry -> String -> Value -> Maybe (Result String String)
toBytes ((Registry _ entries) as registry) name json =
    Dict.get name entries |> Maybe.map (\entry -> entry.toBytes registry json)


{-| Whether the registry has an entry for a message, by full name.
-}
member : String -> Registry -> Bool
member name (Registry _ entries) =
    Dict.member name entries


{-| Whether the registry reads an `Any` of a type it has no entry for as its
JSON alone.
-}
isLenient : Registry -> Bool
isLenient (Registry leniency _) =
    leniency == Lenient


{-| Whether the registry writes an `Any` held as JSON alone as JSON.
-}
writesJsonAlone : Registry -> Bool
writesJsonAlone (Registry leniency _) =
    leniency /= Lossless


{-| The registry with its entries, strict.
-}
strict : Registry -> Registry
strict (Registry _ entries) =
    Registry Strict entries
