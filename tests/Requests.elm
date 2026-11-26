module Requests exposing (builtOf, refusalOf, requestOf)

{-| A call's request for the tests that read one: [`Rpc.request`](Rpc#request)
of a call it does not refuse, or the error it refuses the call with; or the
request the call's plan builds before the checks that refuse a call, for the
tests of how a path value its template cannot match, or a header a request
cannot carry, is printed.
-}

import Rpc
import Rpc.Body
import Rpc.Error
import Rpc.Internal.Plan


{-| The request `Rpc.request` gives, or for a refused call a request whose
method names the error, so that an expectation on the request fails saying
why.
-}
requestOf : Rpc.Client codec -> Rpc.Call codec req res -> Rpc.Request
requestOf client call =
    case Rpc.request client call of
        Ok sent ->
            sent

        Err error ->
            refused (Rpc.Error.toString error)


{-| The request the call's plan builds, whatever its path values and headers
hold, or for a request with no proto3 JSON, which has none, a request whose
method says so.
-}
builtOf : Rpc.Client codec -> Rpc.Call codec req res -> Rpc.Request
builtOf client call =
    case (Rpc.Internal.Plan.toSend client call).request () of
        Ok sent ->
            sent

        Err _ ->
            refused "no JSON"


refused : String -> Rpc.Request
refused why =
    { method = "refused: " ++ why
    , url = ""
    , headers = []
    , body = Rpc.Body.none
    , timeout = Nothing
    , withCredentials = False
    }


{-| The error `Rpc.request` refuses a call with, or `Nothing`.
-}
refusalOf : Rpc.Client codec -> Rpc.Call codec req res -> Maybe Rpc.Error
refusalOf client call =
    case Rpc.request client call of
        Ok _ ->
            Nothing

        Err error ->
            Just error
