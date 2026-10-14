module Rpc.CodeTest exposing (suite)

import Expect
import Rpc.Code as Code exposing (ErrorCode(..))
import Test exposing (Test, describe, test)


all : List ( ErrorCode, String, Int )
all =
    [ ( Canceled, "canceled", 1 )
    , ( Unknown, "unknown", 2 )
    , ( InvalidArgument, "invalid_argument", 3 )
    , ( DeadlineExceeded, "deadline_exceeded", 4 )
    , ( NotFound, "not_found", 5 )
    , ( AlreadyExists, "already_exists", 6 )
    , ( PermissionDenied, "permission_denied", 7 )
    , ( ResourceExhausted, "resource_exhausted", 8 )
    , ( FailedPrecondition, "failed_precondition", 9 )
    , ( Aborted, "aborted", 10 )
    , ( OutOfRange, "out_of_range", 11 )
    , ( Unimplemented, "unimplemented", 12 )
    , ( Internal, "internal", 13 )
    , ( Unavailable, "unavailable", 14 )
    , ( DataLoss, "data_loss", 15 )
    , ( Unauthenticated, "unauthenticated", 16 )
    ]


suite : Test
suite =
    describe "Rpc.Code"
        [ describe "every error code"
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
        , describe "every code"
            (List.map
                (\( code, text, number ) ->
                    test text <|
                        \_ ->
                            Expect.equal
                                ( ( Code.codeToString code, Code.codeFromString text ), ( Code.codeToInt code, Code.codeFromInt number ) )
                                ( ( text, Just code ), ( number, Just code ) )
                )
                (( Code.Ok, "ok", 0 ) :: List.map (\( code, text, number ) -> ( Code.Failed code, text, number )) all)
            )
        , test "OK and unknown numbers are no error code" <|
            \_ ->
                List.map Code.fromInt [ 0, 17, -1 ]
                    |> Expect.equal [ Nothing, Nothing, Nothing ]
        , test "unknown numbers are no code" <|
            \_ ->
                List.map Code.codeFromInt [ 17, -1 ]
                    |> Expect.equal [ Nothing, Nothing ]
        , test "ok and unknown names are no error code" <|
            \_ ->
                List.map Code.fromString [ "NOT_FOUND", "notFound", "", "ok" ]
                    |> Expect.equal [ Nothing, Nothing, Nothing, Nothing ]
        , test "unknown names are no code" <|
            \_ ->
                List.map Code.codeFromString [ "OK", "NOT_FOUND", "" ]
                    |> Expect.equal [ Nothing, Nothing, Nothing ]
        , test "the status a Connect server sends" <|
            \_ ->
                List.map (\( code, _, _ ) -> Code.toHttpStatus code) all
                    |> Expect.equal [ 499, 500, 400, 504, 404, 409, 403, 429, 400, 409, 400, 501, 500, 503, 500, 401 ]
        , test "the status of any code" <|
            \_ ->
                List.map Code.codeToHttpStatus [ Code.Ok, Code.Failed NotFound ]
                    |> Expect.equal [ 200, 404 ]
        , test "the HTTP status table" <|
            \_ ->
                List.map Code.fromHttpStatus [ 400, 401, 403, 404, 429, 502, 503, 504, 500, 409, 418, 302, 200 ]
                    |> Expect.equal
                        [ Internal
                        , Unauthenticated
                        , PermissionDenied
                        , Unimplemented
                        , Unavailable
                        , Unavailable
                        , Unavailable
                        , Unavailable
                        , Unknown
                        , Unknown
                        , Unknown
                        , Unknown
                        , Unknown
                        ]
        , test "any 2xx is ok" <|
            \_ ->
                List.map Code.codeFromHttpStatus [ 200, 201, 204, 299, 199, 300, 404 ]
                    |> Expect.equal
                        [ Code.Ok
                        , Code.Ok
                        , Code.Ok
                        , Code.Ok
                        , Code.Failed Unknown
                        , Code.Failed Unknown
                        , Code.Failed Unimplemented
                        ]
        , test "toHttpStatus is not the inverse of fromHttpStatus" <|
            \_ ->
                Code.fromHttpStatus (Code.toHttpStatus InvalidArgument)
                    |> Expect.equal Internal
        ]
