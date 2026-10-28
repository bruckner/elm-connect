module Snippets.Refresh exposing (withRefresh)

{-| docs/calling.md's token refresh, a wrapper around this example's `Api.rpc`.
-}

import Api exposing (Shared, rpc)
import Rpc
import Rpc.Code
import Rpc.Error
import Task exposing (Task)



-- region refresh


withRefresh : Task Rpc.Error Shared -> Shared -> Rpc.Call Rpc.Json req res -> Task Rpc.Error res
withRefresh refresh shared call =
    rpc shared call
        |> Task.onError
            (\error ->
                if Rpc.Error.code error == Rpc.Code.Unauthenticated then
                    refresh |> Task.andThen (\fresh -> rpc fresh call)

                else
                    Task.fail error
            )



-- endregion refresh
