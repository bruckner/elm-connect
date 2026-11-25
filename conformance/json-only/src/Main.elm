port module Main exposing (main)

{-| A client that speaks JSON alone, its method built with
`Proto.Method.initJson`, over a protocol given every modifier. Compiled with
`--optimize`, it must hold nothing of elm/bytes' kernel: a modifier installs
both wires' functions, and the binary ones reach elm/bytes only through the
wire a binary constructor built (`just json-only-check`).
-}

import Json.Decode
import Json.Encode
import Proto.Json
import Proto.Method
import Rpc
import Rpc.Client
import Rpc.Code
import Rpc.Error
import Rpc.Protocol
import Rpc.Retry


port reply : String -> Cmd msg


protocol : Rpc.Protocol.Protocol Rpc.Json
protocol =
    Rpc.Protocol.connect
        |> Rpc.Protocol.withConnectGet
        |> Rpc.Protocol.withMaxGetUrl 2048
        |> Rpc.Protocol.withReadMaxBytes 100000
        |> Rpc.Protocol.withWriteMaxBytes 100000


client : Rpc.Client Rpc.Json
client =
    Rpc.client protocol "https://api.example.com"
        |> Rpc.Client.withRetry (Rpc.Retry.on [ Rpc.Code.Unavailable ])


echo : String -> Rpc.Call Rpc.Json String String
echo =
    Rpc.call
        (Proto.Method.initJson "echo.v1.Echo"
            "Echo"
            (\text -> Proto.Json.succeed (Json.Encode.string text))
            (\_ -> Json.Decode.string)
            |> Proto.Method.withIdempotency Proto.Method.IdempotencyNoSideEffects
        )


main : Program String () (Result Rpc.Error String)
main =
    Platform.worker
        { init = \text -> ( (), Rpc.send client identity (echo text) )
        , update =
            \result _ ->
                case result of
                    Ok text ->
                        ( (), reply text )

                    Err error ->
                        ( (), reply (Rpc.Error.message error) )
        , subscriptions = \_ -> Sub.none
        }
