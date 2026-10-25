module Live.Notes exposing (streams, table)

{-| The dispatch table of `notes.v1.NotesService`, the example API's service.
-}

import Live.Call exposing (Entry, entry)
import Live.Stream
import Notes.V1
import Notes.V1.NotesService as Service
import Proto.Json


{-| Each method by its service and name.
-}
table : List ( ( String, String ), Entry msg )
table =
    List.map (\( name, e ) -> ( ( "notes.v1.NotesService", name ), e ))
        [ ( "GetNote", entry Service.getNote Notes.V1.decodeGetNoteRequest Notes.V1.encodeNote )
        , ( "ListNotes", entry Service.listNotes Notes.V1.decodeListNotesRequest Notes.V1.encodeListNotesResponse )
        , ( "CreateNote", entry Service.createNote Notes.V1.decodeCreateNoteRequest Notes.V1.encodeNote )
        , ( "UpdateNote", entry Service.updateNote Notes.V1.decodeUpdateNoteRequest Notes.V1.encodeNote )
        , ( "DeleteNote", entry Service.deleteNote Notes.V1.decodeDeleteNoteRequest Proto.Json.encodeEmpty )
        , ( "ArchiveNote", entry Service.archiveNote Notes.V1.decodeArchiveNoteRequest Notes.V1.encodeNote )
        , ( "Ping", entry Service.ping Proto.Json.empty Proto.Json.encodeEmpty )
        ]


{-| Each server-streaming method by its service and name.
-}
streams : List ( ( String, String ), Live.Stream.Entry )
streams =
    [ ( ( "notes.v1.NotesService", "WatchNotes" ), Live.Stream.entry Service.watchNotes Notes.V1.decodeWatchNotesRequest Notes.V1.encodeNoteEvent ) ]
