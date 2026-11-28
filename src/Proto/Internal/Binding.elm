module Proto.Internal.Binding exposing
    ( Binding(..)
    , Body(..)
    , Param(..)
    , Rule
    , Segment(..)
    , withBindings
    )

{-| The HTTP binding types, with their constructors, and the interpreter that
reads them.

`Proto.Http` builds the types and exposes them alone, so an application builds
a binding and cannot take one apart. Generated code writes each method's
`google.api.http` rule as this data into its descriptor, and builds its
routes with typed route functions instead.

The interpreter, [`withBindings`](#withBindings), gives a method its routes
from bindings as data, reading each route from the request's proto3 JSON. No
generated code calls it, and it is not exposed: the package's tests use it as
an oracle, an implementation of transcoding apart from the generator's, which
the generated route functions must agree with.

-}

import Json.Decode
import Json.Encode exposing (Value)
import Proto.Internal.Method as Method exposing (Method)
import Proto.Internal.Percent as Internal
import Proto.Route exposing (PathError, Route)


type Binding
    = Binding Rule


type alias Rule =
    { method : String
    , path : List Segment
    , customVerb : Maybe String
    , body : Body
    , responseBody : Maybe String
    , query : List Param
    }


type Segment
    = Literal String
    | Wildcard
    | DoubleWildcard
    | Variable (List String) (List Segment) String


type Body
    = NoBody
    | WholeBody
    | BodyField String


type Param
    = Param { name : String, path : List String, zero : Maybe String }


{-| The method's routes from its `google.api.http` bindings as data: each
route is read from the request's proto3 JSON, written with the registry in
use and encoded once per send for the route and the body alike, and each
binding's answer is read from the response field its data names. The routes
replace any the method had.
-}
withBindings : List Binding -> Method idempotency codec req res -> Method idempotency codec req res
withBindings methodBindings (Method.Method m) =
    Method.Method
        { m
            | routes =
                List.map
                    (\(Binding rule) ->
                        { shape = Method.FromJson (\_ json -> route rule json)
                        , responseBody = rule.responseBody
                        }
                    )
                    methodBindings
        }


{-| The route of a request over a binding, built whatever its path values,
and the first path value its template cannot match, if any.
-}
route : Rule -> Value -> Route
route rule json =
    let
        verb =
            Maybe.map ((++) ":" << Internal.encodeRouteText) rule.customVerb |> Maybe.withDefault ""
    in
    { method = rule.method
    , path = String.join "/" (List.map (pathSegment json) rule.path) ++ verb
    , query = List.concatMap (queryPairs json) rule.query
    , body = body rule json
    , invalid = invalidPathValue rule json
    }


body : Rule -> Value -> Maybe Value
body rule json =
    case rule.body of
        NoBody ->
            Nothing

        WholeBody ->
            Just (Proto.Route.without (variables rule.path) json)

        BodyField key ->
            Just (lookup [ key ] json |> Maybe.withDefault (Json.Encode.object []))


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
A value holding a surrogate without its pair matches none: it has no UTF-8
form, so no URL holds it as it is.
-}
invalidPathValue : Rule -> Value -> Maybe PathError
invalidPathValue rule json =
    case rule.path of
        [] ->
            Nothing

        (Variable fieldPath template zero) :: rest ->
            let
                value =
                    pathText json fieldPath zero
            in
            if Internal.wellFormed value && matches template value then
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


queryPairs : Value -> Param -> List ( String, String )
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
    List.map (\v -> ( p.name, v )) values


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
