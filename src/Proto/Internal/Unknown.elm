module Proto.Internal.Unknown exposing (Fields(..), settle)

{-| The unknown fields type, defined here so that `Proto.Binary` can read and
write them while `Proto.Unknown` exposes the type opaquely. It takes the value
type as a parameter only so that `Proto.Unknown` can define the values as data
a user matches on without this module importing it.

At rest the fields are in canonical order: by field number, and in arrival
order within one number. While a message is read they are held newest first,
each field read put in front, and [`settle`](#settle) turns one form into the
other.

-}


type Fields value
    = Fields (List ( Int, value ))


{-| Canonical order from fields held newest first. A decoder applies it to the
message it reads into before reading, as generated code reverses its lists
there, and again once every field is read: the first application leaves held
fields sorted by number with each number's fields newest first, so after the
second the held fields come before those read, in arrival order within a
number. `List.sortBy` is stable, which keeps that order.
-}
settle : Fields value -> Fields value
settle (Fields fields) =
    Fields (List.sortBy Tuple.first (List.reverse fields))
