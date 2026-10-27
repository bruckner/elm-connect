port module Eq exposing (main)

{-| The ClientTest comparisons in an `--optimize` build, where record fields
are renamed: clients built alike are `==`, clients differing in one
modifier are not, and none of it throws. Run with spike/tostring/run.sh.
-}

import Rpc
import Rpc.Client
import Rpc.Code
import Rpc.Protocol
import Rpc.Retry


port out : String -> Cmd msg


every : Rpc.Protocol.Protocol codec -> Rpc.Client codec
every protocol =
    Rpc.client (protocol |> Rpc.Protocol.withConnectGet |> Rpc.Protocol.withMaxGetUrl 2048 |> Rpc.Protocol.withReadMaxBytes 1000000 |> Rpc.Protocol.withWriteMaxBytes 100000) "https://api.example.com"
        |> Rpc.Client.withHeaders [ ( "Authorization", "Bearer t" ) ]
        |> Rpc.Client.withTimeout 5000
        |> Rpc.Client.withCredentials
        |> Rpc.Client.withRetry (Rpc.Retry.on [ Rpc.Code.Unavailable ] |> Rpc.Retry.withAttempts 5 |> Rpc.Retry.withDeadline 10000)


base : Rpc.Client Rpc.Json
base =
    Rpc.client Rpc.Protocol.connect "https://api.example.com"


main : Program () () ()
main =
    Platform.worker
        { init =
            \_ ->
                ( ()
                , out
                    (listText
                        [ every Rpc.Protocol.connect == every Rpc.Protocol.connect
                        , every Rpc.Protocol.transcode == every Rpc.Protocol.transcode
                        , every Rpc.Protocol.connectProto == every Rpc.Protocol.connectProto
                        , every Rpc.Protocol.grpcWeb == every Rpc.Protocol.grpcWeb
                        , Rpc.client Rpc.Protocol.transcode "https://api.example.com" == base
                        , Rpc.client (Rpc.Protocol.withConnectGet Rpc.Protocol.connect) "https://api.example.com" == base
                        , Rpc.client (Rpc.Protocol.withReadMaxBytes 10 Rpc.Protocol.connect) "https://api.example.com" == base
                        , Rpc.client (Rpc.Protocol.withWriteMaxBytes 10 Rpc.Protocol.connect) "https://api.example.com" == base
                        , (base |> Rpc.Client.withRetry (Rpc.Retry.on [ Rpc.Code.Unavailable ])) == base
                        , (base |> Rpc.Client.withRetry (Rpc.Retry.on [ Rpc.Code.Unavailable ])) == (base |> Rpc.Client.withRetry (Rpc.Retry.on [ Rpc.Code.Aborted ]))
                        ]
                    )
                )
        , update = \_ _ -> ( (), Cmd.none )
        , subscriptions = \_ -> Sub.none
        }


listText : List Bool -> String
listText =
    List.map
        (\b ->
            if b then
                "True"

            else
                "False"
        )
        >> String.join ","
