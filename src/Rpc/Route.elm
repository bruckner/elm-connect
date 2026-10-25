module Rpc.Route exposing
    ( Route, PathError
    , segment, segments, checkSegment, checkSegments, firstInvalid
    , string, int, int64, bool, float, enum, optional, repeated, unlessZero, except
    , boolText, viaJson, jsonText, without
    )

{-| Where a call goes over one binding of its `google.api.http` rule, as
generated route functions build it from a typed request:
`routeGetNote0 : GetNoteRequest -> Route`: the route, built whatever the
request holds, with the first path value its variable's template cannot
match. The helpers
below are what such functions call; application code reads a `Route` and
does not build one.

@docs Route, PathError


# Path variables

@docs segment, segments, checkSegment, checkSegments, firstInvalid


# Query parameters

@docs string, int, int64, bool, float, enum, optional, repeated, unlessZero, except


# Values and bodies

@docs boolText, viaJson, jsonText, without

-}

import Json.Decode
import Json.Encode exposing (Value)
import Rpc.Internal.Http as Internal


{-| A binding's request: its HTTP method, its path percent-encoded and
without a leading slash (`v1/notes/42:archive`), its query as name and
value pairs not yet encoded, in order, its body as JSON (`Nothing` for
none), the JSON name of the response field its answer is read from
(`Nothing` for the whole response), and the first path value its
variable's template cannot match, which sending refuses.
-}
type alias Route =
    { method : String
    , path : String
    , query : List ( String, String )
    , body : Maybe Value
    , responseBody : Maybe String
    , invalid : Maybe PathError
    }


{-| A path value its variable's template cannot match: the variable's field,
as its dotted JSON field path, and its template as `google.api.http` writes
it. Sending the call fails with
[`InvalidPathValue`](Rpc-Error#Reason), which carries this record.
-}
type alias PathError =
    { field : String, template : String }


{-| A variable of one segment's value, percent-encoded with `/` escaped.
-}
segment : String -> String
segment =
    Internal.percentEncode Internal.unreserved


{-| A variable of several segments' value, percent-encoded with each `/`
kept.
-}
segments : String -> String
segments =
    Internal.percentEncode (\char -> Internal.unreserved char || char == '/')


{-| Whether a variable of one segment matches its value: `checkSegment "name"
"*" value` for `{name}` or `{name=*}`, which takes any value but `""`, and
`checkSegment "v" "v1" value` for `{v=v1}`, which takes only the literal.
-}
checkSegment : String -> String -> String -> Maybe PathError
checkSegment field template value =
    let
        ok =
            if template == "*" then
                value /= ""

            else
                value == template
    in
    if ok then
        Nothing

    else
        Just { field = field, template = template }


{-| Whether a variable of several segments matches its value, by its
template's segments (`[ "notes", "*" ]` for `{name=notes/*}`, `"**"` for any
number): the value split at each `/` must have non-empty segments that
match.
-}
checkSegments : String -> List String -> String -> Maybe PathError
checkSegments field template value =
    let
        parts =
            String.split "/" value
    in
    if List.all ((/=) "") parts && matchParts template parts then
        Nothing

    else
        Just { field = field, template = String.join "/" template }


{-| The first problem of a route's path variables, in path order.
-}
firstInvalid : List (Maybe PathError) -> Maybe PathError
firstInvalid checks =
    case checks of
        [] ->
            Nothing

        (Just problem) :: _ ->
            Just problem

        Nothing :: rest ->
            firstInvalid rest


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


{-| A query parameter of a field without presence, by its name, its proto3
default and its text: none at the default.
-}
unlessZero : String -> a -> (a -> String) -> a -> List ( String, String )
unlessZero name zero toText value =
    if value == zero then
        []

    else
        [ ( name, toText value ) ]


{-| A `string` or `bytes` field's parameter: none at `""`.
-}
string : String -> String -> List ( String, String )
string name value =
    if value == "" then
        []

    else
        [ ( name, value ) ]


{-| A 32-bit integer field's parameter: none at 0.
-}
int : String -> Int -> List ( String, String )
int name value =
    if value == 0 then
        []

    else
        [ ( name, String.fromInt value ) ]


{-| A 64-bit integer field's parameter, held as its decimal string: none at
`"0"`.
-}
int64 : String -> String -> List ( String, String )
int64 name value =
    if value == "0" then
        []

    else
        [ ( name, value ) ]


{-| A boolean field's parameter: none at `False`.
-}
bool : String -> Bool -> List ( String, String )
bool name value =
    if value then
        [ ( name, "true" ) ]

    else
        []


{-| A floating-point field's parameter, as proto3 JSON writes it (`NaN`,
`Infinity`, `-Infinity` included): none at 0.
-}
float : String -> Float -> List ( String, String )
float name value =
    -- Not `value == 0`, which compiles to `!value` and so drops NaN.
    if value /= 0 || isNaN value then
        [ ( name, String.fromFloat value ) ]

    else
        []


{-| An enum field's parameter, by its zero and its encoder: none at the zero.
-}
enum : String -> e -> (e -> Value) -> e -> List ( String, String )
enum name zero encode value =
    if value == zero then
        []

    else
        [ ( name, jsonText (encode value) ) ]


{-| A parameter of a field with presence, as text: none when unset.
-}
optional : String -> Maybe String -> List ( String, String )
optional name value =
    case value of
        Just v ->
            [ ( name, v ) ]

        Nothing ->
            []


{-| A repeated field's parameters, as text: one per element.
-}
repeated : String -> List String -> List ( String, String )
repeated name values =
    List.map (Tuple.pair name) values


{-| A message's query parameters without those of the named fields: a
binding's query, from its request message's query encoder less the fields
its path and body hold.
-}
except : List String -> List ( String, String ) -> List ( String, String )
except names pairs =
    List.filter (\( name, _ ) -> not (List.member name names)) pairs


{-| A boolean as path text.
-}
boolText : Bool -> String
boolText b =
    if b then
        "true"

    else
        "false"


{-| A value's path or query text, by its proto3 JSON encoder: for the types
whose text is their JSON's (enums, floating-point numbers, bytes, field
masks).
-}
viaJson : (a -> Value) -> a -> String
viaJson encode value =
    jsonText (encode value)


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
