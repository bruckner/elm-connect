module Proto.Descriptors exposing
    ( Descriptors, empty, fromDescriptors, union
    , message, enum, fieldName
    , messages, enums
    )

{-| Descriptors by full name. A descriptor names the messages its fields hold
rather than containing them (a message may contain itself), and a
`Descriptors` resolves those names; it finds enums by name too. Generated code
gives one per package module (`Notes.V1.descriptors`), holding the package's
types, those of every package it imports, and the well-known types,
which are [`Proto.WellKnown.descriptors`](Proto-WellKnown#descriptors).

@docs Descriptors, empty, fromDescriptors, union


# Looking up

@docs message, enum, fieldName


# Listing

@docs messages, enums

-}

import Dict exposing (Dict)
import Proto.Enum as Enum
import Proto.Field as Field
import Proto.Message as Message


{-| Message and enum descriptors, each by its full name.
-}
type Descriptors
    = Descriptors
        { messages : Dict String Message.Descriptor
        , enums : Dict String Enum.Descriptor
        }


{-| No descriptors at all.
-}
empty : Descriptors
empty =
    Descriptors { messages = Dict.empty, enums = Dict.empty }


{-| These messages and enums, by full name. Of two descriptors with one name,
the first is kept.
-}
fromDescriptors : List Message.Descriptor -> List Enum.Descriptor -> Descriptors
fromDescriptors messageDescriptors enumDescriptors =
    Descriptors
        { messages = keyed Message.fullName messageDescriptors
        , enums = keyed Enum.fullName enumDescriptors
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


{-| The descriptors of both. Of two with one name, the left one's is kept.
-}
union : Descriptors -> Descriptors -> Descriptors
union (Descriptors left) (Descriptors right) =
    Descriptors
        { messages = Dict.union left.messages right.messages
        , enums = Dict.union left.enums right.enums
        }


{-| The message of this full name, such as `notes.v1.Note`.
-}
message : String -> Descriptors -> Maybe Message.Descriptor
message typeName (Descriptors descriptors) =
    Dict.get typeName descriptors.messages


{-| The declared name of a message's field, from the message's full name
and the field's number: what a [`Proto.Error.Binary`](Proto-Error#Binary)
path holds, as a person reads it.


    showPath : Descriptors -> Proto.Error.Binary -> String
    showPath descriptors problem =
        problem.path
            |> List.map
                (\( typeName, number ) ->
                    typeName
                        ++ "."
                        ++ (Proto.Descriptors.fieldName descriptors typeName number
                                |> Maybe.withDefault (String.fromInt number)
                           )
                )
            |> String.join " > "

    -- "notes.v1.Note.revision > notes.v1.Revision.title"

`Nothing` when the descriptors have no such message, or the message no
field of that number.

-}
fieldName : Descriptors -> String -> Int -> Maybe String
fieldName descriptors typeName number =
    message typeName descriptors
        |> Maybe.andThen (Message.fields >> List.filter (\f -> Field.number f == number) >> List.head)
        |> Maybe.map Field.name


{-| The enum of this full name, such as `notes.v1.Visibility`.
-}
enum : String -> Descriptors -> Maybe Enum.Descriptor
enum typeName (Descriptors descriptors) =
    Dict.get typeName descriptors.enums


{-| Every message, by full name.
-}
messages : Descriptors -> List Message.Descriptor
messages (Descriptors descriptors) =
    Dict.values descriptors.messages


{-| Every enum, by full name.
-}
enums : Descriptors -> List Enum.Descriptor
enums (Descriptors descriptors) =
    Dict.values descriptors.enums
