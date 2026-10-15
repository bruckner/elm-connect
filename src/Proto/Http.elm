module Proto.Http exposing
    ( Binding, binding
    , Segment, literal, variable, wildcard, doubleWildcard
    , Body, noBody, wholeBody, bodyField
    , Param, param
    )

{-| A method's `google.api.http` rule as data: its bindings, each a verb, a
path template, a body and query parameters. The generator parses the rule
and writes these into the method's [descriptor](Proto-Descriptor#MethodDescriptor);
application code only passes them along, and `Rpc` builds the request from
them under the Transcode transport.

@docs Binding, binding
@docs Segment, literal, variable, wildcard, doubleWildcard
@docs Body, noBody, wholeBody, bodyField
@docs Param, param

-}

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
  - `responseBody`: the JSON name of the response field the answer holds, if it
    is not the whole response.
  - `query`: the query parameters, every request field outside the path and the
    body.

-}
binding :
    { method : String
    , path : List Segment
    , customVerb : Maybe String
    , body : Body
    , responseBody : Maybe String
    , query : List Param
    }
    -> Binding
binding =
    Internal.Binding


{-| One segment of a path template.
-}
type alias Segment =
    Internal.Segment


{-| Literal text, written as it is.
-}
literal : String -> Segment
literal =
    Internal.Literal


{-| A request field's value: the field's JSON path (`[ "book", "name" ]`), the
variable's template (`[ literal "books", wildcard ]` for `{book.name=books/*}`;
`[]` for `{name}`), and the text of the field's proto3 default (`"0"`, `""`,
`"false"`, an enum's zero name). A variable matching one segment (`{name}`,
`{name=*}`) is percent-encoded with `/` escaped as `%2F`; any other keeps its
`/`s. A value absent from the request's JSON, or `null` there, as under an
unset message, is the default: proto3 reads the field as its default, and a
server parsing the segment as the field's type rejects an empty one. The value
is not checked against the template: the server does that.
-}
variable : List String -> List Segment -> String -> Segment
variable =
    Internal.Variable


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


{-| `body: "note"`: the JSON of one top-level field, by its JSON name, sent
whole even when the path holds a field inside it. An unset field is sent as
`{}`.
-}
bodyField : String -> Body
bodyField =
    Internal.BodyField


{-| One query parameter.
-}
type alias Param =
    Internal.Param


{-| A query parameter: its name (the dotted proto field path, `sub.subfield`),
the field's JSON path (`[ "sub", "subfield" ]`), and the text of the value at
which it is left out (`Just "0"`, `Just ""`, an enum's zero name), or
`Nothing` to leave it out only when the field is unset. A JSON array is sent
as one parameter per element.
-}
param : String -> List String -> Maybe String -> Param
param name path zero =
    Internal.Param { name = name, path = path, zero = zero }
