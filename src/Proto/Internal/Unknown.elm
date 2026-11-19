module Proto.Internal.Unknown exposing (Fields(..), empty)

{-| The unknown fields type, defined here so that `Proto.Binary` can read and
write them while `Proto.Unknown` exposes the type opaquely.
-}


{-| The fields a message's schema does not know: their protobuf binary, each
field's key and value as read, as base64 text, since `==` on `Bytes` finds
any two equal. The fields are in canonical order: by field number, and in
the order they arrived within one number. Order within a number carries
meaning (it is a repeated field's element order in a newer schema); order
across numbers does not, so sorting by number makes `==` see two messages
holding the same fields as equal.
-}
type Fields
    = Fields String


empty : Fields
empty =
    Fields ""
