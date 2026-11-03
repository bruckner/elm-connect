module Snippets.Descriptors exposing (noteFields, noteUrl)

{-| docs/descriptors.md's "Descriptors".
-}

-- region descriptors

import Notes.V1
import Notes.V1.Note
import Proto.Descriptors
import Proto.Field
import Proto.Message


noteUrl : String
noteUrl =
    -- "type.googleapis.com/notes.v1.Note"
    Proto.Message.typeUrl Notes.V1.Note.descriptor


noteFields : List String
noteFields =
    -- the proto names of Note's fields, in declaration order
    Proto.Descriptors.message "notes.v1.Note" Notes.V1.descriptors
        |> Maybe.map (Proto.Message.fields >> List.map Proto.Field.name)
        |> Maybe.withDefault []



-- endregion descriptors
