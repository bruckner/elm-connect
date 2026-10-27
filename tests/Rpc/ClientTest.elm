module Rpc.ClientTest exposing (suite)

{-| Clients and protocols hold functions, every one a top-level function a
constructor or modifier put there, with their settings as data: two built
alike are `==`, and two that differ compare unequal on their data before
`==` would reach a function.
-}

import Expect
import Json.Decode
import Json.Encode
import Proto.Method exposing (Idempotency(..))
import Rpc
import Rpc.Call
import Rpc.Client
import Rpc.Code
import Rpc.Protocol
import Rpc.Retry
import Test exposing (Test, describe, test)


every : Rpc.Protocol.Protocol codec -> Rpc.Client codec
every protocol =
    Rpc.client
        (protocol
            |> Rpc.Protocol.withConnectGet
            |> Rpc.Protocol.withMaxGetUrl 2048
            |> Rpc.Protocol.withReadMaxBytes 1000000
            |> Rpc.Protocol.withWriteMaxBytes 100000
        )
        "https://api.example.com"
        |> Rpc.Client.withHeaders [ ( "Authorization", "Bearer t" ) ]
        |> Rpc.Client.withTimeout 5000
        |> Rpc.Client.withCredentials
        |> Rpc.Client.withRetry
            (Rpc.Retry.on [ Rpc.Code.Unavailable ]
                |> Rpc.Retry.withAttempts 5
                |> Rpc.Retry.withBackoff 100
                |> Rpc.Retry.withMaxBackoff 1000
                |> Rpc.Retry.withDeadline 10000
                |> Rpc.Retry.withoutJitter
                |> Rpc.Retry.allowNonIdempotent
            )


base : Rpc.Client Rpc.Json
base =
    Rpc.client Rpc.Protocol.connect "https://api.example.com"


{-| Clients differing from `base` in one modifier each.
-}
variants : List ( String, Rpc.Client Rpc.Json )
variants =
    [ ( "protocol", Rpc.client Rpc.Protocol.transcode "https://api.example.com" )
    , ( "base URL", Rpc.client Rpc.Protocol.connect "https://other.example.com" )
    , ( "withConnectGet", Rpc.client (Rpc.Protocol.withConnectGet Rpc.Protocol.connect) "https://api.example.com" )
    , ( "withMaxGetUrl", Rpc.client (Rpc.Protocol.withMaxGetUrl 10 Rpc.Protocol.connect) "https://api.example.com" )
    , ( "withReadMaxBytes", Rpc.client (Rpc.Protocol.withReadMaxBytes 10 Rpc.Protocol.connect) "https://api.example.com" )
    , ( "withWriteMaxBytes", Rpc.client (Rpc.Protocol.withWriteMaxBytes 10 Rpc.Protocol.connect) "https://api.example.com" )
    , ( "withHeaders", base |> Rpc.Client.withHeaders [ ( "X", "1" ) ] )
    , ( "withTimeout", base |> Rpc.Client.withTimeout 10 )
    , ( "withCredentials", base |> Rpc.Client.withCredentials )
    , ( "withRetry", base |> Rpc.Client.withRetry (Rpc.Retry.on [ Rpc.Code.Unavailable ]) )
    ]


call : Rpc.Call Rpc.Json { name : String } ()
call =
    Rpc.call
        (Proto.Method.json (\r -> Json.Encode.object [ ( "name", Json.Encode.string r.name ) ])
            (Json.Decode.succeed ())
            (Proto.Method.endpoint "notes.v1.Notes" "GetNote" IdempotencyNoSideEffects)
        )
        { name = "notes/42" }


suite : Test
suite =
    describe "== on clients"
        [ test "two clients built alike with every modifier are ==, over each protocol" <|
            \_ ->
                [ every Rpc.Protocol.connect == every Rpc.Protocol.connect
                , every Rpc.Protocol.transcode == every Rpc.Protocol.transcode
                ]
                    ++ [ every Rpc.Protocol.connectProto == every Rpc.Protocol.connectProto
                       , every Rpc.Protocol.grpcWeb == every Rpc.Protocol.grpcWeb
                       ]
                    |> Expect.equal [ True, True, True, True ]
        , test "a client is == to itself and to one built alike without modifiers" <|
            \_ ->
                ( base == base, base == Rpc.client Rpc.Protocol.connect "https://api.example.com" )
                    |> Expect.equal ( True, True )
        , test "clients differing in one modifier compare unequal, without throwing" <|
            \_ ->
                List.map (\( name, other ) -> ( name, other == base, base == other )) variants
                    |> Expect.equal (List.map (\( name, _ ) -> ( name, False, False )) variants)
        , test "two retry policies built alike are ==, two that differ are not" <|
            \_ ->
                ( Rpc.Retry.on [ Rpc.Code.Unavailable ] == Rpc.Retry.on [ Rpc.Code.Unavailable ]
                , Rpc.Retry.on [ Rpc.Code.Unavailable ] == Rpc.Retry.on [ Rpc.Code.Aborted ]
                )
                    |> Expect.equal ( True, False )
        , test "a client's data reads back, as JSON for logs" <|
            \_ ->
                Json.Encode.encode 0 (Rpc.Client.toJson (Rpc.client (Rpc.Protocol.withConnectGet Rpc.Protocol.connect) "https://api.example.com" |> Rpc.Client.withTimeout 5000))
                    |> Expect.equal """{"protocol":{"name":"connect","codec":"json","get":true,"maxGetUrl":null,"readMaxBytes":null,"writeMaxBytes":null},"baseUrl":"https://api.example.com","headers":[],"timeout":5000,"withCredentials":false,"retry":false}"""
        , test "Debug.toString of a client and of a call (what a debugger shows)" <|
            \_ ->
                ( Debug.toString base, Debug.toString call, Debug.toString (Rpc.Call.endpoint call) )
                    |> Debug.log "toString"
                    |> (\_ -> Expect.pass)
        ]
