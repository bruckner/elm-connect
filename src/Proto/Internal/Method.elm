module Proto.Internal.Method exposing (Bound, Method(..))

{-| The method type, defined here so that `Rpc` can read a method's routes,
which `Proto.Method` exposes only to build. It is over the descriptor's
type, which `Proto.Method` defines, so that `Proto.Method` can expose the
descriptor's unions with their constructors.
-}

import Json.Decode
import Json.Encode
import Rpc.Route exposing (PathError, Route)


type Method descriptor req res
    = Method
        { encodeRequest : req -> Json.Encode.Value
        , responseDecoder : Json.Decode.Decoder res
        , descriptor : descriptor
        , routes : List (Bound req)
        }


{-| One binding as a call takes it: its route of the request, built
whatever its path values.
-}
type alias Bound req =
    req -> Route
