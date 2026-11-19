module Proto.Unknown exposing
    ( Fields, empty, isEmpty
    , Value(..), toList, fromList
    )

{-| The fields of a protobuf binary message that its schema does not know,
kept by code generated under `unknown_fields=keep` in each message's
`unknownFields_` so that a message read and written back keeps them, and
`==` sees them.

    { Notes.V1.defaultNote | title = "Groceries" }
    -- unknownFields_ = Proto.Unknown.empty, from the default

Only protobuf binary carries them: a proto3 JSON read gives none, and a
proto3 JSON write leaves them out, as every protobuf runtime does.

@docs Fields, empty, isEmpty


# As data

@docs Value, toList, fromList

-}

import Proto.Internal.Unknown as Internal


{-| The unknown fields of one message. Two are `==` when they hold the same
fields, whatever order fields of different numbers arrived in; fields of one
number are compared in the order they arrived.
-}
type alias Fields =
    Internal.Fields


{-| No unknown fields: what a message built in Elm or read from proto3 JSON
holds.
-}
empty : Fields
empty =
    Internal.empty


{-| Whether there are none.
-}
isEmpty : Fields -> Bool
isEmpty (Internal.Fields fields) =
    List.isEmpty fields


{-| One field's value by its wire type: a varint or a 64-bit fixed value as
two unsigned 32-bit halves, high then low; a 32-bit fixed value unsigned; a
length-delimited payload (a string, bytes, a message or a packed run, which
the wire does not tell apart) as base64 text.
-}
type Value
    = Varint Int Int
    | Fixed64 Int Int
    | Fixed32 Int
    | Delimited String


{-| Each field with its number, by field number and in arrival order within
one number.
-}
toList : Fields -> List ( Int, Value )
toList (Internal.Fields fields) =
    List.map (\( number, value ) -> ( number, fromInternal value )) fields


{-| Fields from a list, put in canonical order, for a test or a message built
to carry them.
-}
fromList : List ( Int, Value ) -> Fields
fromList fields =
    Internal.append Internal.empty (List.reverse (List.map (\( number, value ) -> ( number, toInternal value )) fields))


fromInternal : Internal.Value -> Value
fromInternal value =
    case value of
        Internal.Varint high low ->
            Varint high low

        Internal.Fixed64 high low ->
            Fixed64 high low

        Internal.Fixed32 bits ->
            Fixed32 bits

        Internal.Delimited text ->
            Delimited text


toInternal : Value -> Internal.Value
toInternal value =
    case value of
        Varint high low ->
            Internal.Varint high low

        Fixed64 high low ->
            Internal.Fixed64 high low

        Fixed32 bits ->
            Internal.Fixed32 bits

        Delimited text ->
            Internal.Delimited text
