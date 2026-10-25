module Rpc.Internal.Route exposing (Route(..), connectUrl, route, transcodeBody, transcodeUrl)

{-| Where a call goes over HTTP: the binding of its `google.api.http` rule it
takes, the URL that binding's route makes, and the body it sends, or the
implicit route of a method without a rule. Not exposed; it is the mapping
`Rpc.request` and `Rpc.response` share, kept out of `Rpc` so that the public
module reads as API.
-}

import Json.Encode
import Proto.Internal.Method as Method exposing (Bound)
import Rpc.Body as Body exposing (Body)
import Rpc.Call
import Rpc.Internal.Call exposing (Call(..))
import Rpc.Internal.Http as Internal
import Rpc.Internal.Transport exposing (Transport(..))
import Rpc.Route


{-| How a call is sent: over a binding of its method (by number), or over
the implicit route of a method without a rule.
-}
type Route req
    = Bound Int (Bound req)
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
            -- A call's binding number is one its method has (`viaBinding`
            -- checks), or 0 for a method without bindings.
            case fields.method of
                Method.Method m ->
                    case List.head (List.drop fields.binding m.routes) of
                        Just bound ->
                            Bound fields.binding bound

                        Nothing ->
                            Implicit


{-| The URL Connect sends a call to: `baseUrl/service/method`.
-}
connectUrl : String -> Call req res -> String
connectUrl baseUrl c =
    trimSlash baseUrl ++ "/" ++ Rpc.Call.serviceName c ++ "/" ++ Rpc.Call.methodName c


{-| The URL of a binding's route: its path, then its query percent-encoded.
-}
transcodeUrl : String -> Rpc.Route.Route -> String
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
                                    Internal.percentEncode Internal.unreserved name ++ "=" ++ Internal.percentEncode Internal.unreserved value
                                )
                                pairs
                            )
    in
    trimSlash baseUrl ++ "/" ++ r.path ++ query


{-| The body of a binding's route.
-}
transcodeBody : Rpc.Route.Route -> Body
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
