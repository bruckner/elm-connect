module Snippets.Migrating exposing (client, clientFor, describe, fetch, getNote, getNoteBinding, procedure)

{-| docs/migrating.md's code: what a 0.1 application writes in 0.2.

Each `before-*` region is the 0.1 code it replaces, kept in a comment since it
no longer compiles; it compiled against the 0.1.0 runtime and the notes
example's 0.1.0 generated code.

-}

import Notes.V1
import Notes.V1.GetNoteRequest
import Proto.Http
import Proto.Method
import Rpc
import Rpc.Call
import Rpc.Client
import Rpc.Code
import Rpc.Protocol
import Rpc.Retry
import Rpc.Trace



{-
   -- region before-client
   config : Rpc.Config
   config =
       let
           base =
               Rpc.config "https://api.example.com"
       in
       { base
           | transport =
               Rpc.Transport.connectGet
                   |> Rpc.Transport.withMaxGetUrl 2048
           , headers = [ ( "X-Api-Key", "key-7" ) ]
           , timeout = Just 10000
           , retry = Just (Rpc.Retry.on [ Rpc.Code.Unavailable ])
       }
   -- endregion before-client
-}
-- region client


client : Rpc.Client Rpc.Json
client =
    Rpc.client
        (Rpc.Protocol.connect
            |> Rpc.Protocol.withConnectGet
            |> Rpc.Protocol.withMaxGetUrl 2048
        )
        "https://api.example.com"
        |> Rpc.Client.withHeaders [ ( "X-Api-Key", "key-7" ) ]
        |> Rpc.Client.withTimeout 10000
        |> Rpc.Client.withRetry (Rpc.Retry.on [ Rpc.Code.Unavailable ])



-- endregion client
-- region client-for


clientFor : { token : String } -> Rpc.Client Rpc.Json
clientFor session =
    Rpc.client Rpc.Protocol.connect "https://api.example.com"
        |> Rpc.Client.withHeaders [ ( "Authorization", "Bearer " ++ session.token ) ]



-- endregion client-for
{-
   -- region before-fetch
   fetch : Rpc.Config -> (Result Rpc.Error res -> msg) -> Rpc.Call req res -> Cmd msg
   fetch cfg toMsg call =
       call
           |> Rpc.Call.withTimeout 10000
           |> Rpc.send cfg toMsg
   -- endregion before-fetch
-}
-- region fetch


fetch : Rpc.Client codec -> (Result Rpc.Error res -> msg) -> Rpc.Call codec req res -> Cmd msg
fetch rpcClient toMsg call =
    call
        |> Rpc.Call.withTimeout 10000
        |> Rpc.send rpcClient toMsg



-- endregion fetch
{-
   -- region before-trace
   describe : Rpc.Trace.Trace -> String
   describe trace =
       Rpc.Trace.transport trace
           ++ " "
           ++ Rpc.Trace.serviceName trace
           ++ "/"
           ++ Rpc.Trace.methodName trace
   -- endregion before-trace
-}
-- region trace


describe : Rpc.Trace.Trace -> String
describe trace =
    -- "connect json /notes.v1.NotesService/GetNote"
    Rpc.Trace.protocol trace
        ++ " "
        ++ Rpc.Trace.codec trace
        ++ " "
        ++ Rpc.Trace.procedure trace



-- endregion trace
{-
   -- region before-method
   getNote : Notes.V1.GetNoteRequest -> Rpc.Call Notes.V1.GetNoteRequest Notes.V1.Note
   getNote =
       Rpc.call
           (Proto.Method.method Notes.V1.encodeGetNoteRequest
               Notes.V1.decodeNote
               (Proto.Method.descriptor "notes.v1.NotesService"
                   "GetNote"
                   Proto.Method.IdempotencyNoSideEffects
                   "notes.v1.GetNoteRequest"
                   "notes.v1.Note"
                   [ getNoteBinding ]
               )
           )
   -- endregion before-method
-}
-- region method


getNote : Notes.V1.GetNoteRequest -> Rpc.Call Rpc.Json Notes.V1.GetNoteRequest Notes.V1.Note
getNote =
    Rpc.call
        (Proto.Method.json "notes.v1.NotesService"
            "GetNote"
            Notes.V1.encodeGetNoteRequest
            Notes.V1.decodeNote
            |> Proto.Method.withIdempotency Proto.Method.IdempotencyNoSideEffects
            |> Proto.Method.withBindings [ getNoteBinding ]
        )



-- endregion method
-- region binding


getNoteBinding : Proto.Http.Binding
getNoteBinding =
    -- GET /v1/{name=notes/*}
    Proto.Http.binding
        { method = "GET"
        , path =
            [ Proto.Http.literal "v1"
            , Proto.Http.variable
                { fieldPath = [ Notes.V1.GetNoteRequest.name ]
                , template = [ Proto.Http.literal "notes", Proto.Http.wildcard ]
                }
            ]
        , customVerb = Nothing
        , body = Proto.Http.noBody
        , responseBody = Nothing
        , query = []
        }



-- endregion binding
{-
   -- region before-procedure
   procedure : Rpc.Call req res -> String
   procedure call =
       let
           descriptor =
               Rpc.Call.descriptor call
       in
       "/" ++ Proto.Method.service descriptor ++ "/" ++ Proto.Method.name descriptor
   -- endregion before-procedure
-}
-- region procedure


procedure : Rpc.Call codec req res -> String
procedure call =
    -- "/notes.v1.NotesService/GetNote"
    Rpc.Call.procedure call



-- endregion procedure
