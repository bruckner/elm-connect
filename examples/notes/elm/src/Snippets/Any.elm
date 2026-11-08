module Snippets.Any exposing (packed, title)

{-| docs/descriptors.md's "Any".
-}

-- region any

import Notes.V1
import Proto.Any


packed : Proto.Any.Any
packed =
    -- {"@type": "type.googleapis.com/notes.v1.Note", "title": "groceries"}
    -- as proto3 JSON (Proto.Any.toJson, through a registry holding notes.v1.Note);
    -- the Any itself holds the note's protobuf binary
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
