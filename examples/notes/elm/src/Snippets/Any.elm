module Snippets.Any exposing (packed, title)

{-| docs/descriptors.md's "Any".
-}

-- region any

import Notes.V1
import Proto.Any


packed : Proto.Any.Any
packed =
    -- {"@type": "type.googleapis.com/notes.v1.Note", "title": "groceries"}
    -- as proto3 JSON, through Notes.V1.registry
    let
        note =
            Notes.V1.defaultNote
    in
    Proto.Any.pack Notes.V1.messageNote { note | title = "groceries" }


title : Proto.Any.Any -> Maybe String
title any =
    Proto.Any.unpack Notes.V1.messageNote any
        |> Maybe.map .title



-- endregion any
