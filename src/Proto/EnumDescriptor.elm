module Proto.EnumDescriptor exposing
    ( EnumDescriptor
    , typeName, values
    )

{-| An enum's descriptor, and what it says.

@docs EnumDescriptor
@docs typeName, values

-}

import Proto.Descriptor exposing (EnumValue)
import Proto.Internal.Descriptor as Internal


{-| The opaque type itself, built by
[`Proto.Descriptor.enum`](Proto-Descriptor#enum); the same type as
[`Proto.Descriptor.EnumDescriptor`](Proto-Descriptor#EnumDescriptor), named here beside what reads it.
-}
type alias EnumDescriptor =
    Proto.Descriptor.EnumDescriptor


{-| The enum's full name, such as `notes.v1.Visibility`.
-}
typeName : EnumDescriptor -> String
typeName (Internal.EnumDescriptor e) =
    e.typeName


{-| Every value in declaration order. An alias (`allow_alias`) is a value of
its own, with the number of the value it aliases.
-}
values : EnumDescriptor -> List EnumValue
values (Internal.EnumDescriptor e) =
    e.values
