module Proto.Enum exposing
    ( Enum, typeName, descriptor
    , toName, fromName, toNumber, fromNumber
    )

{-| An enum type as a value: its full name, its proto3 JSON codecs and its
values, together. Generated code gives one per enum
(`Notes.V1.enumVisibility : Enum Visibility`).

@docs Enum, typeName, descriptor


# Names and numbers

@docs toName, fromName, toNumber, fromNumber

-}

import Json.Decode
import Json.Encode
import Proto.Descriptor exposing (EnumDescriptor)


{-| An enum type whose Elm values are `a`:

  - `typeName`: its full name, such as `notes.v1.Visibility`.
  - `encodeJson` and `jsonDecoder`: its proto3 JSON codecs.
  - `values`: every value name in declaration order, with its number and the
    Elm value it stands for. An alias (`allow_alias`) is an entry of its own
    whose `value` is that of the name it aliases, so one Elm value can appear
    under several names; the first is the one written.

What the proto says about the enum is all here, so unlike a message's
record this one carries no descriptor; [`descriptor`](#descriptor) builds
it.

-}
type alias Enum a =
    { typeName : String
    , encodeJson : a -> Json.Encode.Value
    , jsonDecoder : Json.Decode.Decoder a
    , values : List { name : String, number : Int, value : a }
    }


{-| The enum's full name, such as `notes.v1.Visibility`.
-}
typeName : Enum a -> String
typeName enum =
    enum.typeName


{-| The enum as data: its full name and its value names with their numbers,
which is `values` without the Elm values.
-}
descriptor : Enum a -> EnumDescriptor
descriptor enum =
    { typeName = enum.typeName
    , values = List.map (\entry_ -> { name = entry_.name, number = entry_.number }) enum.values
    }


{-| The proto name of a value, such as `"VISIBILITY_PUBLIC"`: the first entry
of `values` holding it, which is the name proto3 JSON writes.
-}
toName : Enum a -> a -> String
toName enum value =
    case entry value enum of
        Just found ->
            found.name

        Nothing ->
            -- Only a hand-built record can leave a value out; its encoder
            -- still knows the name.
            Json.Decode.decodeValue Json.Decode.string (enum.encodeJson value)
                |> Result.withDefault ""


{-| The value a proto name stands for, aliases included, or `Nothing` for a
name the enum does not have. Names are matched exactly.
-}
fromName : Enum a -> String -> Maybe a
fromName enum name =
    find (\candidate -> candidate.name == name) enum.values
        |> Maybe.map .value


{-| The number of a value: that of the first entry of `values` holding it, or
`0` for a value not among them.
-}
toNumber : Enum a -> a -> Int
toNumber enum value =
    entry value enum
        |> Maybe.map .number
        |> Maybe.withDefault 0


{-| The value a number stands for, or `Nothing` for a number the enum does not
have. The JSON decoder reads an unknown number as the zero value instead.
-}
fromNumber : Enum a -> Int -> Maybe a
fromNumber enum number =
    find (\candidate -> candidate.number == number) enum.values
        |> Maybe.map .value


entry : a -> Enum a -> Maybe { name : String, number : Int, value : a }
entry value enum =
    find (\candidate -> candidate.value == value) enum.values


find : (a -> Bool) -> List a -> Maybe a
find matches list =
    case list of
        [] ->
            Nothing

        first :: rest ->
            if matches first then
                Just first

            else
                find matches rest
