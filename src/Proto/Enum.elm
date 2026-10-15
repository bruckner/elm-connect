module Proto.Enum exposing
    ( Enum, typeName
    , toName, fromName, toNumber, fromNumber
    )

{-| An enum type as a value: its proto3 JSON codecs, its zero value and its
descriptor, together. Generated code gives one per enum
(`Notes.V1.enumVisibility : Enum Visibility`).

@docs Enum, typeName


# Names and numbers

@docs toName, fromName, toNumber, fromNumber

-}

import Json.Decode
import Json.Encode
import Proto.Descriptor exposing (EnumDescriptor)


{-| An enum type whose Elm values are `a`:

  - `encodeJson` and `jsonDecoder`: its proto3 JSON codecs.
  - `default`: its zero value, which an absent field reads as.
  - `descriptor`: what the proto says about it.

The names and numbers below come from the descriptor and the codecs, which
read every declared name and number, aliases (`allow_alias`) included.

-}
type alias Enum a =
    { encodeJson : a -> Json.Encode.Value
    , jsonDecoder : Json.Decode.Decoder a
    , default : a
    , descriptor : EnumDescriptor
    }


{-| The enum's full name, such as `notes.v1.Visibility`.
-}
typeName : Enum a -> String
typeName enum =
    enum.descriptor.typeName


{-| The proto name of a value, such as `"VISIBILITY_PUBLIC"`: the one its
encoder writes, which for an aliased number is the first name declared for
it.
-}
toName : Enum a -> a -> String
toName enum value =
    Json.Decode.decodeValue Json.Decode.string (enum.encodeJson value)
        |> Result.withDefault ""


{-| The value a proto name stands for, aliases included, or `Nothing` for a
name the descriptor does not declare. Names are matched exactly. This is a
lookup, not a decode: it gives `Nothing` for an unknown name even when the JSON
decoder reads one as the zero value (`enum_unknown=zero`).
-}
fromName : Enum a -> String -> Maybe a
fromName enum name =
    if List.any (\declared -> declared.name == name) enum.descriptor.values then
        Json.Decode.decodeValue enum.jsonDecoder (Json.Encode.string name)
            |> Result.toMaybe

    else
        Nothing


{-| The number of a value: the one declared for its name, or `0` for a name
the descriptor does not declare.
-}
toNumber : Enum a -> a -> Int
toNumber enum value =
    let
        name =
            toName enum value
    in
    find (\declared -> declared.name == name) enum.descriptor.values
        |> Maybe.map .number
        |> Maybe.withDefault 0


{-| The value a number stands for, or `Nothing` for a number the descriptor
does not declare. The JSON decoder reads an unknown number as the zero value
instead; this lookup does not.
-}
fromNumber : Enum a -> Int -> Maybe a
fromNumber enum number =
    if List.any (\declared -> declared.number == number) enum.descriptor.values then
        Json.Decode.decodeValue enum.jsonDecoder (Json.Encode.int number)
            |> Result.toMaybe

    else
        Nothing


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
