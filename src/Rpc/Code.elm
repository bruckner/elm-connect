module Rpc.Code exposing
    ( Code(..)
    , toString, fromString
    , toInt, fromInt
    , toHttpStatus, fromHttpStatus
    )

{-| The codes an RPC fails with, shared by both protocols. Connect writes them
as strings (`"not_found"`), `google.rpc.Status` as gRPC's numbers (`5`). Every
[`Rpc.Error`](Rpc-Error#Error) has one ([`Rpc.Error.code`](Rpc-Error#code)). Success has no code:
the `Result` a call ends with already says whether it succeeded.

@docs Code


# Connect's names

@docs toString, fromString


# gRPC's numbers

@docs toInt, fromInt


# HTTP status

@docs toHttpStatus, fromHttpStatus

-}


{-| Every error code: gRPC's `1` to `16`.
-}
type Code
    = Canceled
    | Unknown
    | InvalidArgument
    | DeadlineExceeded
    | NotFound
    | AlreadyExists
    | PermissionDenied
    | ResourceExhausted
    | FailedPrecondition
    | Aborted
    | OutOfRange
    | Unimplemented
    | Internal
    | Unavailable
    | DataLoss
    | Unauthenticated


{-| Every code in gRPC's order, `1` to `16`, with its Connect name: the one
table the conversions to and from names and numbers read.
-}
codes : List ( Code, String )
codes =
    [ ( Canceled, "canceled" )
    , ( Unknown, "unknown" )
    , ( InvalidArgument, "invalid_argument" )
    , ( DeadlineExceeded, "deadline_exceeded" )
    , ( NotFound, "not_found" )
    , ( AlreadyExists, "already_exists" )
    , ( PermissionDenied, "permission_denied" )
    , ( ResourceExhausted, "resource_exhausted" )
    , ( FailedPrecondition, "failed_precondition" )
    , ( Aborted, "aborted" )
    , ( OutOfRange, "out_of_range" )
    , ( Unimplemented, "unimplemented" )
    , ( Internal, "internal" )
    , ( Unavailable, "unavailable" )
    , ( DataLoss, "data_loss" )
    , ( Unauthenticated, "unauthenticated" )
    ]


{-| The first entry of `codes` that `match` accepts, and its gRPC number.
-}
find : (( Code, String ) -> Bool) -> Maybe ( Int, ( Code, String ) )
find match =
    findFrom 1 match codes


findFrom : Int -> (( Code, String ) -> Bool) -> List ( Code, String ) -> Maybe ( Int, ( Code, String ) )
findFrom number match entries =
    case entries of
        entry :: rest ->
            if match entry then
                Just ( number, entry )

            else
                findFrom (number + 1) match rest

        [] ->
            Nothing


{-| The code as the Connect protocol writes it: `"canceled"`, `"not_found"`.
-}
toString : Code -> String
toString code =
    case find (\( c, _ ) -> c == code) of
        Just ( _, ( _, name ) ) ->
            name

        Nothing ->
            -- Not reached: every code is in the table.
            "unknown"


{-| The error code a Connect name stands for, or `Nothing` for any other
string, `"ok"` included.
-}
fromString : String -> Maybe Code
fromString name =
    find (\( _, n ) -> n == name) |> Maybe.map (\( _, ( code, _ ) ) -> code)


{-| The code's gRPC number, `1` (`Canceled`) to `16` (`Unauthenticated`).
-}
toInt : Code -> Int
toInt code =
    case find (\( c, _ ) -> c == code) of
        Just ( number, _ ) ->
            number

        Nothing ->
            -- Not reached: every code is in the table.
            2


{-| The error code a gRPC number stands for, or `Nothing` for `0` (`OK`) and
any number outside `1` to `16`.
-}
fromInt : Int -> Maybe Code
fromInt number =
    if number < 1 then
        Nothing

    else
        List.head (List.drop (number - 1) codes) |> Maybe.map Tuple.first


{-| The code a failed HTTP response stands for when it carries none of its own,
by the table the Connect protocol and gRPC's HTTP mapping share: 400 is
`Internal`, 401 `Unauthenticated`, 403 `PermissionDenied`, 404 `Unimplemented`,
429, 502, 503 and 504 `Unavailable`, and every other status `Unknown`.

A 200 reaches it only for a success that is not the protocol's answer, such as
a proxy's HTML page in place of a Connect or gRPC-Web answer, and reads as
`Unknown`.

It is not the inverse of [`toHttpStatus`](#toHttpStatus), which says why.
A REST server's bare 404 thus reads as `Unimplemented`; see
[`Rpc.Error.code`](Rpc-Error#code).

-}
fromHttpStatus : Int -> Code
fromHttpStatus status =
    case status of
        400 ->
            Internal

        401 ->
            Unauthenticated

        403 ->
            PermissionDenied

        404 ->
            Unimplemented

        429 ->
            Unavailable

        502 ->
            Unavailable

        503 ->
            Unavailable

        504 ->
            Unavailable

        _ ->
            Unknown


{-| The HTTP status a Connect server sends with an error code, by the
[Connect protocol's table](https://connectrpc.com/docs/protocol/#error-codes),
which is `google/rpc/code.proto`'s HTTP mapping: `Canceled` 499, `Unknown`
500, `InvalidArgument` 400, `DeadlineExceeded` 504, `NotFound` 404,
`AlreadyExists` 409, `PermissionDenied` 403, `ResourceExhausted` 429,
`FailedPrecondition` 400, `Aborted` 409, `OutOfRange` 400, `Unimplemented` 501,
`Internal` 500, `Unavailable` 503, `DataLoss` 500, `Unauthenticated` 401.

It is not the inverse of [`fromHttpStatus`](#fromHttpStatus), which reads 400
as `Internal`: that table is
[gRPC's mapping](https://github.com/grpc/grpc/blob/master/doc/http-grpc-status-mapping.md)
for a response with no error body, where a 400 means a proxy or the transport
rejected the request, not the request's argument.

-}
toHttpStatus : Code -> Int
toHttpStatus code =
    case code of
        Canceled ->
            499

        Unknown ->
            500

        InvalidArgument ->
            400

        DeadlineExceeded ->
            504

        NotFound ->
            404

        AlreadyExists ->
            409

        PermissionDenied ->
            403

        ResourceExhausted ->
            429

        FailedPrecondition ->
            400

        Aborted ->
            409

        OutOfRange ->
            400

        Unimplemented ->
            501

        Internal ->
            500

        Unavailable ->
            503

        DataLoss ->
            500

        Unauthenticated ->
            401
