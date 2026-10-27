module BadJsonClientAnnotation exposing (client)

{-| A client annotated `Rpc.Client Rpc.Json` built over `grpcWeb`.
-}

import Rpc
import Rpc.Protocol


client : Rpc.Client Rpc.Json
client =
    Rpc.client Rpc.Protocol.grpcWeb "https://demo.connectrpc.com"
