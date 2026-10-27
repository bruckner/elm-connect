module Shim exposing
    ( Config
    , checkConfig
    , client
    , config
    , descriptor
    , method
    , refused
    , request
    , response
    , responseBytes
    , send
    , task
    , taskFromRequest
    , taskTraced
    , withBudget
    )

{-| The tests' former config record over the new client, so that a test
can still build its settings with record syntax and send through `Rpc`:
`Shim.request cfg call` is `Rpc.request (Shim.client cfg) call`. A method
from a descriptor written as data (`Shim.method`) is the JSON method with
the descriptor's endpoint and its bindings read by the interpreter.
-}

import Json.Decode
import Json.Encode
import Proto.Http
import Proto.Method exposing (Descriptor, Idempotency)
import Rpc
import Rpc.Client
import Rpc.Error
import Rpc.Internal.Send
import Rpc.Protocol exposing (Protocol)
import Rpc.Retry exposing (Retry)
import Task exposing (Task)


type alias Config codec =
    { transport : Protocol codec
    , baseUrl : String
    , headers : List ( String, String )
    , timeout : Maybe Float
    , withCredentials : Bool
    , retry : Maybe Retry
    }


config : String -> Config Rpc.Json
config url =
    { transport = Rpc.Protocol.connect
    , baseUrl = url
    , headers = []
    , timeout = Nothing
    , withCredentials = False
    , retry = Nothing
    }


client : Config codec -> Rpc.Client codec
client cfg =
    let
        withTimeout cl =
            case cfg.timeout of
                Just ms ->
                    Rpc.Client.withTimeout ms cl

                Nothing ->
                    cl

        withCredentials cl =
            if cfg.withCredentials then
                Rpc.Client.withCredentials cl

            else
                cl

        withRetry cl =
            case cfg.retry of
                Just policy ->
                    Rpc.Client.withRetry policy cl

                Nothing ->
                    cl
    in
    Rpc.client cfg.transport cfg.baseUrl
        |> Rpc.Client.withHeaders cfg.headers
        |> withTimeout
        |> withCredentials
        |> withRetry


request : Config codec -> Rpc.Call codec req res -> Rpc.Request
request cfg =
    Rpc.request (client cfg)


response cfg =
    Rpc.response (client cfg)


responseBytes cfg =
    Rpc.responseBytes (client cfg)


task : Config codec -> Rpc.Call codec req res -> Task Rpc.Error res
task cfg =
    Rpc.task (client cfg)


send cfg =
    Rpc.send (client cfg)


taskTraced cfg =
    Rpc.taskTraced (client cfg)


taskFromRequest cfg =
    Rpc.taskFromRequest (client cfg)


checkConfig : Config codec -> List String
checkConfig cfg =
    Rpc.Client.problems (client cfg)


method : (req -> Json.Encode.Value) -> Json.Decode.Decoder res -> Descriptor -> Proto.Method.Method Rpc.Json req res
method encode decoder d =
    Proto.Method.json encode decoder (Proto.Method.toEndpoint d)
        |> Proto.Method.withBindings (Proto.Method.bindings d)


descriptor : String -> String -> Idempotency -> String -> String -> List Proto.Http.Binding -> Descriptor
descriptor service name idempotency input output bindings =
    Proto.Method.descriptor (Proto.Method.endpoint service name idempotency) input output bindings


{-| A request with what is left of a retry deadline, as an attempt sends it.
-}
withBudget : Config codec -> Rpc.Call codec req res -> Maybe Float -> Rpc.Request -> Rpc.Request
withBudget cfg c =
    Rpc.Internal.Send.withBudget (Rpc.Internal.Send.plan (client cfg) c)


{-| Why sending a call would refuse it before it reaches elm/http.
-}
refused : Config codec -> Rpc.Call codec req res -> Maybe Rpc.Error.Error
refused cfg c =
    let
        plan =
            Rpc.Internal.Send.plan (client cfg) c
    in
    Rpc.Internal.Send.refused cfg.baseUrl plan (plan.request ())
