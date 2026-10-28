module Snippets.Signed exposing (signed)

{-| docs/calling.md's "Rewriting a request". `sign` stands for whatever an API asks
a request to be signed with.
-}

import Rpc
import Rpc.Body
import Task exposing (Task)



-- region signed


signed : Rpc.Client codec -> Rpc.Call codec req res -> Task Rpc.Error res
signed client call =
    let
        request =
            Rpc.request client call
    in
    { request | headers = ( "X-Signature", sign request ) :: request.headers }
        |> Rpc.taskFromRequest client call



-- endregion signed


sign : Rpc.Request -> String
sign request =
    String.fromInt (String.length request.url + String.length (Maybe.withDefault "" (Rpc.Body.toText request.body)))
