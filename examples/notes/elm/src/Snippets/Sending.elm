module Snippets.Sending exposing (Msg(..), client, milk, viaConnect, viaTranscoding)

{-| The README's quick start and docs/quickstart.md's first call: a call sent
over each protocol, and a message built from its default.
-}

-- region sending

import Notes.V1
import Notes.V1.NotesService as Notes
import Rpc
import Rpc.Protocol


type Msg
    = GotNote (Result Rpc.Error Notes.V1.Note)


client : Rpc.Client Rpc.Json
client =
    Rpc.client Rpc.Protocol.connect "https://api.example.com"


viaConnect : Cmd Msg
viaConnect =
    -- POST https://api.example.com/notes.v1.NotesService/GetNote
    Notes.getNote { name = "notes/42" }
        |> Rpc.send client GotNote


viaTranscoding : Cmd Msg
viaTranscoding =
    -- GET https://api.example.com/v1/notes/42
    Notes.getNote { name = "notes/42" }
        |> Rpc.send (Rpc.client Rpc.Protocol.transcode "https://api.example.com") GotNote



-- endregion sending
-- region building


milk : Notes.V1.Note
milk =
    let
        note =
            Notes.V1.defaultNote
    in
    { note | title = "Milk" }



-- endregion building
