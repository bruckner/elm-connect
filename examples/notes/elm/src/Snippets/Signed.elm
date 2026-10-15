module Snippets.Signed exposing (signed)

{-| The README's "Rewriting a request". `sign` stands for whatever an API asks
a request to be signed with.
-}

import Rpc
import Task exposing (Task)



-- region signed


signed : Rpc.Config -> Rpc.Call req res -> Task Rpc.Error res
signed cfg call =
    let
        request =
            Rpc.request cfg call
    in
    { request | headers = ( "X-Signature", sign request ) :: request.headers }
        |> Rpc.taskFromRequest cfg call



-- endregion signed


sign : Rpc.Request -> String
sign request =
    String.fromInt (String.length request.url + String.length (Maybe.withDefault "" request.body))
