module Rpc.Internal.Client exposing (Client(..))

{-| A client: a protocol, and where and how to send calls over it. Not
exposed. Two public modules need the constructor: `Rpc.Client` builds and
reads one and aliases the type, `Rpc` sends through it.
-}

import Rpc.Internal.Protocol exposing (Protocol)
import Rpc.Internal.Retry exposing (Retry)


type Client codec
    = Client
        { protocol : Protocol codec
        , baseUrl : String
        , headers : List ( String, String )
        , timeout : Maybe Float
        , withCredentials : Bool
        , retry : Maybe Retry
        }
