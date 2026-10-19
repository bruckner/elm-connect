module Proto.Registry exposing
    ( Registry, empty, fromDescriptors, union, wellKnown
    , message, enum
    , messages, enums
    )

{-| Descriptors by full name. A descriptor names the messages its fields hold
rather than containing them (a message may contain itself), and a registry
resolves those names; it finds enums by name too. Generated code gives one per package module
(`Notes.V1.registry`), holding the package's types, those of every package it
imports, and the well-known types.

@docs Registry, empty, fromDescriptors, union, wellKnown


# Looking up

@docs message, enum


# Listing

@docs messages, enums

-}

import Dict exposing (Dict)
import Proto.Enum as Enum
import Proto.Internal.WellKnown as WellKnown
import Proto.Message as Message


{-| Message and enum descriptors, each by its full name.
-}
type Registry
    = Registry
        { messages : Dict String Message.Descriptor
        , enums : Dict String Enum.Descriptor
        }


{-| The registry with nothing in it.
-}
empty : Registry
empty =
    Registry { messages = Dict.empty, enums = Dict.empty }


{-| The registry of these messages and enums. Of two descriptors with one name,
the first is kept.
-}
fromDescriptors : List Message.Descriptor -> List Enum.Descriptor -> Registry
fromDescriptors messageDescriptors enumDescriptors =
    Registry
        { messages = keyed Message.typeName messageDescriptors
        , enums = keyed Enum.typeName enumDescriptors
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
        }


{-| The `google.protobuf` types elm-connect maps: `Timestamp`, `Duration`,
`FieldMask`, `Empty`, `Any`, `Struct`, `Value`, `ListValue` and the wrappers,
and the enum `NullValue` that `Value` refers to.
-}
wellKnown : Registry
wellKnown =
    fromDescriptors WellKnown.messages WellKnown.enums


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
