module Snippets.Any exposing (packed, title)

{-| docs/descriptors.md's "Any".
-}

-- region any

import Notes.V1
import Proto.Any
import Rpc


packed : Proto.Any.Any Rpc.Json
packed =
    -- {"@type": "type.googleapis.com/notes.v1.Note", "title": "groceries"}
    let
        note =
            Notes.V1.defaultNote
    in
    Proto.Any.packJson Notes.V1.messageNote { note | title = "groceries" }


title : Proto.Any.Any Rpc.Json -> Maybe String
title any =
    Proto.Any.unpackJson Notes.V1.messageNote any
        |> Maybe.map .title



-- endregion any
