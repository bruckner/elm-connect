module Snippets.Configuring exposing (NoteMsg(..), NoteState(..), Retrying, attemptNote, checked, connectGet, perCall, retrying, updateNote, withdraw)

{-| docs/calling.md's clients: a protocol with its options, a retry policy,
a retry loop the application drives, checking a client, and the adjustments
of one call.
-}

import Notes.V1
import Notes.V1.NotesService as Notes
import Process
import Rpc
import Rpc.Call
import Rpc.Client
import Rpc.Code
import Rpc.Error
import Rpc.Protocol
import Rpc.Retry
import Task
import Time



-- region protocols


connectGet : Rpc.Client Rpc.Json
connectGet =
    -- GetNote, ListNotes and Ping, declared NO_SIDE_EFFECTS, become GETs;
    -- a GET whose URL would pass 2048 characters is POSTed instead.
    Rpc.client
        (Rpc.Protocol.connect
            |> Rpc.Protocol.withConnectGet
            |> Rpc.Protocol.withMaxGetUrl 2048
        )
        "https://api.example.com"



-- endregion protocols
-- region retry


retrying : Rpc.Client Rpc.Json
retrying =
    Rpc.client Rpc.Protocol.connect "https://api.example.com"
        |> Rpc.Client.withRetry
            (Rpc.Retry.on [ Rpc.Code.Unavailable, Rpc.Code.ResourceExhausted ]
                |> Rpc.Retry.withAttempts 5
                |> Rpc.Retry.withBackoff 500
                |> Rpc.Retry.withMaxBackoff 10000
            )



-- endregion retry
-- region driving


type NoteState
    = Loading
    | Waiting Float
    | Loaded Notes.V1.Note
    | Failed Rpc.Error


type alias Retrying =
    { started : Time.Posix, note : NoteState }


type NoteMsg
    = TryAgain Int
    | GotNote Int Time.Posix (Result Rpc.Error Notes.V1.Note)


notePolicy : Rpc.Retry.Retry
notePolicy =
    Rpc.Retry.on [ Rpc.Code.Unavailable ]
        |> Rpc.Retry.withAttempts 5
        |> Rpc.Retry.withDeadline 30000


attemptNote : Int -> Cmd NoteMsg
attemptNote tried =
    Notes.getNote { name = "notes/42" }
        |> Rpc.Call.withoutRetry
        |> Rpc.task (Rpc.client Rpc.Protocol.connect "https://api.example.com")
        |> Task.map Ok
        |> Task.onError (\err -> Task.succeed (Err err))
        |> Task.andThen (\result -> Task.map (\now -> GotNote tried now result) Time.now)
        |> Task.perform identity


updateNote : NoteMsg -> Retrying -> ( Retrying, Cmd NoteMsg )
updateNote msg model =
    case msg of
        TryAgain tried ->
            ( { model | note = Loading }, attemptNote tried )

        GotNote _ _ (Ok note) ->
            ( { model | note = Loaded note }, Cmd.none )

        GotNote tried now (Err err) ->
            case
                Rpc.Retry.next notePolicy
                    { tried = tried
                    , code = Rpc.Error.code err
                    , idempotency = Rpc.Call.idempotency (Notes.getNote { name = "notes/42" })
                    , now = now
                    , elapsed = toFloat (Time.posixToMillis now - Time.posixToMillis model.started)
                    }
            of
                Just ms ->
                    ( { model | note = Waiting ms }
                    , Process.sleep ms |> Task.perform (\_ -> TryAgain (tried + 1))
                    )

                Nothing ->
                    ( { model | note = Failed err }, Cmd.none )



-- endregion driving
-- region check-client


checked : Rpc.Client codec -> Result String (Rpc.Client codec)
checked client =
    case Rpc.Client.problems client of
        [] ->
            Ok client

        problems ->
            Err (String.join "; " problems)



-- endregion check-client
-- region per-call


perCall : (Result Rpc.Error Notes.V1.Note -> msg) -> Cmd msg
perCall toMsg =
    Notes.getNote { name = "notes/42" }
        |> Rpc.Call.withTimeout 10000
        |> Rpc.Call.withHeaders [ ( "X-Request-Id", "req-7" ) ]
        |> Rpc.Call.withTracker "note-42"
        |> Rpc.send (Rpc.client Rpc.Protocol.connect "https://api.example.com") toMsg


withdraw : Cmd msg
withdraw =
    Rpc.cancel "note-42"



-- endregion per-call
