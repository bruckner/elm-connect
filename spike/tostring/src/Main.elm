port module Main exposing (main)

{-| Prints `Debug.toString` of a client, a call and an endpoint: what the
debugger and a log show of each. Run with spike/tostring/run.sh.
-}

import Connectrpc.Eliza.V1.ElizaService as ElizaService
import Rpc
import Rpc.Call
import Rpc.Client
import Rpc.Code
import Rpc.Protocol
import Rpc.Retry


port out : String -> Cmd msg


client : Rpc.Client Rpc.Json
client =
    Rpc.client (Rpc.Protocol.withConnectGet Rpc.Protocol.connect) "https://demo.connectrpc.com"
        |> Rpc.Client.withTimeout 5000
        |> Rpc.Client.withRetry (Rpc.Retry.on [ Rpc.Code.Unavailable ])


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                ( ()
                , out
                    (String.join "\n"
                        [ "client:   " ++ Debug.toString client
                        , "call:     " ++ Debug.toString (ElizaService.say { sentence = "hi" })
                        , "endpoint: " ++ Debug.toString (Rpc.Call.endpoint (ElizaService.say { sentence = "hi" }))
                        ]
                    )
                )
        , update = \_ _ -> ( (), Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
