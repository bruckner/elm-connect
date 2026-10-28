module Live.Codec exposing (entry)

{-| The dispatch tables' entries, for the build against bindings generated
with `codec=json`: a generated call is `Rpc.Call Rpc.Json`, so an entry has
the JSON call function alone, and an envelope naming the proto codec is
refused. The build against `codec=both` has its own module of this name
(`both/src/Live/Codec.elm`).
-}

import Json.Decode exposing (Decoder)
import Live.Call exposing (Entry)
import Proto.Message exposing (Message)
import Rpc


{-| The entry for a method, from its generated call function, given twice so
that the tables read the same in both builds, its request's decoder and its
response's message.
-}
entry : (req -> Rpc.Call Rpc.Json req res) -> (req -> Rpc.Call Rpc.Json req res) -> Decoder req -> Message res -> Entry msg
entry toCall _ =
    Live.Call.entryWith { json = Just toCall, proto = Nothing }
