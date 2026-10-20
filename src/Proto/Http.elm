module Proto.Http exposing
    ( Binding, binding
    , Segment, literal, variable, wildcard, doubleWildcard
    , Body, noBody, wholeBody, bodyField
    , Param, param
    )

{-| A method's `google.api.http` rule as data: its bindings, each a verb, a
path template, a body and query parameters. The generator parses the rule
and writes these into the method's [descriptor](Proto-Method#Descriptor);
application code only passes them along, and `Rpc` builds the request from
them under the Transcode transport.

@docs Binding, binding
@docs Segment, literal, variable, wildcard, doubleWildcard
@docs Body, noBody, wholeBody, bodyField
@docs Param, param

-}

import Proto.Enum
import Proto.EnumValue
import Proto.Field exposing (Cardinality(..), Kind(..), Scalar(..))
import Proto.Internal.Binding as Internal


{-| One binding of a method's `google.api.http` rule.
-}
type alias Binding =
    Internal.Binding


{-| A binding, as the generator parses it:

  - `method`: the HTTP method, such as `"GET"`.
  - `path`: the path template's segments.
  - `customVerb`: the text after `:` at the end of the template, if any.
  - `body`: what the request body holds.
  - `responseBody`: the descriptor of the top-level response field the answer
    holds (`Notes.V1.ListNotesResponse.notes`), if it is not the whole
    response. The answer is read as that field's JSON.
  - `query`: the query parameters, every request field outside the path and the
    body.

-}
binding :
    { method : String
    , path : List Segment
    , customVerb : Maybe String
    , body : Body
    , responseBody : Maybe Proto.Field.Descriptor
    , query : List Param
    }
    -> Binding
binding rule =
    Internal.Binding
        { method = rule.method
        , path = rule.path
        , customVerb = rule.customVerb
        , body = rule.body
        , responseBody = Maybe.map Proto.Field.jsonName rule.responseBody
        , query = rule.query
        }


{-| One segment of a path template.
-}
type alias Segment =
    Internal.Segment


{-| Literal text, written as it is.
-}
literal : String -> Segment
literal =
    Internal.Literal


{-| A request field's value. `fieldPath` is the path of field descriptors from the
request message down to the field, a scalar or an enum, through singular
message fields: `[ Notes.V1.GetNoteRequest.name ]` for `{name}`, or
`[ Notes.V1.UpdateNoteRequest.note, Notes.V1.Note.name ]` for `{note.name}`.
`template` is the variable's template
(`[ literal "books", wildcard ]` for `{book.name=books/*}`; `[]` for `{name}`).

The value is read from the request's JSON by each field's JSON name. A variable
matching one segment (`{name}`, `{name=*}`) is percent-encoded with `/`
escaped as `%2F`; any other keeps its `/`s. A value absent from the request's
JSON, or `null` there, as under an unset message, is the text of the field's
proto3 default, read from the last descriptor's kind: `""` for a string or
bytes, `false`, `0` for any number, and an enum's zero value's name. Proto3
reads the field as its default, and a server parsing the segment as the
field's type rejects an empty one. The value is not checked against the
template: the server does that.

-}
variable : { fieldPath : List Proto.Field.Descriptor, template : List Segment } -> Segment
variable { fieldPath, template } =
    Internal.Variable (List.map Proto.Field.jsonName fieldPath) template (defaultText fieldPath)


{-| `*`, one path segment, inside a variable's template.
-}
wildcard : Segment
wildcard =
    Internal.Wildcard


{-| `**`, any number of path segments, inside a variable's template.
-}
doubleWildcard : Segment
doubleWildcard =
    Internal.DoubleWildcard


{-| What a request body holds.
-}
type alias Body =
    Internal.Body


{-| No body: every field outside the path is in the query.
-}
noBody : Body
noBody =
    Internal.NoBody


{-| `body: "*"`: the request's JSON without the fields the path holds.
-}
wholeBody : Body
wholeBody =
    Internal.WholeBody


{-| `body: "note"`: the JSON of one top-level message field of the request, by
its descriptor (`Notes.V1.CreateNoteRequest.note`), sent whole even when the
path holds a field inside it. An unset field is sent as `{}`.
-}
bodyField : Proto.Field.Descriptor -> Body
bodyField field =
    Internal.BodyField (Proto.Field.jsonName field)


{-| One query parameter.
-}
type alias Param =
    Internal.Param


{-| A query parameter: one request field, by the path of field descriptors from
the request message down to it (`[ Notes.V1.ListNotesRequest.pageSize ]`). Its
name in the query is the dotted path of proto names (`page_size`,
`filter.visibility`); its value is read from the request's JSON by JSON names.
A JSON array is sent as one parameter per element.

Whether a value is left out follows from the last field: one without presence
(a singular scalar or enum outside any oneof) is left out at its proto3
default, the text [`variable`](#variable) describes; one with presence (a
proto3 `optional` field, a oneof member, a message) is left out only when
unset, and a repeated field only when empty.

-}
param : List Proto.Field.Descriptor -> Param
param fieldPath =
    Internal.Param
        { name = String.join "." (List.map Proto.Field.name fieldPath)
        , path = List.map Proto.Field.jsonName fieldPath
        , zero =
            if hasPresence fieldPath then
                Nothing

            else
                Just (defaultText fieldPath)
        }


{-| Whether the last field of a path is told apart from its default by being
set rather than by its value, or is a list.
-}
hasPresence : List Proto.Field.Descriptor -> Bool
hasPresence fields =
    case last fields of
        Just leaf ->
            case ( Proto.Field.cardinality leaf, Proto.Field.kind leaf, Proto.Field.oneof leaf ) of
                ( CardinalitySingular, KindMessage _, _ ) ->
                    True

                ( CardinalitySingular, _, Nothing ) ->
                    False

                _ ->
                    True

        Nothing ->
            True


{-| The text of the last field's proto3 default as a path or query value: `""`
for a string or bytes, `false`, `0` for any number, and an enum's zero value's
name.
-}
defaultText : List Proto.Field.Descriptor -> String
defaultText fields =
    case Maybe.map Proto.Field.kind (last fields) of
        Just (KindScalar ScalarString) ->
            ""

        Just (KindScalar ScalarBytes) ->
            ""

        Just (KindScalar ScalarBool) ->
            "false"

        Just (KindScalar _) ->
            "0"

        Just (KindEnum enum) ->
            Proto.Enum.values enum
                |> List.head
                |> Maybe.map Proto.EnumValue.name
                |> Maybe.withDefault ""

        Just (KindMessage _) ->
            ""

        Nothing ->
            ""


last : List a -> Maybe a
last list =
    List.head (List.reverse list)
