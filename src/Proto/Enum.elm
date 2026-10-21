module Proto.Enum exposing
    ( Enum, enum
    , encode, decoder, default, toDescriptor
    , toName, fromName, toNumber, fromNumber
    , Descriptor, descriptor
    , typeName, values
    )

{-| An enum type: its typed value, which holds its proto3 JSON codecs, its
zero value and its descriptor together, and its descriptor, what the proto
says about it as data. Generated code gives one of each per enum: the typed
value in the package's module (`Notes.V1.enumVisibility : Enum Visibility`),
the descriptor in a module of the enum's own
(`Notes.V1.Visibility.descriptor : Descriptor`).

@docs Enum, enum


# Reading a typed value

@docs encode, decoder, default, toDescriptor


# Names and numbers

@docs toName, fromName, toNumber, fromNumber


# Descriptors

@docs Descriptor, descriptor


# Reading a descriptor

@docs typeName, values

-}

import Json.Decode
import Json.Encode
import Proto.EnumValue as EnumValue


{-| An enum type whose Elm values are `a`. It is opaque: built by
[`enum`](#enum) and read by the functions below.

The names and numbers below come from the descriptor and the codecs, which
read every declared name and number, aliases (`allow_alias`) included.

-}
type Enum a
    = Enum
        { encode : a -> Json.Encode.Value
        , decoder : Json.Decode.Decoder a
        , default : a
        , descriptor : Descriptor
        }


{-| An enum type from its proto3 JSON encoder and decoder, its zero value
(which an absent field reads as) and its descriptor. Generated code writes:

    enumVisibility : Proto.Enum.Enum Visibility
    enumVisibility =
        Proto.Enum.enum encodeVisibility decodeVisibility VisibilityUnspecified Notes.V1.Visibility.descriptor

-}
enum : (a -> Json.Encode.Value) -> Json.Decode.Decoder a -> a -> Descriptor -> Enum a
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


{-| What the proto says about the enum, read by the functions below.
-}
toDescriptor : Enum a -> Descriptor
toDescriptor (Enum e) =
    e.descriptor


declared : Enum a -> List ( String, Int )
declared (Enum e) =
    List.map (\v -> ( EnumValue.name v, EnumValue.number v )) (values e.descriptor)


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


{-| An enum type's descriptor: its full name and its values. It is opaque,
built by [`descriptor`](#descriptor) and read by the functions below.
-}
type Descriptor
    = Descriptor
        { typeName : String
        , values : List EnumValue.Descriptor
        }


{-| An enum of this full name, such as `notes.v1.Visibility`, with these values
in declaration order
([`Proto.EnumValue.descriptor`](Proto-EnumValue#descriptor)). An alias
(`allow_alias`) is a value of its own, with the number of the value it
aliases.
-}
descriptor : String -> List EnumValue.Descriptor -> Descriptor
descriptor fullName enumValues =
    Descriptor { typeName = fullName, values = enumValues }


{-| The enum's full name, such as `notes.v1.Visibility`.
-}
typeName : Descriptor -> String
typeName (Descriptor e) =
    e.typeName


{-| Every value in declaration order. An alias (`allow_alias`) is a value of
its own, with the number of the value it aliases.
-}
values : Descriptor -> List EnumValue.Descriptor
values (Descriptor e) =
    e.values
