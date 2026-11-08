module Live.Conformance exposing (table)

{-| The dispatch table of `connectrpc.conformance.v1.ConformanceService`, the
Connect conformance suite's service: its unary methods, which are all
elm-connect generates (`streaming=skip` leaves the rest out).

The build against `codec=both`: each entry has its JSON call and its binary
one. The build against `codec=json` has its own module of this name.

-}

import Connectrpc.Conformance.V1 as V1
import Connectrpc.Conformance.V1.ConformanceService.Json as JsonCalls
import Connectrpc.Conformance.V1.ConformanceService.Proto as ProtoCalls
import Live.Call exposing (Entry)
import Live.Codec exposing (entry)


{-| Each method by its service and name.
-}
table : List ( ( String, String ), Entry msg )
table =
    List.map (\( name, e ) -> ( ( "connectrpc.conformance.v1.ConformanceService", name ), e ))
        [ ( "Unary", entry JsonCalls.unary ProtoCalls.unary (V1.decodeUnaryRequestWith Live.Codec.registry) V1.messageUnaryResponse )
        , ( "IdempotentUnary", entry JsonCalls.idempotentUnary ProtoCalls.idempotentUnary (V1.decodeIdempotentUnaryRequestWith Live.Codec.registry) V1.messageIdempotentUnaryResponse )
        , ( "Unimplemented", entry JsonCalls.unimplemented ProtoCalls.unimplemented V1.decodeUnimplementedRequest V1.messageUnimplementedResponse )
        ]
