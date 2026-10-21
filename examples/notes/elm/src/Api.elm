module Api exposing (Shared, config, rpc)

{-| How this application sends a call: every call goes through `rpc`, which
builds the config from the application's state. docs/calling.md's "Wrapping
the sending once" and this example's walkthrough quote it.
-}

import Rpc
import Rpc.Transport
import Task exposing (Task)


{-| What the config is built from: where the API is, the token every call
carries, and the transport the page's toggle chose.
-}
type alias Shared =
    { apiUrl : String
    , token : String
    , transport : Rpc.Transport.Transport
    }



-- region wrapper


rpc : Shared -> Rpc.Call req res -> Task Rpc.Error res
rpc shared call =
    Rpc.task (config shared) call


config : Shared -> Rpc.Config
config shared =
    let
        base =
            Rpc.config shared.apiUrl
    in
    { base
        | transport = shared.transport
        , headers = [ ( "Authorization", "Bearer " ++ shared.token ) ]
    }



-- endregion wrapper
