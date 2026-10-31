module Snippets.Tracing exposing (Msg(..), log, traced)

{-| docs/calling.md's "Tracing": a call sent with `Rpc.sendTraced`, and its
trace as JSON for a log.
-}

import Json.Encode
import Notes.V1
import Notes.V1.NotesService as Notes
import Rpc
import Rpc.Trace



-- region trace


type Msg
    = GotNote Rpc.Trace.Trace (Result Rpc.Error Notes.V1.Note)


traced : Rpc.Client Rpc.Json -> Cmd Msg
traced client =
    Notes.getNote { name = "notes/42" }
        |> Rpc.sendTraced client GotNote


log : Rpc.Trace.Trace -> String
log trace =
    -- {"service": "notes.v1.NotesService", "method": "GetNote", ...}
    Json.Encode.encode 0 (Rpc.Trace.toJson trace)



-- endregion trace
