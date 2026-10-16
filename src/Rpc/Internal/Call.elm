module Rpc.Internal.Call exposing (Call(..))

{-| A method applied to its request. Not exposed; `Rpc.Call.Call` is this
type, its constructor private so that `Rpc.call` alone makes one and a
per-call adjustment can be added without breaking code that holds one.
-}

import Proto.Method exposing (Method)


{-| A call; `Rpc.Call`'s readers say what each field holds.
-}
type Call req res
    = Call
        { method : Method req res
        , message : req
        , binding : Int
        , headers : List ( String, String )
        , timeout : Maybe Float
        , tracker : Maybe String
        }
