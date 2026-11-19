module Rpc.Internal.Client exposing (Client(..), Data)

{-| A client: a protocol, and where and how to send calls over it. Not
exposed. Two public modules need the constructor: `Rpc.Client` builds and
reads one and aliases the type, `Rpc` sends through it.

Its parts are in the order `==` should meet them, since elm/core's `==`
compares a constructor's arguments in order, stops at the first that differ,
and throws on two functions that are not the same one (how its code works,
not a guarantee of the language: `Rpc.Internal.Protocol` says more): the
data, which holds no function; the protocol and the retry
policy, each data first and functions after; and the registry last, whose
functions are fresh wherever it is built in place, so that two clients
differing in anything else are unequal before `==` reaches it.

-}

import Proto.Registry exposing (Registry)
import Rpc.Internal.Protocol exposing (Protocol)
import Rpc.Internal.Retry exposing (Retry)


type Client codec
    = Client Data (Protocol codec) (Maybe Retry) Registry


{-| Where and how calls go: the base URL, the headers, the timeout and
whether credentials go cross-origin.
-}
type alias Data =
    { baseUrl : String
    , headers : List ( String, String )
    , timeout : Maybe Float
    , withCredentials : Bool
    }
