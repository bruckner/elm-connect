port module MinCode exposing (main)

{-| The smallest program again, reading only the error's code: what a program pays
when it never asks for a message.
-}

import Connectrpc.Eliza.V1
import Connectrpc.Eliza.V1.ElizaService as ElizaService
import Rpc
import Rpc.Code
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
                        ( (), reply (String.fromInt (Rpc.Code.toInt (Rpc.Error.code error))) )
        , subscriptions = \_ -> Sub.none
        }
