module Live.Routes exposing (table)

{-| The dispatch table of `routes.v1.Routes`, the route fixtures' service
(`conformance/routes/routes.proto`), which the example server echoes.
-}

import Live.Call exposing (Entry)
import Live.Codec exposing (entry)
import Routes.V1 as V1
import Routes.V1.Routes as Service


{-| Each method by its service and name.
-}
table : List ( ( String, String ), Entry msg )
table =
    List.map (\( name, e ) -> ( ( "routes.v1.Routes", name ), e ))
        [ ( "GetMessage", entry Service.getMessage Service.getMessage V1.decodeGetMessageRequest V1.messageMessage )
        , ( "UpdateMessage", entry Service.updateMessage Service.updateMessage V1.decodeUpdateMessageRequest V1.messageMessage )
        , ( "UpdateMessageWhole", entry Service.updateMessageWhole Service.updateMessageWhole V1.decodeMessage V1.messageMessage )
        , ( "PostSub", entry Service.postSub Service.postSub V1.decodeGetMessageRequest V1.messageMessage )
        , ( "Query", entry Service.query Service.query V1.decodeEverything V1.messageEverything )
        , ( "Single", entry Service.single Service.single V1.decodeEverything V1.messageEverything )
        , ( "Multi", entry Service.multi Service.multi V1.decodeEverything V1.messageEverything )
        , ( "Typed", entry Service.typed Service.typed V1.decodeEverything V1.messageEverything )
        , ( "Files", entry Service.files Service.files V1.decodeFileRequest V1.messageFileRequest )
        , ( "Cancel", entry Service.cancel Service.cancel V1.decodeResource V1.messageResource )
        , ( "UpdateResource", entry Service.updateResource Service.updateResource V1.decodeUpdateResourceRequest V1.messageResource )
        , ( "Head", entry Service.head Service.head V1.decodeFileRequest V1.messageFileRequest )
        , ( "Unbound", entry Service.unbound Service.unbound V1.decodeGetMessageRequest V1.messageMessage )
        ]
