module Live.Notes exposing (table)

{-| The dispatch table of `notes.v1.NotesService`, the example API's service.
-}

import Live.Call exposing (Entry)
import Live.Codec exposing (entry)
import Notes.V1
import Notes.V1.NotesService as Service
import Proto.Json
import Proto.WellKnown


{-| Each method by its service and name.
-}
table : List ( ( String, String ), Entry msg )
table =
    List.map (\( name, e ) -> ( ( "notes.v1.NotesService", name ), e ))
        [ ( "GetNote", entry Service.getNote Service.getNote Notes.V1.decodeGetNoteRequest Notes.V1.messageNote )
        , ( "ListNotes", entry Service.listNotes Service.listNotes Notes.V1.decodeListNotesRequest Notes.V1.messageListNotesResponse )
        , ( "CreateNote", entry Service.createNote Service.createNote Notes.V1.decodeCreateNoteRequest Notes.V1.messageNote )
        , ( "UpdateNote", entry Service.updateNote Service.updateNote Notes.V1.decodeUpdateNoteRequest Notes.V1.messageNote )
        , ( "DeleteNote", entry Service.deleteNote Service.deleteNote Notes.V1.decodeDeleteNoteRequest Proto.WellKnown.empty )
        , ( "ArchiveNote", entry Service.archiveNote Service.archiveNote Notes.V1.decodeArchiveNoteRequest Notes.V1.messageNote )
        , ( "Ping", entry Service.ping Service.ping Proto.Json.empty Proto.WellKnown.empty )
        ]
