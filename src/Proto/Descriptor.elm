module Proto.Descriptor exposing
    ( MessageDescriptor, Field, Cardinality(..), Kind(..), Scalar(..)
    , EnumDescriptor
    , MethodDescriptor
    , Binding, binding
    , Segment, literal, variable, wildcard, doubleWildcard
    , Body, noBody, wholeBody, bodyField
    , Param, param
    )

{-| Descriptors: what the proto says about a message, an enum or a method, as
plain data. Generated code writes one per type and per method, and the typed
records of [`Proto.Message`](Proto-Message), [`Proto.Enum`](Proto-Enum) and
[`Proto.Method`](Proto-Method) carry them in their `descriptor` field.

A descriptor is faithful to the proto, not to the Elm the generator makes of
it: a singular message field is [`Singular`](#Cardinality) of a
[`Message`](#Kind), though Elm holds it as a `Maybe`. Types refer to each
other by full name, never by value, so a message can contain itself; a
[`Registry`](Proto-Registry) resolves the names.


# Messages

@docs MessageDescriptor, Field, Cardinality, Kind, Scalar


# Enums

@docs EnumDescriptor


# Methods

@docs MethodDescriptor


# HTTP bindings

A method's `google.api.http` rule, parsed by the generator and written as
data. Generated code builds these; application code only passes them along.

@docs Binding, binding
@docs Segment, literal, variable, wildcard, doubleWildcard
@docs Body, noBody, wholeBody, bodyField
@docs Param, param

-}

import Proto.Internal.Binding as Internal



-- MESSAGES


{-| A message:

  - `typeName`: its full name, such as `notes.v1.Note`, or
    `notes.v1.Note.Revision` for a nested message.
  - `fields`: every field in declaration order, the members of its oneofs
    among them.
  - `oneofs`: the names of its oneofs in declaration order. A proto3
    `optional` field's synthetic oneof is not one of them.

-}
type alias MessageDescriptor =
    { typeName : String
    , fields : List Field
    , oneofs : List String
    }


{-| A field:

  - `name`: its proto name, such as `page_size`.
  - `jsonName`: its name in proto3 JSON, such as `pageSize`; an explicit
    `json_name` when the proto gives one.
  - `number`: its field number.
  - `cardinality`: how many values it holds.
  - `kind`: the type of each value; for a map, of each map value.
  - `oneof`: the name of the oneof it is a member of, if any.

-}
type alias Field =
    { name : String
    , jsonName : String
    , number : Int
    , cardinality : Cardinality
    , kind : Kind
    , oneof : Maybe String
    }


{-| How many values a field holds:

  - `Singular`: one, without presence unless it is a message or a oneof
    member.
  - `Optional`: one, with presence: a proto3 `optional` field.
  - `Repeated`: a list.
  - `Map`: a map, keyed by this scalar.

-}
type Cardinality
    = Singular
    | Optional
    | Repeated
    | Map Scalar


{-| The type of a field's values: a scalar, or an enum or a message by its full
name (`google.protobuf.Timestamp` for a well-known type).
-}
type Kind
    = Scalar Scalar
    | Enum String
    | Message String


{-| The fifteen proto scalar types.
-}
type Scalar
    = Double
    | Float
    | Int32
    | Int64
    | Uint32
    | Uint64
    | Sint32
    | Sint64
    | Fixed32
    | Fixed64
    | Sfixed32
    | Sfixed64
    | Bool
    | String
    | Bytes



-- ENUMS


{-| An enum:

  - `typeName`: its full name, such as `notes.v1.Visibility`.
  - `values`: every value in declaration order. An alias (`allow_alias`) is
    an entry of its own, with the number of the value it aliases.

-}
type alias EnumDescriptor =
    { typeName : String
    , values : List { name : String, number : Int }
    }



-- METHODS


{-| A method:

  - `service`: the full name of its service, such as `notes.v1.NotesService`.
  - `name`: the method name as declared, such as `GetNote`.
  - `idempotent`: whether the proto declares
    `idempotency_level = NO_SIDE_EFFECTS`, which lets Connect send it as a GET
    and a retry policy retry it.
  - `input` and `output`: the full names of its request and response types.
  - `bindings`: its `google.api.http` rule, the rule's own binding first and
    then its `additional_bindings` in order; `[]` for a method without one.

-}
type alias MethodDescriptor =
    { service : String
    , name : String
    , idempotent : Bool
    , input : String
    , output : String
    , bindings : List Binding
    }



-- HTTP BINDINGS


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


{-| A request field's value: the field's JSON path (`[ "book", "name" ]`), and
the variable's template (`[ literal "books", wildcard ]` for
`{book.name=books/*}`; `[]` for `{name}`). A variable matching one segment
(`{name}`, `{name=*}`) is percent-encoded with `/` escaped as `%2F`; any other
keeps its `/`s. An absent value is the empty string. The value is not checked
against the template: the server does that.
-}
variable : List String -> List Segment -> Segment
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
