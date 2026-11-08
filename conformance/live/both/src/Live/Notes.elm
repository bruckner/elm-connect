module Live.Notes exposing (table)

{-| The dispatch table of `notes.v1.NotesService`, the example API's service.

The build against `codec=both`: each entry has its JSON call and its binary
one. The build against `codec=json` has its own module of this name.

-}

import Live.Call exposing (Entry)
import Live.Codec exposing (entry)
import Notes.V1
import Notes.V1.NotesService.Json as JsonCalls
import Notes.V1.NotesService.Proto as ProtoCalls
import Proto.Json


{-| Each method by its service and name.
-}
table : List ( ( String, String ), Entry msg )
table =
    List.map (\( name, e ) -> ( ( "notes.v1.NotesService", name ), e ))
        [ ( "GetNote", entry JsonCalls.getNote ProtoCalls.getNote Notes.V1.decodeGetNoteRequest Notes.V1.messageNote )
        , ( "ListNotes", entry JsonCalls.listNotes ProtoCalls.listNotes Notes.V1.decodeListNotesRequest Notes.V1.messageListNotesResponse )
        , ( "CreateNote", entry JsonCalls.createNote ProtoCalls.createNote (Notes.V1.decodeCreateNoteRequestWith Live.Codec.registry) Notes.V1.messageNote )
        , ( "UpdateNote", entry JsonCalls.updateNote ProtoCalls.updateNote (Notes.V1.decodeUpdateNoteRequestWith Live.Codec.registry) Notes.V1.messageNote )
        , ( "DeleteNote", entry JsonCalls.deleteNote ProtoCalls.deleteNote Notes.V1.decodeDeleteNoteRequest Live.Codec.empty )
        , ( "ArchiveNote", entry JsonCalls.archiveNote ProtoCalls.archiveNote Notes.V1.decodeArchiveNoteRequest Notes.V1.messageNote )
        , ( "Ping", entry JsonCalls.ping ProtoCalls.ping Proto.Json.empty Live.Codec.empty )
        ]
