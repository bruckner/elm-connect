module Api exposing (Shared, client, rpc)

{-| How this application sends a call: every call goes through `rpc`, which
builds the client from the application's state. docs/calling.md's "Wrapping
the sending once" and this example's walkthrough quote it.
-}

import Rpc
import Rpc.Client
import Rpc.Protocol
import Task exposing (Task)


{-| What the client is built from: where the API is, the token every call
carries, and the protocol the page's toggle chose. Connect and transcoding
both speak JSON, so one field holds either.
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



-- endregion wrapper
