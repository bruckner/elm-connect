module Rpc.Internal.Transcode exposing (transcode, transcodeMessage, transcodeTimeout)

{-| HTTP transcoding: the request over a call's route, or Connect's POST over the
implicit route, and its reading of an answer. Not exposed; `Rpc.Protocol.transcode`
installs these functions (`Rpc.Internal.Protocol`), so a program that never
names it carries none of its route code. A failure is read as every protocol's
is (`Rpc.Internal.Answer`).
-}

import Http
import Json.Encode exposing (Value)
import Proto.Internal.Percent as Percent
import Proto.Route exposing (Route)
import Rpc.Body as Body
import Rpc.Error exposing (Error, Reason)
import Rpc.Internal.Answer as Answer
import Rpc.Internal.Connect as Connect
import Rpc.Internal.Http as Internal
import Rpc.Internal.Protocol exposing (GoodText, Options, Settings)
import Rpc.Request exposing (Request)



-- REQUESTS


{-| Transcoding's request over the call's route: the route's method, its
path and query, its body; or, for a method without routes, the request
Connect would POST (the implicit route).
-}
transcode : Options -> Settings -> Maybe Route -> (() -> Value) -> Request
transcode options settings route json =
    case route of
        Just r ->
            { method = r.method
            , url = Internal.trimSlash settings.baseUrl ++ "/" ++ r.path ++ query r.query
            , headers = settings.headers
            , body =
                case r.body of
                    Just body ->
                        Body.text (Json.Encode.encode 0 body)

                    Nothing ->
                        Body.none
            , timeout = settings.timeout
            , withCredentials = settings.withCredentials
            }

        Nothing ->
            Connect.connectPost options settings route json


query : List ( String, String ) -> String
query pairs =
    case pairs of
        [] ->
            ""

        _ ->
            "?"
                ++ String.join "&"
                    (List.map
                        (\( name, value ) ->
                            Percent.percentEncode Percent.unreserved name ++ "=" ++ Percent.percentEncode Percent.unreserved value
                        )
                        pairs
                    )


{-| Transcoding carries none over a route, and Connect's over the implicit
route.
-}
transcodeTimeout : Maybe Route -> Maybe ( String, Float -> String )
transcodeTimeout route =
    case route of
        Just _ ->
            Nothing

        Nothing ->
            Just ( "Connect-Timeout-Ms", Internal.timeoutMs )



-- ANSWERS


{-| Transcoding's message.
-}
transcodeMessage : (Options -> String -> Maybe Reason) -> Options -> Maybe String -> Http.Response String -> Result Error GoodText
transcodeMessage overRead options responseBody answer =
    transcodeRead responseBody answer |> Result.andThen (Answer.withinText overRead options)


{-| Transcoding's: success is any 2xx, an empty body reading as `{}`, and the
response is read from the field the route's `response_body` names.
-}
transcodeRead : Maybe String -> Http.Response String -> Result Error GoodText
transcodeRead responseBody answer =
    case answer of
        Http.GoodStatus_ metadata raw ->
            Ok
                { metadata = metadata
                , raw = raw
                , text = orEmptyObject raw
                , field = responseBody
                }

        _ ->
            Err (Answer.otherFailure answer)


orEmptyObject : String -> String
orEmptyObject raw =
    if String.isEmpty (String.trim raw) then
        "{}"

    else
        raw
