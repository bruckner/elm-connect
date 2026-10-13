module Rpc.Code exposing
    ( Code(..)
    , toString, fromString
    , toInt, fromInt
    , fromHttpStatus
    )

{-| The status codes an RPC fails with, shared by both transports. Connect
writes them as strings (`"not_found"`), `google.rpc.Status` as gRPC's numbers
(`5`); both name the same sixteen codes.

@docs Code


# Connect's names

@docs toString, fromString


# gRPC's numbers

@docs toInt, fromInt


# HTTP status

@docs fromHttpStatus

-}


{-| Every error code. Success (gRPC's `OK`, `0`) is not an error, so it is not
here.
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


{-| The code as the Connect protocol writes it: `"canceled"`, `"not_found"`.
-}
toString : Code -> String
toString code =
    case code of
        Canceled ->
            "canceled"

        Unknown ->
            "unknown"

        InvalidArgument ->
            "invalid_argument"

        DeadlineExceeded ->
            "deadline_exceeded"

        NotFound ->
            "not_found"

        AlreadyExists ->
            "already_exists"

        PermissionDenied ->
            "permission_denied"

        ResourceExhausted ->
            "resource_exhausted"

        FailedPrecondition ->
            "failed_precondition"

        Aborted ->
            "aborted"

        OutOfRange ->
            "out_of_range"

        Unimplemented ->
            "unimplemented"

        Internal ->
            "internal"

        Unavailable ->
            "unavailable"

        DataLoss ->
            "data_loss"

        Unauthenticated ->
            "unauthenticated"


{-| The code a Connect name stands for, or `Nothing` for any other string.
-}
fromString : String -> Maybe Code
fromString name =
    case name of
        "canceled" ->
            Just Canceled

        "unknown" ->
            Just Unknown

        "invalid_argument" ->
            Just InvalidArgument

        "deadline_exceeded" ->
            Just DeadlineExceeded

        "not_found" ->
            Just NotFound

        "already_exists" ->
            Just AlreadyExists

        "permission_denied" ->
            Just PermissionDenied

        "resource_exhausted" ->
            Just ResourceExhausted

        "failed_precondition" ->
            Just FailedPrecondition

        "aborted" ->
            Just Aborted

        "out_of_range" ->
            Just OutOfRange

        "unimplemented" ->
            Just Unimplemented

        "internal" ->
            Just Internal

        "unavailable" ->
            Just Unavailable

        "data_loss" ->
            Just DataLoss

        "unauthenticated" ->
            Just Unauthenticated

        _ ->
            Nothing


{-| The code's gRPC number, `1` (`Canceled`) to `16` (`Unauthenticated`).
-}
toInt : Code -> Int
toInt code =
    case code of
        Canceled ->
            1

        Unknown ->
            2

        InvalidArgument ->
            3

        DeadlineExceeded ->
            4

        NotFound ->
            5

        AlreadyExists ->
            6

        PermissionDenied ->
            7

        ResourceExhausted ->
            8

        FailedPrecondition ->
            9

        Aborted ->
            10

        OutOfRange ->
            11

        Unimplemented ->
            12

        Internal ->
            13

        Unavailable ->
            14

        DataLoss ->
            15

        Unauthenticated ->
            16


{-| The code a gRPC number stands for, or `Nothing` for `0` (`OK`) and any
number outside `1` to `16`.
-}
fromInt : Int -> Maybe Code
fromInt number =
    case number of
        1 ->
            Just Canceled

        2 ->
            Just Unknown

        3 ->
            Just InvalidArgument

        4 ->
            Just DeadlineExceeded

        5 ->
            Just NotFound

        6 ->
            Just AlreadyExists

        7 ->
            Just PermissionDenied

        8 ->
            Just ResourceExhausted

        9 ->
            Just FailedPrecondition

        10 ->
            Just Aborted

        11 ->
            Just OutOfRange

        12 ->
            Just Unimplemented

        13 ->
            Just Internal

        14 ->
            Just Unavailable

        15 ->
            Just DataLoss

        16 ->
            Just Unauthenticated

        _ ->
            Nothing


{-| The code a failed HTTP response stands for when it carries none of its own,
by the table the Connect protocol and gRPC's HTTP mapping share: 400 is
`Internal`, 401 `Unauthenticated`, 403 `PermissionDenied`, 404 `Unimplemented`,
429, 502, 503 and 504 `Unavailable`, and every other status `Unknown`.
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
