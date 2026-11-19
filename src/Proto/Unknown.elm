module Proto.Unknown exposing (Fields, empty, isEmpty)

{-| The fields of a protobuf binary message that its schema does not know,
kept by code generated under `unknown_fields=keep` in each message's
`unknownFields_` so that a message read and written back keeps them, and
`==` sees them.

Only protobuf binary carries them: a proto3 JSON read gives none, and a
proto3 JSON write leaves them out, as every protobuf runtime does.

@docs Fields, empty, isEmpty

-}

import Proto.Internal.Unknown as Internal


{-| The unknown fields of one message. Two are `==` when they hold the same
fields, whatever order fields of different numbers arrived in; fields of one
number are compared in the order they arrived, byte for byte.
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
isEmpty (Internal.Fields text) =
    String.isEmpty text
