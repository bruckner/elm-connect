module Proto.Any exposing
    ( Any, typeUrl, typeName, is
    , pack, packWith
    , unpack, tryUnpack, Problem(..)
    , bytes
    , equal
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


# Comparing

@docs equal


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
import Proto.Descriptors as Descriptors exposing (Descriptors)
import Proto.Internal.Any as Internal
import Proto.Internal.Binary
import Proto.Internal.Message as InternalMessage
import Proto.Internal.Registry as Registry exposing (Registry)
import Proto.Message as Message exposing (Message)


{-| A packed message's protobuf binary and its type URL. It is opaque: build
one with [`pack`](#pack), or decode one, and read it with the functions here.

An `Any` read from proto3 JSON, or packed, also keeps its message's JSON
beside the binary, so that writing it as JSON again needs no conversion.
`==` compares the binary exactly, through its base64, which the `Any`
keeps beside it, and it sees that JSON: an `Any` read from binary and the
same one read from JSON are not `==`. Compare two `Any`s with
[`equal`](#equal), which reads the type URL and the binary alone.

An `Any` of a type the registry lacks, read through a
[lenient](Proto-Registry#lenient) registry, holds its JSON alone, and no
binary ([`bytes`](#bytes)).

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
protobuf's own libraries write it. It holds the message's JSON too, so that
writing it as JSON needs no registry, unless the message holds an `Any`
with no JSON of its own, read from binary.
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
            Internal.held (Bytes.Encode.encode (codecs.encode value))
    in
    Internal.Any (prefixed prefix message)
        (case codecs.encodeJson (Registry.Registry Registry.Lossless Dict.empty) value of
            Just json ->
                Internal.Both (binary ()) json

            Nothing ->
                case codecs.encodeJson (Registry.Registry Registry.Strict Dict.empty) value of
                    Just json ->
                        -- It holds an `Any` held as JSON alone, which its
                        -- binary would lose.
                        Internal.Json json

                    Nothing ->
                        Internal.Binary (binary ())
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


{-| The packed message, or why it cannot be read: `TypeMismatch` or
`InvalidProto`. It is read from the binary, whatever JSON the `Any` keeps;
an `Any` held as JSON alone, which a [lenient](Proto-Registry#lenient)
registry reads, is read from its JSON with the message's JSON decoder, an
`Any` inside it read leniently too.
-}
tryUnpack : Message a -> Any -> Result Problem a
tryUnpack ((InternalMessage.Message _ codecs) as message) ((Internal.Any _ payload) as any) =
    if is message any then
        case payload of
            Internal.Json json ->
                Json.Decode.decodeValue (codecs.decoder (Registry.Registry Registry.Lenient Dict.empty)) json
                    |> Result.mapError (\_ -> InvalidProto)

            _ ->
                Internal.bytesOf payload
                    |> Maybe.andThen (Proto.Internal.Binary.run codecs.decode)
                    |> Result.fromMaybe InvalidProto

    else
        Err (TypeMismatch (typeName any))


{-| Why an `Any` could not be unpacked, or written as proto3 JSON:

  - `TypeMismatch`: [`tryUnpack`](#tryUnpack) was given the typed value of
    another type than the one it holds, whose full name is here. Test the
    type with [`is`](#is) first, or unpack with that type's typed value.
  - `InvalidProto`: its binary is not a message of the type its URL names,
    or, for an `Any` held as JSON alone, its JSON is not: the sender's
    message and yours disagree. Nothing in the program fixes
    it; report it as the sender's.
  - `UnregisteredType`: [`toJson`](#toJson) and
    [`Proto.Json.encodeAnyWith`](Proto-Json#encodeAnyWith) were given a
    registry with no entry for the type URL named here. Register the type:
    its package's `registry`, [`Proto.Registry.wellKnown`](Proto-Registry#wellKnown),
    [`Proto.ErrorDetails.registry`](Proto-ErrorDetails#registry), or
    [`Proto.Registry.register`](Proto-Registry#register) of its typed value.
    Reading it would have failed the same way, unless the registry it was
    read through is [lenient](Proto-Registry#lenient).
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


{-| The packed message's protobuf binary, as the `Any` holds it, with no
conversion: `Nothing` for an `Any` held as JSON alone, which a
[lenient](Proto-Registry#lenient) registry reads, and which is written as
protobuf binary as its type URL alone. `Just` an empty `Bytes` is an empty
message.
-}
bytes : Any -> Maybe Bytes
bytes (Internal.Any _ payload) =
    Internal.bytesOf payload



-- COMPARING


{-| Whether two `Any`s hold the same type URL and the same binary, whatever
JSON either keeps beside it: what `==` would say if it did not see that JSON
([`Any`](#Any)). Two binaries of one message written in a different field
order are not equal. Two `Any`s held as JSON alone are equal when their type
URLs and their JSON, as text, are; one held as JSON alone never equals one
holding binary, since without a registry the two cannot be compared.
-}
equal : Any -> Any -> Bool
equal (Internal.Any leftUrl left) (Internal.Any rightUrl right) =
    leftUrl
        == rightUrl
        && (case ( left, right ) of
                ( Internal.Json leftJson, Internal.Json rightJson ) ->
                    Json.Encode.encode 0 leftJson == Json.Encode.encode 0 rightJson

                _ ->
                    case ( Internal.heldOf left, Internal.heldOf right ) of
                        ( Just leftHeld, Just rightHeld ) ->
                            Internal.sameHeld leftHeld rightHeld

                        _ ->
                            False
           )



-- CONVERTING


{-| The packed message's proto3 JSON (for a well-known type with a JSON form
of its own, such as `google.protobuf.Timestamp`, that form): the JSON the
`Any` keeps, the JSON it was read from or packed with, else converted from
its binary through the registry's entry for its type: for showing an `Any`,
and what [`Proto.Json.encodeAnyWith`](Proto-Json#encodeAnyWith) writes with
its `"@type"`. The empty `Any`, with no type URL, gives `{}`. Converting fails with
`UnregisteredType`, `InvalidProto` or `UnwritableAny` ([`Problem`](#Problem));
the JSON an `Any` keeps needs no registry.
-}
toJson : Registry -> Any -> Result Problem Json.Encode.Value
toJson registry ((Internal.Any url payload) as any) =
    case ( String.isEmpty url, payload ) of
        ( True, _ ) ->
            Ok (Json.Encode.object [])

        ( False, Internal.Both _ json ) ->
            Ok json

        ( False, Internal.Json json ) ->
            if Registry.writesJsonAlone registry then
                Ok json

            else
                Err (UnregisteredType url)

        ( False, Internal.Binary (Internal.Held _ binary) ) ->
            case Registry.toJson registry (typeName any) binary of
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
