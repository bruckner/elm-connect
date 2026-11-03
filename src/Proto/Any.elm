module Proto.Any exposing
    ( Any, typeUrl, typeName, is
    , pack, packWith, packJson, packJsonWith
    , unpack, unpackJson, tryUnpack, tryUnpackJson, Problem(..)
    , bytes, json
    , toJson, toProto
    , describe
    )

{-| `google.protobuf.Any`: a message of any type, with the URL naming its type.

An `Any` holds the message in one form, which its codec says: an `Any Proto`
its protobuf binary, an `Any Json` its proto3 JSON. Code generated with
`codec=proto` or `codec=both` holds an `Any Proto`, with `codec=json` an
`Any Json`, and each packs and unpacks with the typed values of its own world:

    detail : Proto.Any.Any Rpc.Proto
    detail =
        Proto.Any.pack Notes.V1.messageNote note

    Proto.Any.unpack Notes.V1.messageNote detail
    --> Just note

@docs Any, typeUrl, typeName, is


# Packing and unpacking

@docs pack, packWith, packJson, packJsonWith
@docs unpack, unpackJson, tryUnpack, tryUnpackJson, Problem


# Reading

@docs bytes, json


# Converting

@docs toJson, toProto


# Describing

@docs describe

-}

import Bytes exposing (Bytes)
import Bytes.Encode
import Json.Decode
import Json.Encode
import Proto.Bytes
import Proto.Codec exposing (Json, Proto)
import Proto.Descriptors as Descriptors exposing (Descriptors)
import Proto.Internal.Any as Internal exposing (Payload(..))
import Proto.Internal.Binary
import Proto.Internal.Message as InternalMessage
import Proto.Internal.Registry as Registry exposing (Registry)
import Proto.Message as Message exposing (Message)


{-| A packed message and its type URL, in the form `codec` names:
[`Proto.Codec.Proto`](Proto-Codec#Proto) or
[`Proto.Codec.Json`](Proto-Codec#Json). It is opaque: build one with
[`pack`](#pack) or [`packJson`](#packJson), or decode one, and read it with the
functions here. `==` compares two by their type URL and content. The package
site and compiler errors may show it as `Proto.Internal.Any.Any`, its name
inside the package.
-}
type alias Any codec =
    Internal.Any codec


{-| The URL naming the packed message's type, such as
`type.googleapis.com/notes.v1.Note`; `""` for the empty `Any`.
-}
typeUrl : Any codec -> String
typeUrl (Internal.Any url _) =
    url


{-| The packed message's full name: the type URL after its last `/`, such as
`notes.v1.Note`.
-}
typeName : Any codec -> String
typeName (Internal.Any url _) =
    Internal.nameOf url


{-| Whether the packed message is of this type, by full name.
-}
is : Message codec a -> Any form -> Bool
is message any =
    typeName any == Message.typeName message



-- PACKING AND UNPACKING


{-| A message as an `Any` holding its protobuf binary, its type URL prefixed
`type.googleapis.com/`, as protobuf's own libraries write it.
-}
pack : Message Proto a -> a -> Any Proto
pack message value =
    packWith "type.googleapis.com" message value


{-| [`pack`](#pack) with another prefix: `packWith "example.com/types"
messageNote note` has the type URL `example.com/types/notes.v1.Note`.
-}
packWith : String -> Message Proto a -> a -> Any Proto
packWith prefix ((InternalMessage.Message _ codecs) as message) value =
    Internal.Any (prefixed prefix message)
        (case codecs of
            InternalMessage.ProtoCodecs encode _ ->
                InProto (Proto.Bytes.toBase64 (Bytes.Encode.encode (encode value)))

            InternalMessage.JsonCodecs _ _ ->
                InProto ""
        )


{-| A message as an `Any` holding its proto3 JSON, its type URL prefixed
`type.googleapis.com/`.
-}
packJson : Message Json a -> a -> Any Json
packJson message value =
    packJsonWith "type.googleapis.com" message value


{-| [`packJson`](#packJson) with another prefix, as [`packWith`](#packWith).
-}
packJsonWith : String -> Message Json a -> a -> Any Json
packJsonWith prefix ((InternalMessage.Message _ codecs) as message) value =
    Internal.Any (prefixed prefix message)
        (case codecs of
            InternalMessage.JsonCodecs encode _ ->
                InJson (encode value)

            InternalMessage.ProtoCodecs _ _ ->
                InJson Json.Encode.null
        )


prefixed : String -> Message codec a -> String
prefixed prefix message =
    if String.endsWith "/" prefix then
        prefix ++ Message.typeName message

    else
        prefix ++ "/" ++ Message.typeName message


{-| The packed message, if it is of this type and its binary is that message.
-}
unpack : Message Proto a -> Any Proto -> Maybe a
unpack message any =
    Result.toMaybe (tryUnpack message any)


{-| The packed message, if it is of this type and its JSON is that message.
-}
unpackJson : Message Json a -> Any Json -> Maybe a
unpackJson message any =
    Result.toMaybe (tryUnpackJson message any)


{-| The packed message, or why it cannot be read: `TypeMismatch` or
`InvalidProto`.
-}
tryUnpack : Message Proto a -> Any Proto -> Result Problem a
tryUnpack ((InternalMessage.Message _ codecs) as message) ((Internal.Any _ payload) as any) =
    if is message any then
        case codecs of
            InternalMessage.ProtoCodecs _ decoder ->
                Proto.Bytes.fromBase64 (Internal.base64Of payload)
                    |> Maybe.andThen (Proto.Internal.Binary.run decoder)
                    |> Result.fromMaybe InvalidProto

            InternalMessage.JsonCodecs _ _ ->
                Err InvalidProto

    else
        Err (TypeMismatch (typeName any))


{-| The packed message, or why it cannot be read: `TypeMismatch` or
`InvalidJson`.
-}
tryUnpackJson : Message Json a -> Any Json -> Result Problem a
tryUnpackJson ((InternalMessage.Message _ codecs) as message) ((Internal.Any _ payload) as any) =
    if is message any then
        case codecs of
            InternalMessage.JsonCodecs _ decoder ->
                Json.Decode.decodeValue decoder (Internal.jsonOf payload)
                    |> Result.mapError InvalidJson

            InternalMessage.ProtoCodecs _ _ ->
                Err (TypeMismatch (typeName any))

    else
        Err (TypeMismatch (typeName any))


{-| Why an `Any` could not be read or written:

  - `TypeMismatch`: it holds another type than the message's, named here.
  - `InvalidProto`: its binary is not the message.
  - `InvalidJson`: its JSON is not the message.
  - `UnregisteredType`: it cannot be written as proto3 JSON: the registry
    has no entry for the type named here, or its binary is not that type.

-}
type Problem
    = TypeMismatch String
    | InvalidProto
    | InvalidJson Json.Decode.Error
    | UnregisteredType String



-- READING


{-| The packed message's protobuf binary.
-}
bytes : Any Proto -> Bytes
bytes (Internal.Any _ payload) =
    Proto.Bytes.fromBase64 (Internal.base64Of payload)
        |> Maybe.withDefault Proto.Bytes.empty


{-| The packed message's proto3 JSON: for a well-known type with a JSON form
of its own, such as `google.protobuf.Timestamp`, that form.
-}
json : Any Json -> Json.Encode.Value
json (Internal.Any _ payload) =
    Internal.jsonOf payload



-- CONVERTING


{-| The `Any` holding its message's proto3 JSON, converted through the
registry's entry for its type: `Nothing` when it has none, or the binary is
not that message.
-}
toJson : Registry -> Any Proto -> Maybe (Any Json)
toJson registry ((Internal.Any url _) as any) =
    if String.isEmpty url then
        Just Internal.emptyJson

    else
        Registry.toJson registry (typeName any) (bytes any)
            |> Maybe.map (\value -> Internal.Any url (InJson value))


{-| The `Any` holding its message's protobuf binary, converted through the
registry's entry for its type: `Nothing` when it has none, or the JSON is not
that message.
-}
toProto : Registry -> Any Json -> Maybe (Any Proto)
toProto registry ((Internal.Any url payload) as any) =
    if String.isEmpty url then
        Just Internal.emptyProto

    else
        Registry.toBytes registry (typeName any) (Internal.jsonOf payload)
            |> Maybe.map (\binary -> Internal.Any url (InProto (Proto.Bytes.toBase64 binary)))



-- DESCRIBING


{-| The descriptor of the packed message's type, if the descriptors have it.
-}
describe : Descriptors -> Any codec -> Maybe Message.Descriptor
describe descriptors any =
    Descriptors.message (typeName any) descriptors
