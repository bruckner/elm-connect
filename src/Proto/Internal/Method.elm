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


{-| One binding as a call takes it: its route, built whatever its path
values, with the first path value its template cannot match, and the JSON
name of the response field its answer is read from.
-}
type alias Bound req =
    { build : req -> ( Route, Maybe PathError )
    , responseBody : Maybe String
    }
