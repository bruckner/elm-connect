module Snippets.Configuring exposing (checked, connectGet, perCall, retrying, withdraw)

{-| docs/calling.md's configs: a transport with its options, a retry policy,
checking a config, and the adjustments of one call.
-}

import Notes.V1
import Notes.V1.NotesService as Notes
import Rpc
import Rpc.Call
import Rpc.Code
import Rpc.Retry
import Rpc.Transport



-- region transports


connectGet : Rpc.Config
connectGet =
    let
        base =
            Rpc.config "https://api.example.com"
    in
    -- GetNote, ListNotes and Ping, declared NO_SIDE_EFFECTS, become GETs;
    -- a GET whose URL would pass 2048 characters is POSTed instead.
    { base
        | transport =
            Rpc.Transport.connectGet
                |> Rpc.Transport.withMaxGetUrl 2048
    }



-- endregion transports
-- region retry


retrying : Rpc.Config
retrying =
    let
        base =
            Rpc.config "https://api.example.com"
    in
    { base
        | retry =
            Rpc.Retry.on [ Rpc.Code.Unavailable, Rpc.Code.ResourceExhausted ]
                |> Rpc.Retry.withAttempts 5
                |> Rpc.Retry.withBackoff 500
                |> Rpc.Retry.withMaxBackoff 10000
                |> Just
    }



-- endregion retry
-- region check-config


checked : Rpc.Config -> Result String Rpc.Config
checked cfg =
    case Rpc.checkConfig cfg of
        [] ->
            Ok cfg

        problems ->
            Err (String.join "; " problems)



-- endregion check-config
-- region per-call


perCall : (Result Rpc.Error Notes.V1.Note -> msg) -> Cmd msg
perCall toMsg =
    Notes.getNote { name = "notes/42" }
        |> Rpc.Call.withTimeout 10000
        |> Rpc.Call.withHeaders [ ( "X-Request-Id", "req-7" ) ]
        |> Rpc.Call.withTracker "note-42"
        |> Rpc.send (Rpc.config "https://api.example.com") toMsg


withdraw : Cmd msg
withdraw =
    Rpc.cancel "note-42"



-- endregion per-call
