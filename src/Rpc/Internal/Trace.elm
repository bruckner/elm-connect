module Rpc.Internal.Trace exposing (Trace(..), init)

{-| What happened when a call was sent. Not exposed. Two public modules need
the constructor: `Rpc` builds a trace (through `init`), `Rpc.Trace` reads it
and aliases the type, so users cannot make one and a field can be added
without breaking code that reads one.
-}

import Dict exposing (Dict)
import Proto.Internal.Method
import Rpc.Body
import Rpc.Call
import Rpc.Code exposing (Code)
import Rpc.Error as Error exposing (Error)
import Rpc.Internal.Call exposing (Call(..))
import Rpc.Internal.Http as Internal
import Rpc.Internal.Retry exposing (Outcome)
import Rpc.Internal.Route as Route
import Rpc.Internal.Transport as Transport exposing (Transport)
import Rpc.Request exposing (Request)
import Rpc.Transport


{-| A trace; `Rpc.Trace`'s accessors say what each field holds.
-}
type Trace
    = Trace
        { serviceName : String
        , methodName : String
        , transport : String
        , binding : Maybe Int
        , request : Request
        , requestBase64 : Maybe String
        , httpStatus : Maybe Int
        , headers : Dict String String
        , trailers : Dict String String
        , code : Maybe Code
        , duration : Float
        , attempts : Int
        }


{-| The trace of a call sent over `transport` as `sent`, from what sending
came to and how long it took, in milliseconds.
-}
init : Transport -> Call req res -> Request -> Outcome Error res -> Float -> Trace
init transport ((Call fields) as c) sent outcome duration =
    let
        metadata =
            outcome.metadata
                |> Maybe.map (.headers >> Internal.splitTrailers)
                |> Maybe.withDefault { headers = Dict.empty, trailers = Dict.empty }
    in
    Trace
        { serviceName = Rpc.Call.serviceName c
        , methodName = Rpc.Call.methodName c
        , transport = Rpc.Transport.name transport
        , binding =
            case Route.route transport c of
                Route.Bound index _ ->
                    Just index

                _ ->
                    Nothing
        , request = sent
        , requestBase64 =
            -- Written by the method's bytes path, so that a program without
            -- binary codecs carries no base64 encoder.
            Maybe.map2 (\binary bytes -> binary.base64 bytes)
                (Proto.Internal.Method.binaryUnder (Transport.proto transport) fields.method)
                (Rpc.Body.toBytes sent.body)
        , httpStatus = Maybe.map .statusCode outcome.metadata
        , headers = metadata.headers
        , trailers = metadata.trailers
        , code =
            case outcome.result of
                Ok _ ->
                    Nothing

                Err error ->
                    Just (Error.code error)
        , duration = duration
        , attempts = outcome.attempts
        }
