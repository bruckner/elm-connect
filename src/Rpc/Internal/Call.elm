module Rpc.Internal.Call exposing (Call(..))

{-| A method applied to its request. Not exposed. Two public modules need the
constructor: `Rpc.call` builds a call, `Rpc.Call` reads and modifies it and
aliases the type, so it lives here, out of users' reach, and a per-call
adjustment can be added without breaking code that holds a call.
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
