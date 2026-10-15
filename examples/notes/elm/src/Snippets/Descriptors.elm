module Snippets.Descriptors exposing (noteFields, noteUrl)

{-| The README's "Descriptors".
-}

-- region descriptors

import Notes.V1
import Proto.Message
import Proto.Registry


noteUrl : String
noteUrl =
    -- "type.googleapis.com/notes.v1.Note"
    Proto.Message.typeUrl Notes.V1.messageNote


noteFields : List String
noteFields =
    -- the proto names of Note's fields, in declaration order
    Proto.Registry.message "notes.v1.Note" Notes.V1.registry
        |> Maybe.map (.fields >> List.map .name)
        |> Maybe.withDefault []



-- endregion descriptors
