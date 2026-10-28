module Live.OneCodec exposing (table)

{-| The dispatch table of methods with one codec of the two, built from the
bindings generated with `codec=both` as code generated with `codec=json` and
with `codec=binary` builds them: `notes.v1.NotesService`'s `GetNote` with its
JSON codecs alone (dispatched as `GetNoteJsonOnly`) and with its binary codecs
alone (`GetNoteBinaryOnly`), each called by the method's own name, so that a
case can show each refused under the other codec.
-}

import Live.Call exposing (Entry, entry)
import Notes.V1
import Notes.V1.NotesService as Service
import Proto.Method
import Rpc


table : List ( ( String, String ), Entry msg )
table =
    List.map (\( name, e ) -> ( ( "notes.v1.NotesService", name ), e ))
        [ ( "GetNoteJsonOnly"
          , entry
                (Rpc.call
                    (Proto.Method.method Notes.V1.encodeGetNoteRequest Notes.V1.decodeNote "notes.v1.NotesService" "GetNote"
                        |> Proto.Method.withIdempotency Proto.Method.IdempotencyNoSideEffects
                        |> Proto.Method.withRoutes [ Service.routeGetNote0 ]
                    )
                )
                Notes.V1.decodeGetNoteRequest
                Notes.V1.messageNote
          )
        , ( "GetNoteBinaryOnly"
          , entry
                (Rpc.call
                    (Proto.Method.methodBinary Notes.V1.encodeGetNoteRequestBytes Notes.V1.decodeNoteBytes "notes.v1.NotesService" "GetNote"
                        |> Proto.Method.withIdempotency Proto.Method.IdempotencyNoSideEffects
                    )
                )
                Notes.V1.decodeGetNoteRequest
                Notes.V1.messageNote
          )
        ]
