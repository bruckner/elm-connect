module Proto.MessageDescriptor exposing
    ( MessageDescriptor
    , typeName, fields, oneofs
    )

{-| A message's descriptor, and what it says.

    Proto.MessageDescriptor.fields Notes.V1.descriptorNote
        |> List.map Proto.Field.name
    --> [ "name", "title", … ]

@docs MessageDescriptor
@docs typeName, fields, oneofs

-}

import Proto.Descriptor exposing (Field)
import Proto.Internal.Descriptor as Internal


{-| The opaque type itself, built by
[`Proto.Descriptor.message`](Proto-Descriptor#message); the same type as
[`Proto.Descriptor.MessageDescriptor`](Proto-Descriptor#MessageDescriptor), named here beside what reads it.
-}
type alias MessageDescriptor =
    Proto.Descriptor.MessageDescriptor


{-| The message's full name, such as `notes.v1.Note`, or
`notes.v1.Note.Revision` for a nested message.
-}
typeName : MessageDescriptor -> String
typeName (Internal.MessageDescriptor m) =
    m.typeName


{-| Every field in declaration order, the members of its oneofs among them.
-}
fields : MessageDescriptor -> List Field
fields (Internal.MessageDescriptor m) =
    m.fields


{-| The names of its oneofs, in the order their first members are declared. A
proto3 `optional` field's synthetic oneof is not one of them.
-}
oneofs : MessageDescriptor -> List String
oneofs (Internal.MessageDescriptor m) =
    m.oneofs
