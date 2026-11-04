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
import Dict
import Json.Decode
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
`==` compares two by their type URL and content, the JSON one holds beside
its binary when it was read from JSON or packed included, so an `Any` read
from binary and the same one read from JSON differ. The package site and compiler
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
    let
        base64 =
            Proto.Bytes.toBase64 (Bytes.Encode.encode (codecs.encode value))
    in
    Internal.Any (prefixed prefix message)
        (case codecs.encodeJson emptyRegistry value of
            Just json ->
                Internal.Both base64 json

            Nothing ->
                Internal.Binary base64
        )


{-| The registry a packed or unpacked message's own JSON codecs are given:
an `Any` it holds converts through the JSON that `Any` holds beside its
binary, or not at all.
-}
emptyRegistry : Registry
emptyRegistry =
    Registry.Registry False Dict.empty


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
`InvalidProto`. An `Any` holding its message's JSON is read from that, else
from its binary.
-}
tryUnpack : Message a -> Any -> Result Problem a
tryUnpack ((InternalMessage.Message _ codecs) as message) ((Internal.Any _ payload) as any) =
    let
        fromBinary base64 =
            Proto.Bytes.fromBase64 base64
                |> Maybe.andThen (Proto.Internal.Binary.run codecs.decode)
                |> Result.fromMaybe InvalidProto
    in
    if is message any then
        case payload of
            Internal.Both base64 json ->
                case Json.Decode.decodeValue (codecs.decoder emptyRegistry) json of
                    Ok value ->
                        Ok value

                    Err _ ->
                        fromBinary base64

            Internal.Binary base64 ->
                fromBinary base64

            Internal.Json json ->
                -- An `Any` it holds is read as leniently as it was.
                Json.Decode.decodeValue (codecs.decoder (Registry.Registry True Dict.empty)) json
                    |> Result.mapError (\_ -> InvalidProto)

    else
        Err (TypeMismatch (typeName any))


{-| Why an `Any` could not be read or written:

  - `TypeMismatch`: it holds another type than the message's, named here.
  - `InvalidProto`: its binary is not the message.
  - `UnregisteredType`: it cannot be written as proto3 JSON: the registry
    has no entry for the type named here, or its binary is not that type.

-}
type Problem
    = TypeMismatch String
    | InvalidProto
    | UnregisteredType String



-- READING


{-| The packed message's protobuf binary: `Nothing` for an `Any` held as JSON
alone, which a [lenient](Proto-Registry#lenient) registry reads.
-}
bytes : Any -> Maybe Bytes
bytes (Internal.Any _ payload) =
    Internal.base64Of payload
        |> Maybe.map (Proto.Bytes.fromBase64 >> Maybe.withDefault Proto.Bytes.empty)



-- CONVERTING


{-| The packed message's proto3 JSON (for a well-known type with a JSON form
of its own, such as `google.protobuf.Timestamp`, that form): the JSON it was
read from or packed with, else converted from its binary through the
registry's entry for its type, `Nothing` when it has none, or the binary is
not that message.
-}
toJson : Registry -> Any -> Maybe Json.Encode.Value
toJson registry ((Internal.Any url payload) as any) =
    if String.isEmpty url then
        Just (Json.Encode.object [])

    else
        case payload of
            Internal.Both _ json ->
                Just json

            Internal.Json json ->
                Just json

            Internal.Binary base64 ->
                Proto.Bytes.fromBase64 base64
                    |> Maybe.andThen (Registry.toJson registry (typeName any))



-- DESCRIBING


{-| The descriptor of the packed message's type, if the descriptors have it.
-}
describe : Descriptors -> Any -> Maybe Message.Descriptor
describe descriptors any =
    Descriptors.message (typeName any) descriptors
