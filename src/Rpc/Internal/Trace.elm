module Rpc.Internal.Trace exposing (Trace(..))

{-| What happened when a call was sent. Not exposed; `Rpc.Trace.Trace` is this
type, its constructor private so that `Rpc` alone makes one and a field can be
added without breaking code that reads one.
-}

import Dict exposing (Dict)
import Rpc.Code exposing (Code)
import Rpc.Internal.Http exposing (Request)


{-| A trace; `Rpc.Trace`'s accessors say what each field holds.
-}
type Trace
    = Trace
        { serviceName : String
        , methodName : String
        , transport : String
        , binding : Maybe Int
        , request : Request
        , httpStatus : Maybe Int
        , headers : Dict String String
        , trailers : Dict String String
        , code : Maybe Code
        , duration : Float
        , attempts : Int
        }
