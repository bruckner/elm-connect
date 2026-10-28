module Proto.Registry exposing
    ( Registry, empty, fromDescriptors, union, wellKnown
    , withBinary
    , message, enum, toBinary
    , messages, enums
    )

{-| Descriptors by full name. A descriptor names the messages its fields hold
rather than containing them (a message may contain itself), and a registry
resolves those names; it finds enums by name too. Generated code gives one per
package module (`Notes.V1.registry`), holding the package's types, those of
every package it imports, and the well-known types.

@docs Registry, empty, fromDescriptors, union, wellKnown


# Binary codecs

A registry can also hold messages' codecs, so that an
[`Any`](Proto-Any#Any) holding a message's JSON alone, as one read from
proto3 JSON does, can be written as protobuf binary
([`Proto.Binary.anyWith`](Proto-Binary#anyWith)). Code generated with
`codec=both` gives each package one more registry, `binaryRegistry`
(`Notes.V1.binaryRegistry`), holding the codecs of the package's messages,
of those of every package it imports and of the well-known types they hold,
and its binary encoders write an `Any` with it. It holds no descriptors,
and `registry` holds no codecs, so a program reading descriptors keeps no
codecs for it, nor one writing binary any descriptors.

@docs withBinary


# Looking up

@docs message, enum, toBinary


# Listing

@docs messages, enums

-}

import Bytes exposing (Bytes)
import Bytes.Encode
import Dict exposing (Dict)
import Json.Decode
import Json.Encode
import Proto.Enum as Enum
import Proto.Internal.WellKnown as WellKnown
import Proto.Message as Message


{-| Message and enum descriptors, each by its full name, and the conversions
of messages' proto3 JSON to protobuf binary [`withBinary`](#withBinary) adds.
A registry with conversions holds functions, so `==` on it fails at run time.
-}
type Registry
    = Registry
        { messages : Dict String Message.Descriptor
        , enums : Dict String Enum.Descriptor
        , binary : Dict String (Json.Encode.Value -> Maybe Bytes)
        }


{-| The registry with nothing in it.
-}
empty : Registry
empty =
    Registry { messages = Dict.empty, enums = Dict.empty, binary = Dict.empty }


{-| The registry of these messages and enums. Of two descriptors with one name,
the first is kept.
-}
fromDescriptors : List Message.Descriptor -> List Enum.Descriptor -> Registry
fromDescriptors messageDescriptors enumDescriptors =
    Registry
        { messages = keyed Message.typeName messageDescriptors
        , enums = keyed Enum.typeName enumDescriptors
        , binary = Dict.empty
        }


keyed : (d -> String) -> List d -> Dict String d
keyed nameOf =
    List.foldl
        (\descriptor dict ->
            let
                name =
                    nameOf descriptor
            in
            if Dict.member name dict then
                dict

            else
                Dict.insert name descriptor dict
        )
        Dict.empty


{-| Both registries' descriptors. Of two with one name, the left one's is kept.
-}
union : Registry -> Registry -> Registry
union (Registry left) (Registry right) =
    Registry
        { messages = Dict.union left.messages right.messages
        , enums = Dict.union left.enums right.enums
        , binary = Dict.union left.binary right.binary
        }


{-| The `google.protobuf` types elm-connect maps: `Timestamp`, `Duration`,
`FieldMask`, `Empty`, `Any`, `Struct`, `Value`, `ListValue` and the wrappers,
and the enum `NullValue` that `Value` refers to.
-}
wellKnown : Registry
wellKnown =
    fromDescriptors WellKnown.messages WellKnown.enums


{-| The registry with a message's codecs too, by its full name: its proto3
JSON decoder and its protobuf binary encoder, so that its JSON can be written
as binary ([`toBinary`](#toBinary)). Of two codecs for one name, the later is
kept.

    Proto.Registry.empty
        |> Proto.Registry.withBinary "notes.v1.Note" Notes.V1.decodeNote Notes.V1.encodeNoteBytes

-}
withBinary : String -> Json.Decode.Decoder a -> (a -> Bytes.Encode.Encoder) -> Registry -> Registry
withBinary typeName decoder encode (Registry registry) =
    let
        convert json =
            Json.Decode.decodeValue decoder json
                |> Result.toMaybe
                |> Maybe.map (encode >> Bytes.Encode.encode)
    in
    Registry { registry | binary = Dict.insert typeName convert registry.binary }


{-| A message's protobuf binary from its proto3 JSON, by the message's full
name: `Nothing` when the registry has no codecs for it
([`withBinary`](#withBinary)) or the JSON is not the message's.
-}
toBinary : String -> Json.Encode.Value -> Registry -> Maybe Bytes
toBinary typeName json (Registry registry) =
    Dict.get typeName registry.binary
        |> Maybe.andThen (\convert -> convert json)


{-| The message of this full name, such as `notes.v1.Note`.
-}
message : String -> Registry -> Maybe Message.Descriptor
message typeName (Registry registry) =
    Dict.get typeName registry.messages


{-| The enum of this full name, such as `notes.v1.Visibility`.
-}
enum : String -> Registry -> Maybe Enum.Descriptor
enum typeName (Registry registry) =
    Dict.get typeName registry.enums


{-| Every message, by full name.
-}
messages : Registry -> List Message.Descriptor
messages (Registry registry) =
    Dict.values registry.messages


{-| Every enum, by full name.
-}
enums : Registry -> List Enum.Descriptor
enums (Registry registry) =
    Dict.values registry.enums
