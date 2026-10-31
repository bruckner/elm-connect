module Live.Codec exposing (entry)

{-| The dispatch tables' entries, for the build against bindings generated
with `codec=both`: a generated call is free in its codec, so an entry has it
as a JSON call and as a protobuf binary one, and sends an envelope in the
codec it names. The build against `codec=json` has its own module of this
name (`json/Live/Codec.elm`).
-}

import Json.Decode exposing (Decoder)
import Live.Call exposing (Entry)
import Proto.Message exposing (Message)
import Rpc


{-| The entry for a method, from its generated call function, given twice
(an argument holds one type, so one is taken at each codec), its request's
decoder and its response's message.
-}
entry : (req -> Rpc.Call Rpc.Json req res) -> (req -> Rpc.Call Rpc.Proto req res) -> Decoder req -> Message res -> Entry msg
entry toJsonCall toProtoCall =
    Live.Call.entryWith { json = Just toJsonCall, proto = Just toProtoCall }
