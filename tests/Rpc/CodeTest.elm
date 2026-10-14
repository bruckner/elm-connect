module Rpc.CodeTest exposing (suite)

import Expect
import Rpc.Code as Code
import Rpc.ErrorCode exposing (ErrorCode(..))
import Test exposing (Test, describe, test)


all : List ( Code.Code, String, Int )
all =
    [ ( Code.Ok, "ok", 0 )
    , ( Code.Failed Canceled, "canceled", 1 )
    , ( Code.Failed NotFound, "not_found", 5 )
    , ( Code.Failed Unauthenticated, "unauthenticated", 16 )
    ]


suite : Test
suite =
    describe "Rpc.Code"
        [ describe "codes"
            (List.map
                (\( code, text, number ) ->
                    test text <|
                        \_ ->
                            Expect.equal
                                ( ( Code.toString code, Code.fromString text ), ( Code.toInt code, Code.fromInt number ) )
                                ( ( text, Just code ), ( number, Just code ) )
                )
                all
            )
        , test "unknown numbers are no code" <|
            \_ ->
                List.map Code.fromInt [ 17, -1 ]
                    |> Expect.equal [ Nothing, Nothing ]
        , test "unknown names are no code" <|
            \_ ->
                List.map Code.fromString [ "OK", "NOT_FOUND", "" ]
                    |> Expect.equal [ Nothing, Nothing, Nothing ]
        , test "the status of any code" <|
            \_ ->
                List.map Code.toHttpStatus [ Code.Ok, Code.Failed NotFound ]
                    |> Expect.equal [ 200, 404 ]
        , test "any 2xx is ok" <|
            \_ ->
                List.map Code.fromHttpStatus [ 200, 201, 204, 299, 199, 300, 404 ]
                    |> Expect.equal
                        [ Code.Ok
                        , Code.Ok
                        , Code.Ok
                        , Code.Ok
                        , Code.Failed Unknown
                        , Code.Failed Unknown
                        , Code.Failed Unimplemented
                        ]
        ]
