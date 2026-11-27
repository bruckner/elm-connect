module Proto.Route exposing
    ( Route, PathError
    , segment, segments, checkSegment, checkSegments, firstInvalid
    , boolText, bytesText, fieldMaskText, viaJson, jsonText, without, jsonField, jsonValueField
    )

{-| Where a call goes over one binding of its `google.api.http` rule, as
generated route functions build it from a typed request:
`routeGetNote0 : GetNoteRequest -> Route`: the route, built whatever the
request holds, with the first path value its variable's template cannot
match. The helpers below are what such functions call; application code
reads a `Route` and does not build one.

@docs Route, PathError


# Path variables

@docs segment, segments, checkSegment, checkSegments, firstInvalid


# Values and bodies

@docs boolText, bytesText, fieldMaskText, viaJson, jsonText, without, jsonField, jsonValueField

-}

import Bytes exposing (Bytes)
import Json.Decode
import Json.Encode exposing (Value)
import Proto.Bytes
import Proto.Internal.FieldMask as FieldMask
import Proto.Internal.Percent as Internal


{-| A binding's request: its HTTP method, its path percent-encoded and
without a leading slash (`v1/notes/42:archive`), its query as name and
value pairs not yet encoded, in order, its body as JSON (`Nothing` for
none), and the first path value its variable's template cannot match,
which sending refuses. The response field a binding's answer is read from
is not part of it but the method's
([`Proto.Method.withResponseBody`](Proto-Method#withResponseBody)), so that
reading an answer builds no route.
-}
type alias Route =
    { method : String
    , path : String
    , query : List ( String, String )
    , body : Maybe Value
    , invalid : Maybe PathError
    }


{-| A path value its variable's template cannot match: the variable's field,
as its dotted JSON field path, and its template as `google.api.http` writes
it. Sending the call fails as a [`BadCall`](Rpc-Error#Cause), whose message
names the field and the template.
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
            Internal.wellFormed value
                && (if template == "*" then
                        value /= ""

                    else
                        value == template
                   )
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
    if Internal.wellFormed value && List.all ((/=) "") parts && matchParts template parts then
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


{-| A boolean as path text.
-}
boolText : Bool -> String
boolText b =
    if b then
        "true"

    else
        "false"


{-| A `bytes` field held as `Bytes`, as path or query text: its base64 in the
URL-safe alphabet (`-` and `_` for `+` and `/`), padded, which transcoders
read in a path and in a query alike.
-}
bytesText : Bytes -> String
bytesText bytes =
    String.map urlSafe (Proto.Bytes.toBase64 bytes)


urlSafe : Char -> Char
urlSafe char =
    case char of
        '+' ->
            '-'

        '/' ->
            '_'

        _ ->
            char


{-| A `google.protobuf.FieldMask` as path or query text: its proto3 JSON
text, each field name in lowerCamelCase and the paths joined by commas.
-}
fieldMaskText : List String -> String
fieldMaskText =
    FieldMask.toText


{-| A value's path or query text, by its proto3 JSON encoder: for the types
whose text is their JSON's (enums, floating-point numbers, bytes).
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


{-| The body of `body: "field"` from the request's proto3 JSON: the field's
value, or `{}` when the JSON leaves it out or holds `null`.
-}
jsonField : String -> Value -> Value
jsonField key json =
    case Json.Decode.decodeValue (Json.Decode.field key (Json.Decode.nullable Json.Decode.value)) json of
        Ok (Just value) ->
            value

        _ ->
            Json.Encode.object []


{-| The body of `body: "field"` for a `google.protobuf.Value` field, from the
request's proto3 JSON: the field's value, `null` (its `NullValue`) included,
or `{}` when the JSON leaves it out, as [`jsonField`](#jsonField) gives an
unset message.
-}
jsonValueField : String -> Value -> Value
jsonValueField key json =
    case Json.Decode.decodeValue (Json.Decode.field key Json.Decode.value) json of
        Ok value ->
            value

        Err _ ->
            Json.Encode.object []
