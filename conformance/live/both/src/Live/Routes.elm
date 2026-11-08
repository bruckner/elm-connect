module Live.Routes exposing (table)

{-| The dispatch table of `routes.v1.Routes`, the route fixtures' service
(`conformance/routes/routes.proto`), which the example server echoes.

The build against `codec=both`: each entry has its JSON call and its binary
one. The build against `codec=json` has its own module of this name.

-}

import Live.Call exposing (Entry)
import Live.Codec exposing (entry)
import Routes.V1 as V1
import Routes.V1.Routes.Json as JsonCalls
import Routes.V1.Routes.Proto as ProtoCalls


{-| Each method by its service and name.
-}
table : List ( ( String, String ), Entry msg )
table =
    List.map (\( name, e ) -> ( ( "routes.v1.Routes", name ), e ))
        [ ( "GetMessage", entry JsonCalls.getMessage ProtoCalls.getMessage V1.decodeGetMessageRequest V1.messageMessage )
        , ( "UpdateMessage", entry JsonCalls.updateMessage ProtoCalls.updateMessage V1.decodeUpdateMessageRequest V1.messageMessage )
        , ( "UpdateMessageWhole", entry JsonCalls.updateMessageWhole ProtoCalls.updateMessageWhole V1.decodeMessage V1.messageMessage )
        , ( "PostSub", entry JsonCalls.postSub ProtoCalls.postSub V1.decodeGetMessageRequest V1.messageMessage )
        , ( "Query", entry JsonCalls.query ProtoCalls.query V1.decodeEverything V1.messageEverything )
        , ( "Single", entry JsonCalls.single ProtoCalls.single V1.decodeEverything V1.messageEverything )
        , ( "Multi", entry JsonCalls.multi ProtoCalls.multi V1.decodeEverything V1.messageEverything )
        , ( "Typed", entry JsonCalls.typed ProtoCalls.typed V1.decodeEverything V1.messageEverything )
        , ( "Files", entry JsonCalls.files ProtoCalls.files V1.decodeFileRequest V1.messageFileRequest )
        , ( "Cancel", entry JsonCalls.cancel ProtoCalls.cancel V1.decodeResource V1.messageResource )
        , ( "UpdateResource", entry JsonCalls.updateResource ProtoCalls.updateResource V1.decodeUpdateResourceRequest V1.messageResource )
        , ( "Head", entry JsonCalls.head ProtoCalls.head V1.decodeFileRequest V1.messageFileRequest )
        , ( "Unbound", entry JsonCalls.unbound ProtoCalls.unbound V1.decodeGetMessageRequest V1.messageMessage )
        ]
