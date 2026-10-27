module BadJsonOverGrpcWeb exposing (fetch)

{-| A `Call Json` (the generated Eliza service, `codec=json`) sent over
`grpcWeb`, through a top-level client annotated as the quick start writes it.
-}

import Connectrpc.Eliza.V1 exposing (SayResponse)
import Connectrpc.Eliza.V1.ElizaService as ElizaService
import Rpc
import Rpc.Protocol


type Msg
    = GotReply (Result Rpc.Error SayResponse)


client : Rpc.Client Rpc.Proto
client =
    Rpc.client Rpc.Protocol.grpcWeb "https://demo.connectrpc.com"


fetch : Cmd Msg
fetch =
    ElizaService.say { sentence = "hi" }
        |> Rpc.send client GotReply
