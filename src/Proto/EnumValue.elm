module Proto.EnumValue exposing
    ( Descriptor, descriptor
    , name, number
    )

{-| A value of an enum, as its enum's descriptor
([`Proto.Enum.Descriptor`](Proto-Enum#Descriptor)) holds it: the descriptor
type, its builder and its readers.

@docs Descriptor, descriptor


# Reading

@docs name, number

-}


{-| One value of an enum. It is opaque, built by [`descriptor`](#descriptor)
and read by the functions below, so that a later release can say more about a
value without breaking code that builds or reads one.
-}
type Descriptor
    = Descriptor
        { name : String
        , number : Int
        }


{-| A value of this name and number, such as `VISIBILITY_PUBLIC` and `2`.
-}
descriptor : String -> Int -> Descriptor
descriptor valueName valueNumber =
    Descriptor { name = valueName, number = valueNumber }


{-| Its proto name, such as `VISIBILITY_PUBLIC`: its proto3 JSON.
-}
name : Descriptor -> String
name (Descriptor v) =
    v.name


{-| Its number.
-}
number : Descriptor -> Int
number (Descriptor v) =
    v.number
