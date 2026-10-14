module Rpc.Code exposing
    ( Code(..)
    , toString, fromString
    , toInt, fromInt
    , toHttpStatus, fromHttpStatus
    )

{-| The status an RPC ends with, shared by both transports: `ok`, or one of
the sixteen [error codes](Rpc-ErrorCode).

@docs Code


# Connect's names

@docs toString, fromString


# gRPC's numbers

@docs toInt, fromInt


# HTTP status

@docs toHttpStatus, fromHttpStatus

-}

import Rpc.ErrorCode as ErrorCode exposing (ErrorCode)


{-| How an RPC ended: `Ok`, or failed with an error code.

An [`Rpc.Rpc`](Rpc#Error) error carries an [`ErrorCode`](Rpc-ErrorCode#ErrorCode),
so it cannot claim `Ok`; the runtime never produces one for a call that
succeeded, and reads a failed answer whose body claims `ok` (or `0`) as
`Unknown`. `Code` is for what reports either outcome, such as a
[`Trace`](Rpc#Trace).

`Ok` shares its name with `Result`'s, which every module imports, so refer to
it qualified (`Rpc.Code.Ok`) rather than exposing `Code(..)`.

-}
type Code
    = Ok
    | Failed ErrorCode


{-| The code as the Connect protocol writes it: `"ok"`, or the error code's
name.
-}
toString : Code -> String
toString code =
    case code of
        Ok ->
            "ok"

        Failed errorCode ->
            ErrorCode.toString errorCode


{-| The code a Connect name stands for, `"ok"` included, or `Nothing` for any
other string.
-}
fromString : String -> Maybe Code
fromString name =
    if name == "ok" then
        Just Ok

    else
        Maybe.map Failed (ErrorCode.fromString name)


{-| The code's gRPC number, `0` for `Ok`.
-}
toInt : Code -> Int
toInt code =
    case code of
        Ok ->
            0

        Failed errorCode ->
            ErrorCode.toInt errorCode


{-| The code a gRPC number stands for, `0` to `16`, or `Nothing` for any other
number.
-}
fromInt : Int -> Maybe Code
fromInt number =
    if number == 0 then
        Just Ok

    else
        Maybe.map Failed (ErrorCode.fromInt number)


{-| The HTTP status a Connect server sends with the code: 200 for `Ok`, and
[`ErrorCode.toHttpStatus`](Rpc-ErrorCode#toHttpStatus) for an error code.
-}
toHttpStatus : Code -> Int
toHttpStatus code =
    case code of
        Ok ->
            200

        Failed errorCode ->
            ErrorCode.toHttpStatus errorCode


{-| The code an HTTP response stands for when it carries none of its own: `Ok`
for any 2xx, and [`ErrorCode.fromHttpStatus`](Rpc-ErrorCode#fromHttpStatus)
for any other status.
-}
fromHttpStatus : Int -> Code
fromHttpStatus status =
    if status >= 200 && status < 300 then
        Ok

    else
        Failed (ErrorCode.fromHttpStatus status)
