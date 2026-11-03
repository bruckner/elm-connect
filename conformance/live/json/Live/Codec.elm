module Live.Codec exposing (empty, entry)

{-| The dispatch tables' entries, for the build against bindings generated
with `codec=json`: a generated call is `Rpc.Call Rpc.Json`, so an entry has
the JSON call function alone, and an envelope naming the proto codec is
refused. The build against `codec=both` has its own module of this name
(`both/src/Live/Codec.elm`).
-}

import Json.Decode exposing (Decoder)
import Live.Call exposing (Entry)
import Proto.Any
import Proto.Codec exposing (Json)
import Proto.Message exposing (Message)
import Proto.WellKnown
import Rpc


{-| The entry for a method, from its generated call function, given twice so
that the tables read the same in both builds, its request's decoder and its
response's typed value, whose JSON the response is written as.
-}
entry : (req -> Rpc.Call Rpc.Json req res) -> (req -> Rpc.Call Rpc.Json req res) -> Decoder req -> Message Json res -> Entry msg
entry toCall _ decoder message =
    Live.Call.entryWith { json = Just toCall, proto = Nothing }
        decoder
        (\response -> [ ( "ok", Proto.Any.json (Proto.Any.packJson message response) ) ])


{-| `google.protobuf.Empty`'s typed value in this build's world.
-}
empty : Message Json ()
empty =
    Proto.WellKnown.empty
