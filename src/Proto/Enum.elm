module Proto.Enum exposing
    ( Enum, enum
    , encode, decoder, default, descriptor, typeName
    , toName, fromName, toNumber, fromNumber
    )

{-| An enum type as a value: its proto3 JSON codecs, its zero value and its
descriptor, together. Generated code gives one per enum
(`Notes.V1.enumVisibility : Enum Visibility`).

@docs Enum, enum


# Reading

@docs encode, decoder, default, descriptor, typeName


# Names and numbers

@docs toName, fromName, toNumber, fromNumber

-}

import Json.Decode
import Json.Encode
import Proto.Descriptor exposing (EnumDescriptor)
import Proto.EnumDescriptor
import Proto.EnumValue


{-| An enum type whose Elm values are `a`. It is opaque: built by
[`enum`](#enum) and read by the functions below, so that what it carries can
grow as a new modifier without breaking code generated before.

The names and numbers below come from the descriptor and the codecs, which
read every declared name and number, aliases (`allow_alias`) included.

-}
type Enum a
    = Enum
        { encode : a -> Json.Encode.Value
        , decoder : Json.Decode.Decoder a
        , default : a
        , descriptor : EnumDescriptor
        }


{-| An enum type from its proto3 JSON encoder and decoder, its zero value
(which an absent field reads as) and its descriptor. Generated code writes:

    enumVisibility : Proto.Enum.Enum Visibility
    enumVisibility =
        Proto.Enum.enum encodeVisibility decodeVisibility VisibilityUnspecified descriptorVisibility

-}
enum : (a -> Json.Encode.Value) -> Json.Decode.Decoder a -> a -> EnumDescriptor -> Enum a
enum encodeJson jsonDecoder zero enumDescriptor =
    Enum
        { encode = encodeJson
        , decoder = jsonDecoder
        , default = zero
        , descriptor = enumDescriptor
        }


{-| A value as proto3 JSON.
-}
encode : Enum a -> a -> Json.Encode.Value
encode (Enum e) =
    e.encode


{-| The proto3 JSON decoder.
-}
decoder : Enum a -> Json.Decode.Decoder a
decoder (Enum e) =
    e.decoder


{-| The zero value.
-}
default : Enum a -> a
default (Enum e) =
    e.default


{-| What the proto says about the enum.
-}
descriptor : Enum a -> EnumDescriptor
descriptor (Enum e) =
    e.descriptor


{-| The enum's full name, such as `notes.v1.Visibility`.
-}
typeName : Enum a -> String
typeName (Enum e) =
    Proto.EnumDescriptor.typeName e.descriptor


declared : Enum a -> List ( String, Int )
declared (Enum e) =
    Proto.EnumDescriptor.values e.descriptor
        |> List.map (\v -> ( Proto.EnumValue.name v, Proto.EnumValue.number v ))


{-| The proto name of a value, such as `"VISIBILITY_PUBLIC"`: the one its
encoder writes, which for an aliased number is the first name declared for
it.

A value has a name only when its encoder writes a JSON string. One it writes
otherwise, such as a number for a value the proto does not declare, gives
`""`. A generated enum holds declared values only (a value the server adds
decodes as the zero value or fails, see
[`Proto.Json.enum`](Proto-Json#enum)), so its every value has a name.

-}
toName : Enum a -> a -> String
toName (Enum e) value =
    Json.Decode.decodeValue Json.Decode.string (e.encode value)
        |> Result.withDefault ""


{-| The value a proto name stands for, aliases included, or `Nothing` for a
name the descriptor does not declare. Names are matched exactly. This is a
lookup, not a decode: it gives `Nothing` for an unknown name even when the JSON
decoder reads one as the zero value (`enum_unknown=zero`).
-}
fromName : Enum a -> String -> Maybe a
fromName enum_ name =
    if List.any (\( declaredName, _ ) -> declaredName == name) (declared enum_) then
        Json.Decode.decodeValue (decoder enum_) (Json.Encode.string name)
            |> Result.toMaybe

    else
        Nothing


{-| The number of a value: the one declared for its name, or `0` for a name
the descriptor does not declare, and so for a value with no name
([`toName`](#toName) gives `""`), even one its encoder writes as another
number.
-}
toNumber : Enum a -> a -> Int
toNumber enum_ value =
    let
        name =
            toName enum_ value
    in
    find (\( declaredName, _ ) -> declaredName == name) (declared enum_)
        |> Maybe.map Tuple.second
        |> Maybe.withDefault 0


{-| The value a number stands for, or `Nothing` for a number the descriptor
does not declare. The JSON decoder reads an unknown number as the zero value
instead; this lookup does not.
-}
fromNumber : Enum a -> Int -> Maybe a
fromNumber enum_ number =
    if List.any (\( _, declaredNumber ) -> declaredNumber == number) (declared enum_) then
        Json.Decode.decodeValue (decoder enum_) (Json.Encode.int number)
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
