module Proto.EnumValue exposing
    ( EnumValue
    , name, number, deprecated
    )

{-| A value of an enum's descriptor, and what it says.

@docs EnumValue
@docs name, number, deprecated

-}

import Proto.Descriptor
import Proto.Internal.Descriptor as Internal


{-| The opaque type itself, built by
[`Proto.Descriptor.value`](Proto-Descriptor#value); the same type as
[`Proto.Descriptor.EnumValue`](Proto-Descriptor#EnumValue), named here beside what reads it.
-}
type alias EnumValue =
    Proto.Descriptor.EnumValue


{-| Its proto name, such as `VISIBILITY_PUBLIC`: its proto3 JSON.
-}
name : EnumValue -> String
name (Internal.EnumValue v) =
    v.name


{-| Its number.
-}
number : EnumValue -> Int
number (Internal.EnumValue v) =
    v.number


{-| Whether the proto marks it `[deprecated = true]`.
-}
deprecated : EnumValue -> Bool
deprecated (Internal.EnumValue v) =
    v.deprecated
