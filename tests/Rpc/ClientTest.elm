module Rpc.ClientTest exposing (suite)

{-| Clients and protocols hold functions, every one a top-level function a
constructor or modifier put there, with their settings as data: two built
alike are `==`, and two that differ compare unequal on their data before
`==` would reach a function, which would throw.
-}

import Expect
import Json.Encode
import Rpc
import Rpc.Client
import Rpc.Code
import Rpc.Protocol exposing (Protocol)
import Rpc.Retry exposing (Retry)
import Test exposing (Test, describe, test)


url : String
url =
    "https://api.example.com"


policy : Retry
policy =
    Rpc.Retry.on [ Rpc.Code.Unavailable ]
        |> Rpc.Retry.withAttempts 5
        |> Rpc.Retry.withBackoff 100
        |> Rpc.Retry.withMaxBackoff 1000
        |> Rpc.Retry.withDeadline 10000
        |> Rpc.Retry.withoutJitter
        |> Rpc.Retry.allowNonIdempotent


{-| Every modifier, each named, as protocol modifiers and client modifiers.
-}
type alias Modifiers codec =
    { protocol : List ( String, Protocol codec -> Protocol codec )
    , client : List ( String, Rpc.Client codec -> Rpc.Client codec )
    }


modifiers : Modifiers codec
modifiers =
    { protocol =
        [ ( "withConnectGet", Rpc.Protocol.withConnectGet )
        , ( "withMaxGetUrl", Rpc.Protocol.withMaxGetUrl 2048 )
        , ( "withReadMaxBytes", Rpc.Protocol.withReadMaxBytes 1000000 )
        , ( "withWriteMaxBytes", Rpc.Protocol.withWriteMaxBytes 100000 )
        ]
    , client =
        [ ( "withHeaders", Rpc.Client.withHeaders [ ( "Authorization", "Bearer t" ) ] )
        , ( "withTimeout", Rpc.Client.withTimeout 5000 )
        , ( "withCredentials", Rpc.Client.withCredentials )
        , ( "withRetry", Rpc.Client.withRetry policy )
        ]
    }


names : List String
names =
    List.map Tuple.first modifiers.protocol ++ List.map Tuple.first modifiers.client


{-| A client over `protocol` with every modifier whose name `keep` accepts.
-}
built : (String -> Bool) -> Protocol codec -> Rpc.Client codec
built keep protocol =
    let
        apply ( name, modify ) value =
            if keep name then
                modify value

            else
                value
    in
    Rpc.client (List.foldl apply protocol modifiers.protocol) url
        |> (\client -> List.foldl apply client modifiers.client)


every : Protocol codec -> Rpc.Client codec
every =
    built (always True)


{-| For each modifier, `every` over `protocol` but for it.
-}
allBut : Protocol codec -> List ( String, Rpc.Client codec )
allBut protocol =
    List.map (\name -> ( name, built ((/=) name) protocol )) names


{-| Clients over `protocol` differing from `every` over it in one modifier's
argument each.
-}
otherwise : Protocol codec -> List ( String, Rpc.Client codec )
otherwise protocol =
    let
        -- The protocol modifier is applied last, over every other one.
        protocolWith modify =
            Rpc.client (modify (Rpc.Client.protocol (every protocol))) url
                |> (\client -> List.foldl (\( _, modifyClient ) -> modifyClient) client modifiers.client)
    in
    [ ( "withMaxGetUrl", protocolWith (Rpc.Protocol.withMaxGetUrl 10) )
    , ( "withReadMaxBytes", protocolWith (Rpc.Protocol.withReadMaxBytes 10) )
    , ( "withWriteMaxBytes", protocolWith (Rpc.Protocol.withWriteMaxBytes 10) )
    , ( "withHeaders", every protocol |> Rpc.Client.withHeaders [ ( "X", "1" ) ] )
    , ( "withTimeout", every protocol |> Rpc.Client.withTimeout 10 )
    , ( "withRetry", every protocol |> Rpc.Client.withRetry (Rpc.Retry.on [ Rpc.Code.Aborted ]) )
    ]


base : Rpc.Client Rpc.Json
base =
    Rpc.client Rpc.Protocol.connect url


{-| Clients differing from `base` in one modifier each.
-}
variants : List ( String, Rpc.Client Rpc.Json )
variants =
    [ ( "protocol", Rpc.client Rpc.Protocol.transcode url )
    , ( "base URL", Rpc.client Rpc.Protocol.connect "https://other.example.com" )
    , ( "withConnectGet", Rpc.client (Rpc.Protocol.withConnectGet Rpc.Protocol.connect) url )
    , ( "withMaxGetUrl", Rpc.client (Rpc.Protocol.withMaxGetUrl 10 Rpc.Protocol.connect) url )
    , ( "withReadMaxBytes", Rpc.client (Rpc.Protocol.withReadMaxBytes 10 Rpc.Protocol.connect) url )
    , ( "withWriteMaxBytes", Rpc.client (Rpc.Protocol.withWriteMaxBytes 10 Rpc.Protocol.connect) url )
    , ( "withHeaders", base |> Rpc.Client.withHeaders [ ( "X", "1" ) ] )
    , ( "withTimeout", base |> Rpc.Client.withTimeout 10 )
    , ( "withCredentials", base |> Rpc.Client.withCredentials )
    , ( "withRetry", base |> Rpc.Client.withRetry (Rpc.Retry.on [ Rpc.Code.Unavailable ]) )
    ]


{-| Each named client compared with `to` both ways round, as names of the
ones that compare equal.
-}
equalTo : Rpc.Client codec -> List ( String, Rpc.Client codec ) -> List String
equalTo to clients =
    List.filterMap
        (\( name, other ) ->
            if other == to || to == other then
                Just name

            else
                Nothing
        )
        clients


suite : Test
suite =
    describe "Rpc.Client"
        [ equality
        , readers
        , problems
        , json
        ]


equality : Test
equality =
    describe "== on clients"
        [ test "two clients built alike with every modifier are ==, over each protocol" <|
            \_ ->
                [ every Rpc.Protocol.connect == every Rpc.Protocol.connect
                , every Rpc.Protocol.transcode == every Rpc.Protocol.transcode
                , every Rpc.Protocol.connectProto == every Rpc.Protocol.connectProto
                , every Rpc.Protocol.grpcWeb == every Rpc.Protocol.grpcWeb
                ]
                    |> Expect.equal [ True, True, True, True ]
        , test "a client is == to itself and to one built alike without modifiers" <|
            \_ ->
                ( base == base, base == Rpc.client Rpc.Protocol.connect url )
                    |> Expect.equal ( True, True )
        , test "clients differing from a bare client in one modifier compare unequal, without throwing" <|
            \_ ->
                equalTo base variants
                    |> Expect.equal []
        , test "over Connect, a client lacking any one modifier compares unequal to one with all, without throwing" <|
            \_ ->
                ( equalTo (every Rpc.Protocol.connect) (allBut Rpc.Protocol.connect)
                , equalTo (every Rpc.Protocol.connectProto) (allBut Rpc.Protocol.connectProto)
                )
                    |> Expect.equal ( [], [] )
        , test "over transcoding, only the Connect GET modifiers, which leave it as it was, compare equal" <|
            \_ ->
                equalTo (every Rpc.Protocol.transcode) (allBut Rpc.Protocol.transcode)
                    |> Expect.equal [ "withConnectGet", "withMaxGetUrl" ]
        , test "over gRPC-Web, only the Connect GET modifiers, which leave it as it was, compare equal" <|
            \_ ->
                equalTo (every Rpc.Protocol.grpcWeb) (allBut Rpc.Protocol.grpcWeb)
                    |> Expect.equal [ "withConnectGet", "withMaxGetUrl" ]
        , test "a gRPC-Web client compares unequal to a Connect proto one built alike, without throwing" <|
            \_ ->
                ( every Rpc.Protocol.grpcWeb == every Rpc.Protocol.connectProto
                , Rpc.client Rpc.Protocol.grpcWeb url == Rpc.client Rpc.Protocol.connectProto url
                )
                    |> Expect.equal ( False, False )
        , test "clients differing in one modifier's argument compare unequal, over each protocol" <|
            \_ ->
                [ equalTo (every Rpc.Protocol.connect) (otherwise Rpc.Protocol.connect)
                , equalTo (every Rpc.Protocol.transcode) (otherwise Rpc.Protocol.transcode)
                , equalTo (every Rpc.Protocol.connectProto) (otherwise Rpc.Protocol.connectProto)
                , equalTo (every Rpc.Protocol.grpcWeb) (otherwise Rpc.Protocol.grpcWeb)
                ]
                    |> Expect.equal [ [], [ "withMaxGetUrl" ], [], [ "withMaxGetUrl" ] ]
        , test "two retry policies built alike are ==, two that differ are not" <|
            \_ ->
                ( Rpc.Retry.on [ Rpc.Code.Unavailable ] == Rpc.Retry.on [ Rpc.Code.Unavailable ]
                , Rpc.Retry.on [ Rpc.Code.Unavailable ] == Rpc.Retry.on [ Rpc.Code.Aborted ]
                , policy == Rpc.Retry.withAttempts 6 policy
                )
                    |> Expect.equal ( True, False, False )
        ]


readers : Test
readers =
    describe "readers"
        [ test "a bare client reads back what built it, and no settings" <|
            \_ ->
                ( ( Rpc.Client.protocol base == Rpc.Protocol.connect, Rpc.Client.baseUrl base )
                , ( Rpc.Client.headers base, Rpc.Client.timeout base )
                , ( Rpc.Client.credentials base, Rpc.Client.retry base )
                )
                    |> Expect.equal ( ( True, url ), ( [], Nothing ), ( False, Nothing ) )
        , test "a client with every modifier reads each back" <|
            \_ ->
                let
                    client =
                        every Rpc.Protocol.connectProto
                in
                ( ( Rpc.Client.protocol client
                        == (Rpc.Protocol.connectProto
                                |> Rpc.Protocol.withConnectGet
                                |> Rpc.Protocol.withMaxGetUrl 2048
                                |> Rpc.Protocol.withReadMaxBytes 1000000
                                |> Rpc.Protocol.withWriteMaxBytes 100000
                           )
                  , Rpc.Client.baseUrl client
                  )
                , ( Rpc.Client.headers client, Rpc.Client.timeout client )
                , ( Rpc.Client.credentials client, Rpc.Client.retry client == Just policy )
                )
                    |> Expect.equal ( ( True, url ), ( [ ( "Authorization", "Bearer t" ) ], Just 5000 ), ( True, True ) )
        , test "headers added twice are kept in order" <|
            \_ ->
                base
                    |> Rpc.Client.withHeaders [ ( "A", "1" ) ]
                    |> Rpc.Client.withHeaders [ ( "B", "2" ) ]
                    |> Rpc.Client.headers
                    |> Expect.equal [ ( "A", "1" ), ( "B", "2" ) ]
        , test "a protocol's name and codec" <|
            \_ ->
                [ ( Rpc.Protocol.name Rpc.Protocol.connect, Rpc.Protocol.codec Rpc.Protocol.connect )
                , ( Rpc.Protocol.name Rpc.Protocol.connectProto, Rpc.Protocol.codec Rpc.Protocol.connectProto )
                , ( Rpc.Protocol.name Rpc.Protocol.transcode, Rpc.Protocol.codec Rpc.Protocol.transcode )
                , ( Rpc.Protocol.name Rpc.Protocol.grpcWeb, Rpc.Protocol.codec Rpc.Protocol.grpcWeb )
                ]
                    |> Expect.equal [ ( "connect", "json" ), ( "connect", "proto" ), ( "transcode", "json" ), ( "grpc-web", "proto" ) ]
        ]


problems : Test
problems =
    describe "problems"
        [ test "a client with every modifier, over each protocol, has none" <|
            \_ ->
                [ Rpc.Client.problems (every Rpc.Protocol.connect)
                , Rpc.Client.problems (every Rpc.Protocol.transcode)
                , Rpc.Client.problems (every Rpc.Protocol.connectProto)
                , Rpc.Client.problems (every Rpc.Protocol.grpcWeb)
                ]
                    |> Expect.equal [ [], [], [], [] ]
        , test "a binary client's limits below 1 are reported, one sentence each" <|
            \_ ->
                Rpc.client (Rpc.Protocol.connectProto |> Rpc.Protocol.withReadMaxBytes 0 |> Rpc.Protocol.withWriteMaxBytes -1) url
                    |> Rpc.Client.problems
                    |> List.map (\problem -> ( String.startsWith "readMaxBytes 0" problem, String.startsWith "writeMaxBytes -1" problem ))
                    |> Expect.equal [ ( True, False ), ( False, True ) ]
        , test "a bad base URL and header are reported together, in that order" <|
            \_ ->
                Rpc.client Rpc.Protocol.connectProto "https://api.example.com/?x=1"
                    |> Rpc.Client.withHeaders [ ( "Bad Name", "v" ) ]
                    |> Rpc.Client.problems
                    |> List.map (\problem -> ( String.startsWith "baseUrl" problem, String.startsWith "header" problem ))
                    |> Expect.equal [ ( True, False ), ( False, True ) ]
        ]


json : Test
json =
    describe "toJson"
        [ test "a client's data reads back, as JSON for logs" <|
            \_ ->
                Json.Encode.encode 0 (Rpc.Client.toJson (Rpc.client (Rpc.Protocol.withConnectGet Rpc.Protocol.connect) url |> Rpc.Client.withTimeout 5000))
                    |> Expect.equal """{"protocol":{"name":"connect","codec":"json","get":true,"maxGetUrl":null,"readMaxBytes":null,"writeMaxBytes":null},"baseUrl":"https://api.example.com","headers":[],"timeout":5000,"withCredentials":false,"retry":false}"""
        , test "a client with every modifier, over Connect proto" <|
            \_ ->
                Json.Encode.encode 0 (Rpc.Client.toJson (every Rpc.Protocol.connectProto))
                    |> Expect.equal """{"protocol":{"name":"connect","codec":"proto","get":true,"maxGetUrl":2048,"readMaxBytes":1000000,"writeMaxBytes":100000},"baseUrl":"https://api.example.com","headers":[["Authorization","Bearer t"]],"timeout":5000,"withCredentials":true,"retry":true}"""
        , test "the Connect GET options do not reach gRPC-Web" <|
            \_ ->
                Json.Encode.encode 0 (Rpc.Protocol.toJson (Rpc.Client.protocol (every Rpc.Protocol.grpcWeb)))
                    |> Expect.equal """{"name":"grpc-web","codec":"proto","get":false,"maxGetUrl":null,"readMaxBytes":1000000,"writeMaxBytes":100000}"""
        , test "the Connect GET options do not reach transcoding" <|
            \_ ->
                Json.Encode.encode 0 (Rpc.Protocol.toJson (Rpc.Client.protocol (every Rpc.Protocol.transcode)))
                    |> Expect.equal """{"name":"transcode","codec":"json","get":false,"maxGetUrl":null,"readMaxBytes":1000000,"writeMaxBytes":100000}"""
        ]
