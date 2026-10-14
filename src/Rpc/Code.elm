module Rpc.Code exposing
    ( Code(..), ErrorCode(..)
    , toString, fromString
    , toInt, fromInt
    , toHttpStatus, fromHttpStatus
    , codeToString, codeFromString, codeToInt, codeFromInt, codeToHttpStatus, codeFromHttpStatus
    )

{-| The status codes an RPC ends with, shared by both transports. Connect
writes them as strings (`"not_found"`), `google.rpc.Status` as gRPC's numbers
(`5`); both name the same seventeen: `ok` and sixteen error codes.

@docs Code, ErrorCode


# Connect's names

@docs toString, fromString


# gRPC's numbers

@docs toInt, fromInt


# HTTP status

@docs toHttpStatus, fromHttpStatus


# Any code, `Ok` included

@docs codeToString, codeFromString, codeToInt, codeFromInt, codeToHttpStatus, codeFromHttpStatus

-}


{-| How an RPC ended: `Ok`, or failed with an error code.

An [`Rpc.Rpc`](Rpc#Error) error carries an [`ErrorCode`](#ErrorCode), so it
cannot claim `Ok`; the runtime never produces one for a call that succeeded,
and reads a failed answer whose body claims `ok` (or `0`) as `Unknown`. `Code`
is for what reports either outcome, such as a [`Trace`](Rpc#Trace).

`Ok` shares its name with `Result`'s, which every module imports, so refer to
it qualified (`Rpc.Code.Ok`) rather than exposing `Code(..)`.

-}
type Code
    = Ok
    | Failed ErrorCode


{-| Every error code: gRPC's `1` to `16`.
-}
type ErrorCode
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
toString : ErrorCode -> String
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


{-| The error code a Connect name stands for, or `Nothing` for any other
string, `"ok"` included.
-}
fromString : String -> Maybe ErrorCode
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
toInt : ErrorCode -> Int
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


{-| The error code a gRPC number stands for, or `Nothing` for `0` (`OK`) and
any number outside `1` to `16`.
-}
fromInt : Int -> Maybe ErrorCode
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

It is not the inverse of [`toHttpStatus`](#toHttpStatus), which says why.

-}
fromHttpStatus : Int -> ErrorCode
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
toHttpStatus : ErrorCode -> Int
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


{-| The code as the Connect protocol writes it: `"ok"`, or the error code's
name.
-}
codeToString : Code -> String
codeToString code =
    case code of
        Ok ->
            "ok"

        Failed errorCode ->
            toString errorCode


{-| The code a Connect name stands for, `"ok"` included, or `Nothing` for any
other string.
-}
codeFromString : String -> Maybe Code
codeFromString name =
    if name == "ok" then
        Just Ok

    else
        Maybe.map Failed (fromString name)


{-| The code's gRPC number, `0` for `Ok`.
-}
codeToInt : Code -> Int
codeToInt code =
    case code of
        Ok ->
            0

        Failed errorCode ->
            toInt errorCode


{-| The code a gRPC number stands for, `0` to `16`, or `Nothing` for any other
number.
-}
codeFromInt : Int -> Maybe Code
codeFromInt number =
    if number == 0 then
        Just Ok

    else
        Maybe.map Failed (fromInt number)


{-| The HTTP status a Connect server sends with the code: 200 for `Ok`, and
[`toHttpStatus`](#toHttpStatus) for an error code.
-}
codeToHttpStatus : Code -> Int
codeToHttpStatus code =
    case code of
        Ok ->
            200

        Failed errorCode ->
            toHttpStatus errorCode


{-| The code an HTTP response stands for when it carries none of its own: `Ok`
for any 2xx, and [`fromHttpStatus`](#fromHttpStatus) for any other status.
-}
codeFromHttpStatus : Int -> Code
codeFromHttpStatus status =
    if status >= 200 && status < 300 then
        Ok

    else
        Failed (fromHttpStatus status)
