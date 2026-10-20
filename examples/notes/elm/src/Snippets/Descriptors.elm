module Snippets.Descriptors exposing (noteFields, noteUrl)

{-| The README's "Descriptors".
-}

-- region descriptors

import Notes.V1
import Notes.V1.Note
import Proto.Field
import Proto.Message
import Proto.Registry


noteUrl : String
noteUrl =
    -- "type.googleapis.com/notes.v1.Note"
    Proto.Message.typeUrl Notes.V1.Note.descriptor


noteFields : List String
noteFields =
    -- the proto names of Note's fields, in declaration order
    Proto.Registry.message "notes.v1.Note" Notes.V1.registry
        |> Maybe.map (Proto.Message.fields >> List.map Proto.Field.name)
        |> Maybe.withDefault []



-- endregion descriptors
