module Rpc.Route exposing
    ( Route, PathError
    , segment, segments
    , scalar, optional, repeated
    , jsonText, without
    )

{-| Where a call goes over one binding of its `google.api.http` rule, as
generated route functions build it from a typed request:
`routeGetNote0 : GetNoteRequest -> Result PathError Route`. The helpers
below are what such functions call; application code reads a `Route` and
does not build one.

@docs Route, PathError


# Path variables

@docs segment, segments


# Query parameters

@docs scalar, optional, repeated


# Values and bodies

@docs jsonText, without

-}

import Json.Decode
import Json.Encode exposing (Value)
import Rpc.Internal.Http as Internal


{-| A binding's request: its HTTP method, its path percent-encoded and
without a leading slash (`v1/notes/42:archive`), its query as name and
value pairs not yet encoded, in order, and its body as JSON, `Nothing` for
none.
-}
type alias Route =
    { method : String
    , path : String
    , query : List ( String, String )
    , body : Maybe Value
    }


{-| A path value its variable's template cannot match: the variable's field,
as its dotted JSON field path, and its template as `google.api.http` writes
it. Sending the call fails with
[`InvalidPathValue`](Rpc-Error#Reason), which carries this record.
-}
type alias PathError =
    { field : String, template : String }


{-| A variable of one segment: `segment "name" "*" value` for `{name}` or
`{name=*}`, which takes any value but `""`, and `segment "v" "v1" value` for
`{v=v1}`, which takes only the literal. The value is percent-encoded with
`/` escaped.
-}
segment : String -> String -> String -> Result PathError String
segment field template value =
    let
        ok =
            if template == "*" then
                value /= ""

            else
                value == template
    in
    if ok then
        Ok (Internal.percentEncode Internal.unreserved value)

    else
        Err { field = field, template = template }


{-| A variable of several segments, by its template's segments
(`[ "notes", "*" ]` for `{name=notes/*}`, `"**"` for any number): the value
split at each `/` must have non-empty segments that match. The value is
percent-encoded, each `/` kept.
-}
segments : String -> List String -> String -> Result PathError String
segments field template value =
    let
        parts =
            String.split "/" value
    in
    if List.all ((/=) "") parts && matchParts template parts then
        Ok (Internal.percentEncode (\char -> Internal.unreserved char || char == '/') value)

    else
        Err { field = field, template = String.join "/" template }


matchParts : List String -> List String -> Bool
matchParts template parts =
    case ( template, parts ) of
        ( [], [] ) ->
            True

        ( "**" :: rest, _ ) ->
            List.range 0 (List.length parts)
                |> List.any (\taken -> matchParts rest (List.drop taken parts))

        ( "*" :: rest, _ :: others ) ->
            matchParts rest others

        ( written :: rest, part :: others ) ->
            written == part && matchParts rest others

        _ ->
            False


{-| A query parameter of a field without presence: none when its text is
the field's default's (`zero`).
-}
scalar : String -> String -> String -> List ( String, String )
scalar name zero text =
    if text == zero then
        []

    else
        [ ( name, text ) ]


{-| A query parameter of a field with presence: none when unset.
-}
optional : String -> (a -> String) -> Maybe a -> List ( String, String )
optional name toText value =
    case value of
        Just v ->
            [ ( name, toText v ) ]

        Nothing ->
            []


{-| A repeated field's query parameters: one per element.
-}
repeated : String -> (a -> String) -> List a -> List ( String, String )
repeated name toText values =
    List.map (\v -> ( name, toText v )) values


{-| A scalar's proto3 JSON as path or query text: a string as it is, a
number or a boolean as JSON writes it.
-}
jsonText : Value -> String
jsonText value =
    Json.Decode.decodeValue
        (Json.Decode.oneOf
            [ Json.Decode.string
            , Json.Decode.map
                (\b ->
                    if b then
                        "true"

                    else
                        "false"
                )
                Json.Decode.bool
            , Json.Decode.map (\_ -> Json.Encode.encode 0 value) Json.Decode.float
            ]
        )
        value
        |> Result.withDefault ""


{-| The JSON without the values at each JSON field path: the body of
`body: "*"` without the fields the path holds.
-}
without : List (List String) -> Value -> Value
without paths json =
    List.foldl remove json paths


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
