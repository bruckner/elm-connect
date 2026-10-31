module Live.Conformance exposing (table)

{-| The dispatch table of `connectrpc.conformance.v1.ConformanceService`, the
Connect conformance suite's service: its unary methods, which are all
elm-connect generates (`streaming=skip` leaves the rest out).
-}

import Connectrpc.Conformance.V1 as V1
import Connectrpc.Conformance.V1.ConformanceService as Service
import Live.Call exposing (Entry)
import Live.Codec exposing (entry)


{-| Each method by its service and name.
-}
table : List ( ( String, String ), Entry msg )
table =
    List.map (\( name, e ) -> ( ( "connectrpc.conformance.v1.ConformanceService", name ), e ))
        [ ( "Unary", entry Service.unary Service.unary V1.decodeUnaryRequest V1.messageUnaryResponse )
        , ( "IdempotentUnary", entry Service.idempotentUnary Service.idempotentUnary V1.decodeIdempotentUnaryRequest V1.messageIdempotentUnaryResponse )
        , ( "Unimplemented", entry Service.unimplemented Service.unimplemented V1.decodeUnimplementedRequest V1.messageUnimplementedResponse )
        ]
