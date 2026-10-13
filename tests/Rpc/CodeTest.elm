module Rpc.CodeTest exposing (suite)

import Expect
import Rpc.Code as Code exposing (Code(..))
import Test exposing (Test, describe, test)


all : List ( Code, String, Int )
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
        [ describe "every code"
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
        , test "OK and unknown numbers are no code" <|
            \_ ->
                List.map Code.fromInt [ 0, 17, -1 ]
                    |> Expect.equal [ Nothing, Nothing, Nothing ]
        , test "unknown names are no code" <|
            \_ ->
                List.map Code.fromString [ "NOT_FOUND", "notFound", "", "ok" ]
                    |> Expect.equal [ Nothing, Nothing, Nothing, Nothing ]
        , test "the HTTP status table" <|
            \_ ->
                List.map Code.fromHttpStatus [ 400, 401, 403, 404, 429, 502, 503, 504, 500, 409, 418, 302 ]
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
                        ]
        ]
