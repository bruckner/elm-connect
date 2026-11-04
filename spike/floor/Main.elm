module Main exposing (main)

{-| The no-Any floor: the services corpus package's GetNote, JSON-wired, over
Connect.
-}

import Notes.V1
import Notes.V1.NotesService
import Rpc
import Rpc.Protocol


type Msg
    = Got (Result Rpc.Error Notes.V1.Note)


main : Program () () Msg
main =
    Platform.worker
        { init =
            \_ ->
                ( ()
                , Rpc.send (Rpc.client Rpc.Protocol.connect "https://api.example.com")
                    Got
                    (Notes.V1.NotesService.getNote { name = "notes/1" })
                )
        , update = \_ m -> ( m, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
