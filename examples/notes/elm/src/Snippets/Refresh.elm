module Snippets.Refresh exposing (withRefresh)

{-| The README's token refresh, a wrapper around this example's `Api.rpc`.
-}

import Api exposing (Shared, rpc)
import Rpc
import Rpc.ErrorCode
import Task exposing (Task)



-- region refresh


withRefresh : Task Rpc.Error Shared -> Shared -> Rpc.Call req res -> Task Rpc.Error res
withRefresh refresh shared call =
    rpc shared call
        |> Task.onError
            (\error ->
                if Rpc.code error == Rpc.ErrorCode.Unauthenticated then
                    refresh |> Task.andThen (\fresh -> rpc fresh call)

                else
                    Task.fail error
            )



-- endregion refresh
