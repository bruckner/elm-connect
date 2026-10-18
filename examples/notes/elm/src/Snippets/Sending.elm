module Snippets.Sending exposing (Msg(..), config, viaConnect, viaTranscoding)

{-| The README's "Using the generated client": a call sent over each transport.
-}

-- region sending

import Notes.V1
import Notes.V1.NotesService as Notes
import Rpc
import Rpc.Transport


type Msg
    = GotNote (Result Rpc.Error Notes.V1.Note)


config : Rpc.Config
config =
    Rpc.config "https://api.example.com"


viaConnect : Cmd Msg
viaConnect =
    -- POST https://api.example.com/notes.v1.NotesService/GetNote
    Rpc.send config (Notes.getNote { name = "notes/42" }) GotNote


viaTranscoding : Cmd Msg
viaTranscoding =
    -- GET https://api.example.com/v1/notes/42
    Rpc.send { config | transport = Rpc.Transport.transcode } (Notes.getNote { name = "notes/42" }) GotNote



-- endregion sending
