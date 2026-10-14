module Proto.Registry exposing
    ( Registry, empty, fromDescriptors, union, wellKnown
    , message, enum
    , messages, enums
    )

{-| Descriptors by full name. A descriptor names the messages and enums its
fields hold rather than containing them (a message may contain itself), and a
registry resolves those names. Generated code gives one per package module
(`Notes.V1.registry`), holding the package's types, those of every package it
imports, and the well-known types.

@docs Registry, empty, fromDescriptors, union, wellKnown


# Looking up

@docs message, enum


# Listing

@docs messages, enums

-}

import Dict exposing (Dict)
import Proto.Descriptor exposing (EnumDescriptor, MessageDescriptor)
import Proto.Internal.WellKnown as WellKnown


{-| Message and enum descriptors, each by its full name.
-}
type Registry
    = Registry
        { messages : Dict String MessageDescriptor
        , enums : Dict String EnumDescriptor
        }


{-| The registry with nothing in it.
-}
empty : Registry
empty =
    Registry { messages = Dict.empty, enums = Dict.empty }


{-| The registry of these messages and enums. Of two descriptors with one name,
the first is kept.
-}
fromDescriptors : List MessageDescriptor -> List EnumDescriptor -> Registry
fromDescriptors messageDescriptors enumDescriptors =
    Registry
        { messages = keyed messageDescriptors
        , enums = keyed enumDescriptors
        }


keyed : List { a | typeName : String } -> Dict String { a | typeName : String }
keyed =
    List.foldl
        (\descriptor dict ->
            if Dict.member descriptor.typeName dict then
                dict

            else
                Dict.insert descriptor.typeName descriptor dict
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
`FieldMask`, `Empty`, `Struct`, `Value`, `ListValue` and the wrappers, and the
enum `NullValue` that `Value` refers to.
-}
wellKnown : Registry
wellKnown =
    fromDescriptors WellKnown.messages WellKnown.enums


{-| The message of this full name, such as `notes.v1.Note`.
-}
message : String -> Registry -> Maybe MessageDescriptor
message typeName (Registry registry) =
    Dict.get typeName registry.messages


{-| The enum of this full name, such as `notes.v1.Visibility`.
-}
enum : String -> Registry -> Maybe EnumDescriptor
enum typeName (Registry registry) =
    Dict.get typeName registry.enums


{-| Every message, by full name.
-}
messages : Registry -> List MessageDescriptor
messages (Registry registry) =
    Dict.values registry.messages


{-| Every enum, by full name.
-}
enums : Registry -> List EnumDescriptor
enums (Registry registry) =
    Dict.values registry.enums
