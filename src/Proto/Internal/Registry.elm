module Proto.Internal.Registry exposing (Entry, Leniency(..), Registry(..), isLenient, member, strict, toBytes, toJson, unregistered, writesJsonAlone)

{-| The `Registry` type, which `Proto.Registry` names by an alias, and the
conversions through one, which `Proto.Registry` does not expose: `Proto.Any`
and `Proto.Json` call them. The type is defined here because a message's
codecs (`Proto.Internal.Message`) take a registry, and `Proto.Registry`
builds entries from those codecs.

Each entry takes the registry it is called through, so a message holding an
`Any` converts that `Any` with the same table, however wide, at any depth,
and no entry refers to a table of its own.

-}

import Dict exposing (Dict)
import Json.Decode
import Json.Encode exposing (Value)
import Proto.Error exposing (Error)
import Proto.Internal.Any


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
to its proto3 JSON, and back. They take and give the text, not `Bytes`, so
that only a program that registers a message reaches elm/bytes through them.
Writing JSON fails with the binary's `BadBinary`, or with the error of an
`Any` the message holds, as that `Any`'s conversion gave it; reading fails
with the JSON's `BadJson`.
-}
type alias Entry =
    { toJson : Registry -> String -> Result Error Value
    , toBytes : Registry -> Value -> Result Error String
    }


{-| A message's proto3 JSON from its binary as base64, by full name;
`Nothing` when the registry has no entry for it.
-}
toJson : Registry -> String -> String -> Maybe (Result Error Value)
toJson ((Registry _ entries) as registry) name base64 =
    Dict.get name entries |> Maybe.map (\entry -> entry.toJson registry base64)


{-| A message's binary as base64 from its proto3 JSON, by full name;
`Nothing` when the registry has no entry for it.
-}
toBytes : Registry -> String -> Value -> Maybe (Result Error String)
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


{-| The type URL of the `Any` a JSON read failed on because the registry has
no entry for its type, if that is why it failed: the `Any` decoder fails such
a type with the `Any`'s object as the leaf failure's value, and this finds
that failure, reads its `"@type"` and tests the registry. An `Any` of a
registered type that holds one of an unregistered type fails at the outer
`Any`, whose type the registry has, so it gives `Nothing`.

The status-detail reader turns the result into `UnregisteredType`. It is not
public: an application reading proto3 JSON itself has the miss named in the
error's message, and a JSON read that gives a `Proto.Error` is the public
answer when one is asked for (docs/decisions.md, "One error type for the
proto layer").

-}
unregistered : Registry -> Json.Decode.Error -> Maybe String
unregistered registry error =
    case error of
        Json.Decode.Field _ inner ->
            unregistered registry inner

        Json.Decode.Index _ inner ->
            unregistered registry inner

        Json.Decode.OneOf errors ->
            List.filterMap (unregistered registry) errors |> List.head

        Json.Decode.Failure _ value ->
            case Json.Decode.decodeValue (Json.Decode.field "@type" Json.Decode.string) value of
                Ok url ->
                    -- A "@type" that is not a type URL fails for that.
                    if not (String.contains "/" url) || String.endsWith "/" url || member (Proto.Internal.Any.nameOf url) registry then
                        Nothing

                    else
                        Just url

                Err _ ->
                    Nothing
