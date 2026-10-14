module Proto.Descriptor exposing
    ( MessageDescriptor, Field, Cardinality(..), Kind(..), Scalar(..)
    , EnumDescriptor
    , MethodDescriptor
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

-}

import Proto.Http exposing (Binding)



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
  - `bindings`: its `google.api.http` rule as [`Proto.Http`](Proto-Http)
    data, the rule's own binding first and then its `additional_bindings`
    in order; `[]` for a method without one.

-}
type alias MethodDescriptor =
    { service : String
    , name : String
    , idempotent : Bool
    , input : String
    , output : String
    , bindings : List Binding
    }
