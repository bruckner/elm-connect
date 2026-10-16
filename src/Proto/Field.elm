module Proto.Field exposing
    ( Field
    , name, jsonName, number, cardinality, kind, oneof
    , behavior, deprecated
    )

{-| A field of a message's descriptor, and what it says.

@docs Field
@docs name, jsonName, number, cardinality, kind, oneof


# Annotations

@docs behavior, deprecated

-}

import Proto.Descriptor exposing (Behavior, Cardinality, Kind)
import Proto.Internal.Descriptor as Internal


{-| The opaque type itself, built by
[`Proto.Descriptor.field`](Proto-Descriptor#field); the same type as
[`Proto.Descriptor.Field`](Proto-Descriptor#Field), named here beside what reads it.
-}
type alias Field =
    Proto.Descriptor.Field


{-| Its proto name, such as `page_size`: the name a field mask's paths use.
-}
name : Field -> String
name (Internal.Field f) =
    f.name


{-| Its name in proto3 JSON, such as `pageSize`; an explicit `json_name` when
the proto gives one.
-}
jsonName : Field -> String
jsonName (Internal.Field f) =
    f.jsonName


{-| Its field number.
-}
number : Field -> Int
number (Internal.Field f) =
    f.number


{-| How many values it holds.
-}
cardinality : Field -> Cardinality
cardinality (Internal.Field f) =
    f.cardinality


{-| The type of each value; for a map, of each map value.
-}
kind : Field -> Kind
kind (Internal.Field f) =
    f.kind


{-| The name of the oneof it is a member of, if any.
-}
oneof : Field -> Maybe String
oneof (Internal.Field f) =
    f.oneof


{-| Its `google.api.field_behavior` annotations, in the order the proto gives
them; `[]` for a field without any.
-}
behavior : Field -> List Behavior
behavior (Internal.Field f) =
    f.behavior


{-| Whether the proto marks it `[deprecated = true]`.
-}
deprecated : Field -> Bool
deprecated (Internal.Field f) =
    f.deprecated
