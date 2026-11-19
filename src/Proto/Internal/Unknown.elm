module Proto.Internal.Unknown exposing (Fields(..), Value(..), append, empty)

{-| The unknown fields type, defined here so that `Proto.Binary` can read and
write them while `Proto.Unknown` exposes the type opaquely.
-}


{-| The fields a message's schema does not know, each with its number, in
canonical order: by field number, and in the order they arrived within one
number. Order within a number carries meaning (it is a repeated field's
element order in a newer schema); order across numbers does not, so sorting
by number makes `==` see two messages holding the same fields as equal.
-}
type Fields
    = Fields (List ( Int, Value ))


{-| One unknown field's value, by its wire type. A varint and a 64-bit fixed
value are two unsigned 32-bit halves, high then low; a length-delimited
payload is its base64 text, since `==` on `Bytes` finds any two equal.
-}
type Value
    = Varint Int Int
    | Fixed64 Int Int
    | Fixed32 Int
    | Delimited String


empty : Fields
empty =
    Fields []


{-| The fields held, then those read after them (given newest first), in
canonical order. `List.sortBy` is stable, so arrival order within a number
is kept.
-}
append : Fields -> List ( Int, Value ) -> Fields
append (Fields existing) newestFirst =
    Fields (List.sortBy Tuple.first (existing ++ List.reverse newestFirst))
