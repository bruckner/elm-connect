module Live.Routes exposing (table)

{-| The dispatch table of `routes.v1.Routes`, the route fixtures' service
(`conformance/routes/routes.proto`), which the example server echoes.
-}

import Live.Call exposing (Entry, entry)
import Routes.V1 as V1
import Routes.V1.Routes as Service


{-| Each method by its service and name.
-}
table : List ( ( String, String ), Entry msg )
table =
    List.map (\( name, e ) -> ( ( "routes.v1.Routes", name ), e ))
        [ ( "GetMessage", entry Service.getMessage V1.decodeGetMessageRequest V1.encodeMessage )
        , ( "UpdateMessage", entry Service.updateMessage V1.decodeUpdateMessageRequest V1.encodeMessage )
        , ( "UpdateMessageWhole", entry Service.updateMessageWhole V1.decodeMessage V1.encodeMessage )
        , ( "PostSub", entry Service.postSub V1.decodeGetMessageRequest V1.encodeMessage )
        , ( "Query", entry Service.query V1.decodeEverything V1.encodeEverything )
        , ( "Single", entry Service.single V1.decodeEverything V1.encodeEverything )
        , ( "Multi", entry Service.multi V1.decodeEverything V1.encodeEverything )
        , ( "Typed", entry Service.typed V1.decodeEverything V1.encodeEverything )
        , ( "Files", entry Service.files V1.decodeFileRequest V1.encodeFileRequest )
        , ( "Cancel", entry Service.cancel V1.decodeResource V1.encodeResource )
        , ( "UpdateResource", entry Service.updateResource V1.decodeUpdateResourceRequest V1.encodeResource )
        , ( "Head", entry Service.head V1.decodeFileRequest V1.encodeFileRequest )
        , ( "Unbound", entry Service.unbound V1.decodeGetMessageRequest V1.encodeMessage )
        ]
