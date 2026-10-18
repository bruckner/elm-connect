module Rpc.Request exposing (Request)

{-| An HTTP request as data. [`Rpc.request`](Rpc#request) builds the one a
call stands for, without sending anything, so you can check what a call
sends or change it; [`Rpc.taskFromRequest`](Rpc#taskFromRequest) sends one
and reads the answer as the call's.
[`Rpc.Trace.request`](Rpc-Trace#request) gives the request a traced send sent.

    Rpc.request config call
        |> (\req -> { req | headers = ( "x-debug", "1" ) :: req.headers })
        |> Rpc.taskFromRequest config call

@docs Request

-}

import Rpc.Body exposing (Body)


{-| An HTTP request, ready to send.

elm/http has no request value of its own: `Http.request` takes a record with
opaque headers and body and an `expect`. `Request` is the data form of that
record without `expect` and `tracker`: headers as pairs, the body an
[`Rpc.Body`](Rpc-Body) holding the JSON text, and `withCredentials` deciding
whether the runtime calls `Http.request` or `Http.riskyRequest`.

A body is sent as `application/json`, and `timeout` is in milliseconds. The
record's fields are fixed; a body of another kind would be another `Body`.

-}
type alias Request =
    { method : String
    , url : String
    , headers : List ( String, String )
    , body : Body
    , timeout : Maybe Float
    , withCredentials : Bool
    }
