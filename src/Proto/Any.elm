module Proto.Any exposing
    ( Any, typeUrl, typeName, is
    , pack, packWith
    , unpack, tryUnpack, Problem(..)
    , bytes
    , toJson
    , describe
    )

{-| `google.protobuf.Any`: a message of any type, with the URL naming its type.

An `Any` holds the message's protobuf binary, whatever the codec its calls
use; its proto3 JSON is a projection through a
[`Proto.Registry`](Proto-Registry). It packs and unpacks with the typed values
generated code gives each message:

    detail : Proto.Any.Any
    detail =
        Proto.Any.pack Notes.V1.messageNote note

    Proto.Any.unpack Notes.V1.messageNote detail
    --> Just note

@docs Any, typeUrl, typeName, is


# Packing and unpacking

@docs pack, packWith
@docs unpack, tryUnpack, Problem


# Reading

@docs bytes


# Converting

@docs toJson


# Describing

@docs describe

-}

import Bytes exposing (Bytes)
import Bytes.Encode
import Json.Encode
import Proto.Bytes
import Proto.Descriptors as Descriptors exposing (Descriptors)
import Proto.Internal.Any as Internal
import Proto.Internal.Binary
import Proto.Internal.Message as InternalMessage
import Proto.Internal.Registry as Registry exposing (Registry)
import Proto.Message as Message exposing (Message)


{-| A packed message's protobuf binary and its type URL. It is opaque: build
one with [`pack`](#pack), or decode one, and read it with the functions here.
`==` compares two by their type URL and content. The package site and compiler
errors may show it as `Proto.Internal.Any.Any`, its name inside the package.
-}
type alias Any =
    Internal.Any


{-| The URL naming the packed message's type, such as
`type.googleapis.com/notes.v1.Note`; `""` for the empty `Any`.
-}
typeUrl : Any -> String
typeUrl (Internal.Any url _) =
    url


{-| The packed message's full name: the type URL after its last `/`, such as
`notes.v1.Note`.
-}
typeName : Any -> String
typeName (Internal.Any url _) =
    Internal.nameOf url


{-| Whether the packed message is of this type, by full name.
-}
is : Message a -> Any -> Bool
is message any =
    typeName any == Message.typeName message



-- PACKING AND UNPACKING


{-| A message as an `Any`, its type URL prefixed `type.googleapis.com/`, as
protobuf's own libraries write it.
-}
pack : Message a -> a -> Any
pack message value =
    packWith "type.googleapis.com" message value


{-| [`pack`](#pack) with another prefix: `packWith "example.com/types"
messageNote note` has the type URL `example.com/types/notes.v1.Note`.
-}
packWith : String -> Message a -> a -> Any
packWith prefix ((InternalMessage.Message _ codecs) as message) value =
    Internal.Any (prefixed prefix message)
        (Proto.Bytes.toBase64 (Bytes.Encode.encode (codecs.encode value)))


prefixed : String -> Message a -> String
prefixed prefix message =
    if String.endsWith "/" prefix then
        prefix ++ Message.typeName message

    else
        prefix ++ "/" ++ Message.typeName message


{-| The packed message, if it is of this type and its binary is that message.
-}
unpack : Message a -> Any -> Maybe a
unpack message any =
    Result.toMaybe (tryUnpack message any)


{-| The packed message, or why it cannot be read: `TypeMismatch` or
`InvalidProto`.
-}
tryUnpack : Message a -> Any -> Result Problem a
tryUnpack ((InternalMessage.Message _ codecs) as message) ((Internal.Any _ base64) as any) =
    if is message any then
        Proto.Bytes.fromBase64 base64
            |> Maybe.andThen (Proto.Internal.Binary.run codecs.decode)
            |> Result.fromMaybe InvalidProto

    else
        Err (TypeMismatch (typeName any))


{-| Why an `Any` could not be unpacked, or written as proto3 JSON:

  - `TypeMismatch`: [`tryUnpack`](#tryUnpack) was given the typed value of
    another type than the one it holds, whose full name is here. Test the
    type with [`is`](#is) first, or unpack with that type's typed value.
  - `InvalidProto`: its binary is not a message of the type its URL names:
    the sender's message and yours disagree. Nothing in the program fixes
    it; report it as the sender's.
  - `UnregisteredType`: [`toJson`](#toJson) and
    [`Proto.Json.encodeAnyWith`](Proto-Json#encodeAnyWith) were given a
    registry with no entry for the type URL named here. Register the type:
    its package's `registry`, [`Proto.WellKnown.registry`](Proto-WellKnown#registry),
    [`Proto.ErrorDetails.registry`](Proto-ErrorDetails#registry), or
    [`Proto.Registry.register`](Proto-Registry#register) of its typed value.
  - `UnwritableAny`: as `UnregisteredType` or `InvalidProto`, but for an
    `Any` held inside the message of the `Any` whose type URL is named
    here, at any depth. Register the types its `Any`s hold.

-}
type Problem
    = TypeMismatch String
    | InvalidProto
    | UnregisteredType String
    | UnwritableAny String



-- READING


{-| The packed message's protobuf binary.
-}
bytes : Any -> Bytes
bytes (Internal.Any _ base64) =
    Proto.Bytes.fromBase64 base64
        |> Maybe.withDefault Proto.Bytes.empty



-- CONVERTING


{-| The packed message's proto3 JSON (for a well-known type with a JSON form
of its own, such as `google.protobuf.Timestamp`, that form), converted from
its binary through the registry's entry for its type: for showing an `Any`,
and what [`Proto.Json.encodeAnyWith`](Proto-Json#encodeAnyWith) writes with
its `"@type"`. The empty `Any`, with no type URL, gives `{}`. It fails with
`UnregisteredType`, `InvalidProto` or `UnwritableAny` ([`Problem`](#Problem)).
-}
toJson : Registry -> Any -> Result Problem Json.Encode.Value
toJson registry ((Internal.Any url base64) as any) =
    if String.isEmpty url then
        Ok (Json.Encode.object [])

    else
        case Registry.toJson registry (typeName any) base64 of
            Just (Ok json) ->
                Ok json

            Just (Err Registry.NotTheMessage) ->
                Err InvalidProto

            Just (Err Registry.HoldsUnwritable) ->
                Err (UnwritableAny url)

            Nothing ->
                Err (UnregisteredType url)



-- DESCRIBING


{-| The descriptor of the packed message's type, if the descriptors have it.
-}
describe : Descriptors -> Any -> Maybe Message.Descriptor
describe descriptors any =
    Descriptors.message (typeName any) descriptors
