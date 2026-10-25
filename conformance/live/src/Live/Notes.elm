module Live.Notes exposing (table)

{-| The dispatch table of `notes.v1.NotesService`, the example API's service.
-}

import Live.Call exposing (Entry, entry)
import Notes.V1
import Notes.V1.NotesService as Service
import Proto.Json
import Proto.WellKnown


{-| Each method by its service and name.
-}
table : List ( ( String, String ), Entry msg )
table =
    List.map (\( name, e ) -> ( ( "notes.v1.NotesService", name ), e ))
        [ ( "GetNote", entry Service.getNote Notes.V1.decodeGetNoteRequest Notes.V1.messageNote )
        , ( "ListNotes", entry Service.listNotes Notes.V1.decodeListNotesRequest Notes.V1.messageListNotesResponse )
        , ( "CreateNote", entry Service.createNote Notes.V1.decodeCreateNoteRequest Notes.V1.messageNote )
        , ( "UpdateNote", entry Service.updateNote Notes.V1.decodeUpdateNoteRequest Notes.V1.messageNote )
        , ( "DeleteNote", entry Service.deleteNote Notes.V1.decodeDeleteNoteRequest Proto.WellKnown.empty )
        , ( "ArchiveNote", entry Service.archiveNote Notes.V1.decodeArchiveNoteRequest Notes.V1.messageNote )
        , ( "Ping", entry Service.ping Proto.Json.empty Proto.WellKnown.empty )
        ]
