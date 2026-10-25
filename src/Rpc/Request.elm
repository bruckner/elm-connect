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


{-| An HTTP request, ready to send: the record `Http.request` takes, as data,
without `expect` and `tracker`.

  - `method`: the HTTP method, such as `"POST"`.
  - `url`: the whole URL, query included.
  - `headers`: name and value pairs, in the order they are sent.
  - `body`: an [`Rpc.Body`](Rpc-Body), the request's JSON text, sent as
    `application/json`, its protobuf binary, sent as `application/proto`, or
    none.
  - `timeout`: milliseconds, or `Nothing` for none.
  - `withCredentials`: `True` sends cookies and other credentials
    cross-origin (`Http.riskyRequest`).

The record's fields are fixed.

-}
type alias Request =
    { method : String
    , url : String
    , headers : List ( String, String )
    , body : Body
    , timeout : Maybe Float
    , withCredentials : Bool
    }
