module Rpc.Internal.Trace exposing (Trace(..), init)

{-| What happened when a call was sent. Not exposed. Two public modules need
the constructor: `Rpc` builds a trace (through `init`), `Rpc.Trace` reads it
and aliases the type, so users cannot make one and a field can be added
without breaking code that reads one.
-}

import Dict exposing (Dict)
import Proto.Error
import Rpc.Body
import Rpc.Call
import Rpc.Code exposing (Code)
import Rpc.Error as Error exposing (Error)
import Rpc.Internal.Call exposing (Call)
import Rpc.Internal.Http as Internal
import Rpc.Internal.Plan exposing (Plan)
import Rpc.Internal.Protocol exposing (Protocol(..))
import Rpc.Internal.Retry exposing (Outcome)
import Rpc.Request exposing (Request)


{-| A trace; `Rpc.Trace`'s accessors say what each field holds.
-}
type Trace
    = Trace
        { serviceName : String
        , methodName : String
        , protocol : String
        , codec : String
        , binding : Maybe Int
        , request : Request
        , requestBase64 : Maybe String
        , httpStatus : Maybe Int
        , headers : Dict String String
        , trailers : Dict String String
        , code : Maybe Code
        , detailProblems : List String
        , duration : Float
        , attempts : Int
        }


{-| The trace of a call sent over `protocol` by `plan` as `sent`, from what
sending came to and how long it took, in milliseconds.
-}
init : Protocol codec -> Call codec req res -> Plan res -> Request -> Outcome Error res -> Float -> Trace
init (Protocol p) c plan sent outcome duration =
    let
        metadata =
            outcome.metadata
                |> Maybe.map (.headers >> Internal.splitTrailers)
                |> Maybe.withDefault { headers = Dict.empty, trailers = Dict.empty }
    in
    Trace
        { serviceName = Rpc.Call.serviceName c
        , methodName = Rpc.Call.methodName c
        , protocol = p.name
        , codec = p.codec
        , binding = plan.binding
        , request = sent
        , requestBase64 = Maybe.map2 (\base64 bytes -> base64 bytes) plan.base64 (Rpc.Body.toBytes sent.body)
        , httpStatus = Maybe.map .statusCode outcome.metadata
        , headers = metadata.headers
        , trailers = metadata.trailers
        , code =
            case outcome.result of
                Ok _ ->
                    Nothing

                Err error ->
                    Just (Error.code error)
        , detailProblems =
            case outcome.result of
                Err (Error.RpcStatus status _) ->
                    List.filterMap detailProblem status.details

                _ ->
                    []
        , duration = duration
        , attempts = outcome.attempts
        }


{-| A detail's problem as a log line names it, or `Nothing` for a detail
that was read.
-}
detailProblem : Result Proto.Error.Error a -> Maybe String
detailProblem detail =
    case detail of
        Ok _ ->
            Nothing

        Err problem ->
            Just (Proto.Error.toString problem)
