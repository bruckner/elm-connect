module Snippets.Any exposing (packed, title)

{-| The README's "Any".
-}

-- region any

import Notes.V1
import Proto.Any


packed : Proto.Any.Any
packed =
    -- {"@type": "type.googleapis.com/notes.v1.Note", "title": "groceries", …}
    let
        note =
            Notes.V1.defaultNote
    in
    Proto.Any.pack Notes.V1.messageNote { note | title = "groceries" }


title : Proto.Any.Any -> Maybe String
title any =
    case Proto.Any.unpack Notes.V1.messageNote any of
        Just (Ok note) ->
            Just note.title

        _ ->
            Nothing



-- endregion any
