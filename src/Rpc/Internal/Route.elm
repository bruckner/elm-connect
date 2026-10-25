module Rpc.Internal.Route exposing (Route(..), bindingBody, connectUrl, invalidPathValue, route, transcodeUrl)

{-| Where a call goes over HTTP: the binding of its `google.api.http` rule it
takes, the URL that binding's path and query make of the request, and the
body it sends, or the implicit route of a method without a rule. Not
exposed; it is the mapping `Rpc.request` and `Rpc.response` share, kept out
of `Rpc` so that the public module reads as API.
-}

import Json.Decode
import Json.Encode exposing (Value)
import Proto.Internal.Binding exposing (Binding(..), Body(..), Param(..), Rule, Segment(..))
import Proto.Method as Method
import Rpc.Body as Body exposing (Body)
import Rpc.Call
import Rpc.Internal.Call exposing (Call(..))
import Rpc.Internal.Http as Internal
import Rpc.Internal.Transport exposing (Transport(..))


{-| How a call is sent: over a binding of its rule (by number), or over the
implicit route of a method without a rule.
-}
type Route
    = Bound Int Rule
    | Implicit


{-| The route a call takes over a transport: Connect always takes the implicit
one.
-}
route : Transport -> Call req res -> Route
route transport (Call fields) =
    case transport of
        Connect _ ->
            Implicit

        Transcode _ ->
            -- A call's binding number is one its descriptor has (`viaBinding`
            -- checks), or 0 for a method without bindings.
            case List.head (List.drop fields.binding (Method.bindings (Method.toDescriptor fields.method))) of
                Just (Binding rule) ->
                    Bound fields.binding rule

                Nothing ->
                    Implicit


{-| The URL Connect sends a call to: `baseUrl/service/method`.
-}
connectUrl : String -> Call req res -> String
connectUrl baseUrl c =
    trimSlash baseUrl ++ "/" ++ Rpc.Call.serviceName c ++ "/" ++ Rpc.Call.methodName c


{-| The URL of a call over one binding of its rule: the path filled from the
request's JSON, the custom verb, and the query from the fields the rule puts
there.
-}
transcodeUrl : String -> Rule -> Value -> String
transcodeUrl baseUrl rule json =
    let
        path =
            List.map (pathSegment json) rule.path

        verb =
            Maybe.map ((++) ":" << Internal.encodeRouteText) rule.customVerb |> Maybe.withDefault ""

        query =
            case List.concatMap (queryPairs json) rule.query of
                [] ->
                    ""

                pairs ->
                    "?" ++ String.join "&" pairs
    in
    trimSlash baseUrl ++ "/" ++ String.join "/" path ++ verb ++ query


pathSegment : Value -> Segment -> String
pathSegment json segment =
    case segment of
        Literal written ->
            Internal.encodeRouteText written

        Variable fieldPath template zero ->
            let
                keep =
                    if single template then
                        Internal.unreserved

                    else
                        \char -> Internal.unreserved char || char == '/'
            in
            pathText json fieldPath zero
                |> Internal.percentEncode keep

        -- Generated bindings never hold a wildcard outside a variable: no
        -- field fills it.
        Wildcard ->
            ""

        DoubleWildcard ->
            ""


{-| A path variable's value, before encoding: its scalar text, or the text of
the field's default when the JSON has none.
-}
pathText : Value -> List String -> String -> String
pathText json fieldPath zero =
    lookup fieldPath json
        |> Maybe.andThen scalarText
        |> Maybe.withDefault zero


{-| The first path variable of a binding whose value its template cannot
match, by its JSON field path and its template. A request carrying it can
never reach the method: no server route matches it, or a different one does.
-}
invalidPathValue : Rule -> Value -> Maybe { field : String, template : String }
invalidPathValue rule json =
    case rule.path of
        [] ->
            Nothing

        (Variable fieldPath template zero) :: rest ->
            if matches template (pathText json fieldPath zero) then
                invalidPathValue { rule | path = rest } json

            else
                Just { field = String.join "." fieldPath, template = templateText template }

        _ :: rest ->
            invalidPathValue { rule | path = rest } json


{-| Whether a value matches a variable's template as `google.api.http` defines
it. A single-segment value is one segment whatever it holds, since its `/` is
escaped; a multi-segment value is split at each `/`, and every segment must
be non-empty: a literal matches itself, `*` one segment and `**` any number.
-}
matches : List Segment -> String -> Bool
matches template value =
    if single template then
        case template of
            [ Literal written ] ->
                value == written

            _ ->
                value /= ""

    else
        let
            parts =
                String.split "/" value
        in
        List.all ((/=) "") parts && matchParts template parts


matchParts : List Segment -> List String -> Bool
matchParts template parts =
    case ( template, parts ) of
        ( [], [] ) ->
            True

        ( (Literal written) :: rest, part :: others ) ->
            written == part && matchParts rest others

        ( Wildcard :: rest, _ :: others ) ->
            matchParts rest others

        ( DoubleWildcard :: rest, _ ) ->
            List.range 0 (List.length parts)
                |> List.any (\taken -> matchParts rest (List.drop taken parts))

        _ ->
            False


{-| A variable's template as `google.api.http` writes it.
-}
templateText : List Segment -> String
templateText template =
    if List.isEmpty template then
        "*"

    else
        template
            |> List.map
                (\segment ->
                    case segment of
                        Literal written ->
                            written

                        Wildcard ->
                            "*"

                        DoubleWildcard ->
                            "**"

                        Variable _ _ _ ->
                            ""
                )
            |> String.join "/"


single : List Segment -> Bool
single template =
    case template of
        [] ->
            True

        [ Literal _ ] ->
            True

        [ Wildcard ] ->
            True

        _ ->
            False


queryPairs : Value -> Param -> List String
queryPairs json (Param p) =
    let
        values =
            case lookup p.path json of
                Nothing ->
                    []

                Just value ->
                    case Json.Decode.decodeValue (Json.Decode.list Json.Decode.value) value of
                        Ok elements ->
                            List.filterMap scalarText elements

                        Err _ ->
                            -- Generated encoders leave a default out; JSON
                            -- from another encoder may spell it.
                            case scalarText value of
                                Just text ->
                                    if Just text == p.zero then
                                        []

                                    else
                                        [ text ]

                                Nothing ->
                                    []
    in
    List.map
        (\v -> Internal.percentEncode Internal.unreserved p.name ++ "=" ++ Internal.percentEncode Internal.unreserved v)
        values


bindingBody : Rule -> Value -> Body
bindingBody rule json =
    case rule.body of
        NoBody ->
            Body.none

        WholeBody ->
            Body.text (Json.Encode.encode 0 (List.foldl remove json (variables rule.path)))

        BodyField key ->
            lookup [ key ] json
                |> Maybe.withDefault (Json.Encode.object [])
                |> Json.Encode.encode 0
                |> Body.text


variables : List Segment -> List (List String)
variables =
    List.filterMap
        (\segment ->
            case segment of
                Variable fieldPath _ _ ->
                    Just fieldPath

                _ ->
                    Nothing
        )


{-| The JSON without the value at `fieldPath`; unchanged when there is none.
-}
remove : List String -> Value -> Value
remove fieldPath json =
    case fieldPath of
        [] ->
            json

        key :: rest ->
            case Json.Decode.decodeValue (Json.Decode.keyValuePairs Json.Decode.value) json of
                Ok pairs ->
                    pairs
                        |> List.filterMap
                            (\( k, v ) ->
                                if k /= key then
                                    Just ( k, v )

                                else if List.isEmpty rest then
                                    Nothing

                                else
                                    Just ( k, remove rest v )
                            )
                        |> Json.Encode.object

                Err _ ->
                    json


{-| The value at a JSON path, unless absent or `null`.
-}
lookup : List String -> Value -> Maybe Value
lookup fieldPath json =
    Json.Decode.decodeValue (Json.Decode.at fieldPath (Json.Decode.nullable Json.Decode.value)) json
        |> Result.toMaybe
        |> Maybe.andThen identity


{-| A scalar JSON value as query or path text: a string as it is, a number or
a boolean as JSON writes it. `null`, objects and arrays have none.
-}
scalarText : Value -> Maybe String
scalarText value =
    Json.Decode.decodeValue
        (Json.Decode.oneOf
            [ Json.Decode.map Just Json.Decode.string
            , Json.Decode.map
                (\b ->
                    if b then
                        Just "true"

                    else
                        Just "false"
                )
                Json.Decode.bool
            , Json.Decode.map (\_ -> Just (Json.Encode.encode 0 value)) Json.Decode.float
            , Json.Decode.succeed Nothing
            ]
        )
        value
        |> Result.withDefault Nothing


trimSlash : String -> String
trimSlash url =
    if String.endsWith "/" url then
        String.dropRight 1 url

    else
        url
