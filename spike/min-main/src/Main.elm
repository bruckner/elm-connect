port module Main exposing (main)

{-| The smallest honest program: one unary call of a generated method over
Connect, its error read through `Rpc.Error`.
-}

import Connectrpc.Eliza.V1
import Connectrpc.Eliza.V1.ElizaService as ElizaService
import Rpc
import Rpc.Error
import Rpc.Protocol


port reply : String -> Cmd msg


type Msg
    = GotReply (Result Rpc.Error Connectrpc.Eliza.V1.SayResponse)


main : Program String () Msg
main =
    Platform.worker
        { init =
            \sentence ->
                ( ()
                , ElizaService.say { sentence = sentence }
                    |> Rpc.send (Rpc.client Rpc.Protocol.connect "https://demo.connectrpc.com") GotReply
                )
        , update =
            \(GotReply result) _ ->
                case result of
                    Ok response ->
                        ( (), reply response.sentence )

                    Err error ->
                        ( (), reply (Rpc.Error.message error) )
        , subscriptions = \_ -> Sub.none
        }
