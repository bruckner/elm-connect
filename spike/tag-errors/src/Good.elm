module Good exposing (binaryClient, jsonClient, rpc, sayBoth, sayProto)

{-| A type named `Proto` beside `import Proto.Method` and the other `Proto.*`
modules in one module: types and modules are separate namespaces, so
`Proto` (the tag, exposed from Rpc) and `Proto.Method` (a module) coexist.
-}

import Connectrpc.Eliza.V1 exposing (SayRequest, SayResponse)
import Bytes.Encode
import Json.Decode
import Json.Encode
import Proto.Binary
import Proto.Method
import Rpc exposing (Json, Proto)
import Rpc.Protocol
import Task exposing (Task)


jsonClient : Rpc.Client Json
jsonClient =
    Rpc.client Rpc.Protocol.connect "https://demo.connectrpc.com"


binaryClient : Rpc.Client Proto
binaryClient =
    Rpc.client Rpc.Protocol.grpcWeb "https://demo.connectrpc.com"


endpoint : Proto.Method.Endpoint
endpoint =
    Proto.Method.endpoint "connectrpc.eliza.v1.ElizaService" "Say" Proto.Method.IdempotencyNoSideEffects


sayProto : SayRequest -> Rpc.Call Proto SayRequest SayResponse
sayProto =
    Rpc.call (Proto.Method.proto (\_ -> Bytes.Encode.sequence []) (Proto.Binary.merge (\_ wire r -> Proto.Binary.skip wire r) identity { sentence = "" }) endpoint)


sayBoth : SayRequest -> Rpc.Call codec SayRequest SayResponse
sayBoth =
    Rpc.call
        (Proto.Method.both (\_ -> Json.Encode.null)
            (Json.Decode.succeed { sentence = "" })
            (\_ -> Bytes.Encode.sequence [])
            (Proto.Binary.merge (\_ wire r -> Proto.Binary.skip wire r) identity { sentence = "" })
            endpoint
        )


rpc : Rpc.Client codec -> Rpc.Call codec req res -> Task Rpc.Error res
rpc =
    Rpc.task
