module Proto.Any exposing
    ( Any, typeUrl, typeName, is
    , pack, packWith
    , unpack, tryUnpack
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
@docs unpack, tryUnpack


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
import Proto.Error exposing (Error(..))
import Proto.Internal.Any as Internal
import Proto.Internal.Binary
import Proto.Internal.Message as InternalMessage
import Proto.Internal.Registry as InternalRegistry
import Proto.Message as Message exposing (Message)
import Proto.Registry exposing (Registry)


{-| A packed message's protobuf binary and its type URL. It is opaque: build
one with [`pack`](#pack), or decode one, and read it with the functions here.

`==` compares two by their type URL and content: an `Any` read from proto3
JSON holds the binary its registry converts the JSON to, so it is `==` to the
same message read from binary or packed, and so is any message holding it.

An `Any` of a type the registry lacks, read through a
[lenient](Proto-Registry#lenient) registry, holds its JSON alone, and no
binary ([`bytes`](#bytes)). `==` compares two such `Any`s by their JSON as
values, which is not protobuf's equality (the same message written with and
without its defaults differs), and one never equals an `Any` holding binary.

The package site and compiler errors may show it as `Proto.Internal.Any.Any`,
its name inside the package.

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
protobuf's own libraries write it. A message holding an `Any` held as JSON
alone, which a [lenient](Proto-Registry#lenient) registry reads, is packed as
its JSON alone too, since its binary would lose that `Any`.
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
        binary () =
            Internal.Binary (Proto.Bytes.toBase64 (Bytes.Encode.encode (codecs.encodeBinary value)))
    in
    Internal.Any (prefixed prefix message)
        (case codecs.encodeJson (InternalRegistry.Registry InternalRegistry.Lossless Dict.empty) value of
            Ok _ ->
                binary ()

            Err _ ->
                case codecs.encodeJson (InternalRegistry.Registry InternalRegistry.Strict Dict.empty) value of
                    Ok json ->
                        -- Only the refusal of an `Any` held as JSON alone
                        -- failed: the binary would lose that `Any`.
                        Internal.Json json

                    Err _ ->
                        binary ()
        )


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


{-| The packed message, or why it cannot be read: `TypeMismatch` when the
`Any` holds another type than the typed value's (both full names: the typed
value's as `expected`, the `Any`'s as `actual`), or `BadBinary` when its binary is not that
message, which the sender's message and yours disagreeing causes and nothing
in the program fixes. Test the type with [`is`](#is) first to tell the two
apart before unpacking.

It is read from the binary. An `Any` held as JSON alone, which a
[lenient](Proto-Registry#lenient) registry reads, is read from its JSON with
the message's JSON decoder, an `Any` inside it read leniently too, and fails
with that JSON's `BadJson`.

-}
tryUnpack : Message a -> Any -> Result Error a
tryUnpack ((InternalMessage.Message _ codecs) as message) ((Internal.Any url payload) as any) =
    if is message any then
        case payload of
            Internal.Json json ->
                Json.Decode.decodeValue (codecs.decodeJson (InternalRegistry.Registry InternalRegistry.Lenient Dict.empty)) json
                    |> Result.mapError BadJson

            Internal.Binary base64 ->
                Proto.Internal.Binary.runBase64 codecs.decodeBinary base64
                    |> Result.mapError BadBinary

    else
        Err (TypeMismatch { expected = Message.typeName message, actual = typeName any })



-- READING


{-| The packed message's protobuf binary: `Nothing` for an `Any` held as JSON
alone, which a [lenient](Proto-Registry#lenient) registry reads, and which
is written as protobuf binary as its type URL alone. `Just` an empty
`Bytes` is an empty message.
-}
bytes : Any -> Maybe Bytes
bytes (Internal.Any _ payload) =
    Internal.base64Of payload
        |> Maybe.map (Proto.Bytes.fromBase64 >> Maybe.withDefault Proto.Bytes.empty)



-- CONVERTING


{-| The packed message's proto3 JSON (for a well-known type with a JSON form
of its own, such as `google.protobuf.Timestamp`, that form), converted from
its binary through the registry's entry for its type: for showing an `Any`,
and what [`Proto.Json.encodeAnyWith`](Proto-Json#encodeAnyWith) writes with
its `"@type"`. The empty `Any`, with no type URL, gives `{}`. It fails with
[`UnregisteredType`](Proto-Error#Error) for a type the registry has no entry
for, and with [`BadBinary`](Proto-Error#Error) when the binary is not that
message; an `Any` the message holds, at any depth, fails the same ways,
named by its own type. Register the type: its package's `registry`,
[`Proto.WellKnown.registry`](Proto-WellKnown#registry),
[`Proto.ErrorDetails.registry`](Proto-ErrorDetails#registry), or
[`Proto.Registry.register`](Proto-Registry#register) of its typed value.
An `Any` held as JSON alone, which a [lenient](Proto-Registry#lenient)
registry reads, gives that JSON, with no registry.
-}
toJson : Registry -> Any -> Result Error Json.Encode.Value
toJson registry ((Internal.Any url payload) as any) =
    case ( String.isEmpty url, payload ) of
        ( True, _ ) ->
            Ok (Json.Encode.object [])

        ( False, Internal.Json json ) ->
            if InternalRegistry.writesJsonAlone registry then
                Ok json

            else
                Err (UnregisteredType url)

        ( False, Internal.Binary base64 ) ->
            InternalRegistry.toJson registry (typeName any) base64
                |> Maybe.withDefault (Err (UnregisteredType url))



-- DESCRIBING


{-| The descriptor of the packed message's type, if the descriptors have it.
-}
describe : Descriptors -> Any -> Maybe Message.Descriptor
describe descriptors any =
    Descriptors.message (typeName any) descriptors
