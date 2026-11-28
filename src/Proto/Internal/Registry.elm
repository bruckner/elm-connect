module Proto.Internal.Registry exposing (Entry, Leniency(..), Registry(..), anyToJson, atLeast, depthOf, isLenient, member, toBytes, unregistered)

{-| The `Registry` type, which `Proto.Registry` names by an alias, and the
conversions through one, which `Proto.Registry` does not expose: `Proto.Any`
and `Proto.Json.Encode` and `Proto.Json.Decode` call them. An `Any`'s
conversion to proto3 JSON is here, not in `Proto.Any`, so that
`Proto.Json.Encode` writes an `Any` without importing `Proto.Any`, which
imports `Proto.Message`; `Proto.Message` and `Proto.Method` name
`Proto.Json.Encode`'s encoder, so it sits below all three. The type is defined here because a message's
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
import Proto.Internal.Any exposing (Any)
import Proto.Internal.Depth as Depth


{-| How it reads an `Any` of a type it has no entry for, how deeply the
conversion it was passed to has nested (0 for a registry the application
built), and its entries.
-}
type Registry
    = Registry Leniency Int (Dict String Entry)


{-| `Strict` fails to read an `Any` of a type the registry has no entry for,
and to write one held as JSON alone; `Lenient` reads it as that `Any`'s JSON
alone, and writes it as that JSON.

`Checking` is lenient, for a read whose result only says whether a lenient
read succeeds and is then dropped: a lenient read of an `Any` whose strict
read failed, which holds the `Any` as its JSON alone if this succeeds. An
`Any` read under it is read leniently at once, without the strict read
first, which only chooses between holding binary and holding JSON alone; a
strict read that succeeds implies a lenient one that does. So every `Any`
is read at most twice, once strictly and once leniently, not twice more
for every `Any` around it.

-}
type Leniency
    = Strict
    | Lenient
    | Checking


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
toJson (Registry leniency depth entries) name base64 =
    Dict.get name entries
        |> Maybe.map
            (\entry ->
                if depth < Depth.limit then
                    entry.toJson (Registry leniency (depth + 1) entries) base64

                else
                    Err (Proto.Error.BadBinary { typeName = "google.protobuf.Any", reason = Proto.Error.TooDeep, path = [], offset = 0 })
            )


{-| A message's binary as base64 from its proto3 JSON, by full name;
`Nothing` when the registry has no entry for it.
-}
toBytes : Registry -> String -> Value -> Maybe (Result Error String)
toBytes (Registry leniency depth entries) name json =
    Dict.get name entries
        |> Maybe.map
            (\entry ->
                if depth < Depth.limit then
                    entry.toBytes (Registry leniency (depth + 1) entries) json

                else
                    Err (Proto.Error.BadJson (Json.Decode.Failure Depth.tooDeepText Json.Encode.null))
            )


{-| An `Any`'s message as proto3 JSON, without its `"@type"`: what
`Proto.Any.toJson` gives, and what `Proto.Json.Encode.any` writes beside the
type URL. The empty `Any` gives `{}`. An `Any` holding binary is converted
through the entry for its type; one held as JSON alone is read through that
entry, so that what is written is JSON the type's codec accepts, and given
as it is held. Without an entry, a lenient registry gives the JSON unread
and a strict one fails with `UnregisteredType`.
-}
anyToJson : Registry -> Any -> Result Error Value
anyToJson registry (Proto.Internal.Any.Any url payload) =
    case ( String.isEmpty url, payload ) of
        ( True, _ ) ->
            Ok (Json.Encode.object [])

        ( False, Proto.Internal.Any.Json json ) ->
            -- Read through the entry so that what is written is JSON the
            -- type's codec accepts; the read's binary is not kept, and the
            -- JSON is written as held.
            case toBytes registry (Proto.Internal.Any.nameOf url) json of
                Just (Ok _) ->
                    Ok json

                Just (Err (Proto.Error.BadJson problem)) ->
                    Err
                        (unregistered registry problem
                            |> Maybe.map Proto.Error.UnregisteredType
                            |> Maybe.withDefault (Proto.Error.BadJson problem)
                        )

                Just (Err problem) ->
                    Err problem

                Nothing ->
                    if isLenient registry then
                        Ok json

                    else
                        Err (Proto.Error.UnregisteredType url)

        ( False, Proto.Internal.Any.Binary base64 ) ->
            toJson registry (Proto.Internal.Any.nameOf url) base64
                |> Maybe.withDefault (Err (Proto.Error.UnregisteredType url))


{-| How deep the conversion this registry is passed to has nested.
-}
depthOf : Registry -> Int
depthOf (Registry _ d _) =
    d


{-| The registry for a read at `d`, as a message that nests passes it to an
`Any` it holds, so the `Any` counts from there.
-}
atLeast : Int -> Registry -> Registry
atLeast d (Registry leniency current entries) =
    Registry leniency (max d current) entries


{-| Whether the registry has an entry for a message, by full name.
-}
member : String -> Registry -> Bool
member name (Registry _ _ entries) =
    Dict.member name entries


{-| Whether the registry reads an `Any` of a type it has no entry for as its
JSON alone.
-}
isLenient : Registry -> Bool
isLenient (Registry leniency _ _) =
    leniency /= Strict


{-| The type URL of the `Any` a JSON read failed on because the registry has
no entry for its type, if that is why it failed: the `Any` decoder fails such
a type with the `Any`'s object as the leaf failure's value, and this finds
that failure, reads its `"@type"` and tests the registry. An `Any` of a
registered type that holds one of an unregistered type fails at the outer
`Any`, whose type the registry has, so it gives `Nothing`.

`Proto.Message.decodeJson`, the public JSON read, and the status-detail
reader turn the result into `UnregisteredType`. The status-detail reader
calls this rather than `decodeJson`: its one message is `Any`, and
`Proto.WellKnown.any` holds `Any`'s binary codecs, which would put the
binary reader into every program that reads a failed answer, several
kilobytes gzipped on a JSON-only client.

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
