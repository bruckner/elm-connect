module Api exposing (Shared, client, registry, rpc)

{-| How this application sends a call: every call goes through `rpc`, which
builds the client from the application's state. docs/calling.md's "Wrapping
the sending once" and this example's walkthrough quote it.
-}

import Notes.V1
import Proto.ErrorDetails
import Proto.Registry
import Rpc
import Rpc.Client
import Rpc.Protocol
import Task exposing (Task)


{-| What the client is built from: where the API is, the token every call
carries, and the protocol the page's toggle chose.
-}
type alias Shared =
    { apiUrl : String
    , token : String
    , protocol : Rpc.Protocol.Protocol Rpc.Json
    }



-- region wrapper


rpc : Shared -> Rpc.Call Rpc.Json req res -> Task Rpc.Error res
rpc shared call =
    Rpc.task (client shared) call


client : Shared -> Rpc.Client Rpc.Json
client shared =
    Rpc.client shared.protocol shared.apiUrl
        |> Rpc.Client.withHeaders [ ( "Authorization", "Bearer " ++ shared.token ) ]
        |> Rpc.withRegistry registry



-- endregion wrapper
-- region registry


{-| The types an `Any` this page reads as proto3 JSON may hold: a note's
attachment (the package's own messages or a well-known type), and the
`google.rpc` error details a transcoder's status body carries.
-}
registry : Proto.Registry.Registry
registry =
    Proto.Registry.unionAll
        [ Notes.V1.registry
        , Proto.Registry.wellKnown
        , Proto.ErrorDetails.registry
        ]



-- endregion registry
