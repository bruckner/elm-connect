module Rpc.Internal.Route exposing (Route(..), connectUrl, route, transcodeBody, transcodeUrl)

{-| Where a call goes over HTTP: the route of its method's binding it takes,
the URL that route makes, and the body it sends, or the implicit route of a
method without routes. Not exposed; it is the mapping `Rpc.request` and
`Rpc.response` share, kept out of `Rpc` so that the public module reads as
API.
-}

import Json.Encode
import Proto.Internal.Method
import Proto.Internal.Percent as Percent
import Proto.Route
import Rpc.Body as Body exposing (Body)
import Rpc.Call
import Rpc.Internal.Call exposing (Call(..))
import Rpc.Internal.Transport exposing (Transport(..))


{-| How a call is sent: over a binding of its method (by number), by that
binding's route function, or over the implicit route of a method without
routes.
-}
type Route req
    = Bound Int (req -> Proto.Route.Route)
    | Implicit


{-| The route a call takes over a transport: Connect always takes the implicit
one.
-}
route : Transport -> Call req res -> Route req
route transport (Call fields) =
    case transport of
        Connect _ ->
            Implicit

        Transcode _ ->
            let
                (Proto.Internal.Method.Method m) =
                    fields.method
            in
            -- A call's binding number is one its method has (`viaBinding`
            -- checks), or 0 for a method without routes.
            case List.head (List.drop fields.binding m.routes) of
                Just bound ->
                    Bound fields.binding bound

                Nothing ->
                    Implicit


{-| The URL Connect sends a call to: the base URL and the call's procedure
path, `/service/method`.
-}
connectUrl : String -> Call req res -> String
connectUrl baseUrl c =
    trimSlash baseUrl ++ Rpc.Call.procedure c


{-| The URL of a binding's route: its path, then its query percent-encoded.
-}
transcodeUrl : String -> Proto.Route.Route -> String
transcodeUrl baseUrl r =
    let
        query =
            case r.query of
                [] ->
                    ""

                pairs ->
                    "?"
                        ++ String.join "&"
                            (List.map
                                (\( name, value ) ->
                                    Percent.percentEncode Percent.unreserved name ++ "=" ++ Percent.percentEncode Percent.unreserved value
                                )
                                pairs
                            )
    in
    trimSlash baseUrl ++ "/" ++ r.path ++ query


{-| The body of a binding's route.
-}
transcodeBody : Proto.Route.Route -> Body
transcodeBody r =
    case r.body of
        Just json ->
            Body.text (Json.Encode.encode 0 json)

        Nothing ->
            Body.none


trimSlash : String -> String
trimSlash url =
    if String.endsWith "/" url then
        String.dropRight 1 url

    else
        url
