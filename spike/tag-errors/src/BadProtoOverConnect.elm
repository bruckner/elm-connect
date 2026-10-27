module BadProtoOverConnect exposing (fetch)

{-| A `Call Proto` (generated with `codec=proto`) sent over `connect`.
-}

import Connectrpc.Eliza.V1 exposing (SayResponse)
import Good
import Rpc
import Rpc.Protocol


type Msg
    = GotReply (Result Rpc.Error SayResponse)


fetch : Cmd Msg
fetch =
    Good.sayProto { sentence = "hi" }
        |> Rpc.send (Rpc.client Rpc.Protocol.connect "https://demo.connectrpc.com") GotReply
