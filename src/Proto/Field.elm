module Proto.Field exposing
    ( Descriptor, descriptor, inOneof, withBehavior, withDeprecated
    , name, jsonName, number, cardinality, kind, oneof
    , behavior, deprecated
    , Cardinality(..), Kind(..), Scalar(..), Behavior(..)
    )

{-| A field of a message, as its message's descriptor
([`Proto.Message.Descriptor`](Proto-Message#Descriptor)) holds it: the
descriptor type, its builder and its readers, and the unions it holds.
Generated code gives each field's descriptor a value of its own, in the
module of its message's descriptor (`Notes.V1.Note.title`).

Each union's constructors carry the union's name as a prefix
(`CardinalitySingular`, `KindMessage`, `ScalarString`, `BehaviorRequired`), so
all four can be exposed with `(..)` beside each other and beside the other
modules' unions: `CardinalityRequired` and `BehaviorRequired` mean different
things.

@docs Descriptor, descriptor, inOneof, withBehavior, withDeprecated


# Reading

@docs name, jsonName, number, cardinality, kind, oneof


# Annotations

@docs behavior, deprecated


# Unions

@docs Cardinality, Kind, Scalar, Behavior

-}

import Proto.Enum


{-| A field's descriptor. It is opaque, built by [`descriptor`](#descriptor)
and its modifiers and read by the functions below.
-}
type Descriptor
    = Descriptor
        { name : String
        , jsonName : String
        , number : Int
        , cardinality : Cardinality
        , kind : Kind
        , oneof : Maybe String
        , behavior : List Behavior
        , deprecated : Bool
        }


{-| How many values a field holds:

  - `CardinalitySingular`: one, without presence unless it is a message or a
    oneof member.
  - `CardinalityOptional`: one, with presence: a proto3 `optional` field.
  - `CardinalityRequired`: one, which must be present: proto2's `required`.
    The generator reads proto3 alone, so it never gives this today.
  - `CardinalityRepeated`: a list.
  - `CardinalityMap`: a map, keyed by this scalar.

-}
type Cardinality
    = CardinalitySingular
    | CardinalityOptional
    | CardinalityRequired
    | CardinalityRepeated
    | CardinalityMap Scalar


{-| The type of a field's values: a scalar, an enum by its descriptor, or a
message by its full name (`google.protobuf.Timestamp` for a well-known type).

An enum's values, its zero value first, can be read from the field alone
([`Proto.Enum.values`](Proto-Enum#values)). A message's fields are found by
resolving its name in a [`Proto.Registry`](Proto-Registry).

-}
type Kind
    = KindScalar Scalar
    | KindEnum Proto.Enum.Descriptor
    | KindMessage String


{-| The fifteen proto scalar types.
-}
type Scalar
    = ScalarDouble
    | ScalarFloat
    | ScalarInt32
    | ScalarInt64
    | ScalarUint32
    | ScalarUint64
    | ScalarSint32
    | ScalarSint64
    | ScalarFixed32
    | ScalarFixed64
    | ScalarSfixed32
    | ScalarSfixed64
    | ScalarBool
    | ScalarString
    | ScalarBytes


{-| One value of `google.api.FieldBehavior` but its unspecified zero, what an
API says about a field's contract (not its presence on the wire):

  - `BehaviorOptional`: the field may be left out, said for emphasis.
  - `BehaviorRequired`: a request must set it.
  - `BehaviorOutputOnly`: the server sets it; a request's value is ignored.
  - `BehaviorInputOnly`: a request sets it; responses leave it out.
  - `BehaviorImmutable`: it may be set once, when the resource is created.
  - `BehaviorUnorderedList`: a repeated field whose order the server may
    change.
  - `BehaviorNonEmptyDefault`: the server gives a value of its own when it is
    unset.
  - `BehaviorIdentifier`: the field is the resource's name.
  - `BehaviorUnknown`: the number of a `google.api.FieldBehavior` value this
    release does not name. A later release may name it; until then, matching
    on the number is how an application reads that behavior.

-}
type Behavior
    = BehaviorOptional
    | BehaviorRequired
    | BehaviorOutputOnly
    | BehaviorInputOnly
    | BehaviorImmutable
    | BehaviorUnorderedList
    | BehaviorNonEmptyDefault
    | BehaviorIdentifier
    | BehaviorUnknown Int


{-| A field: its proto name (`page_size`), its name in proto3 JSON
(`pageSize`, or the proto's explicit `json_name`), its number, how many values
it holds, and the type of each value (for a map, of each map value). It is in
no oneof, has no [`Behavior`](#Behavior) and is not deprecated until the
modifiers below say otherwise.

    Proto.Field.descriptor "title" "title" 2 Proto.Field.CardinalitySingular (Proto.Field.KindScalar Proto.Field.ScalarString)

-}
descriptor : String -> String -> Int -> Cardinality -> Kind -> Descriptor
descriptor protoName json fieldNumber howMany valueKind =
    Descriptor
        { name = protoName
        , jsonName = json
        , number = fieldNumber
        , cardinality = howMany
        , kind = valueKind
        , oneof = Nothing
        , behavior = []
        , deprecated = False
        }


{-| The field as a member of the oneof of this name.
-}
inOneof : String -> Descriptor -> Descriptor
inOneof oneofName (Descriptor f) =
    Descriptor { f | oneof = Just oneofName }


{-| The field with these `google.api.field_behavior` annotations after any it
has, in the order the proto gives them.
-}
withBehavior : List Behavior -> Descriptor -> Descriptor
withBehavior annotations (Descriptor f) =
    Descriptor { f | behavior = f.behavior ++ annotations }


{-| The field as `[deprecated = true]`.
-}
withDeprecated : Descriptor -> Descriptor
withDeprecated (Descriptor f) =
    Descriptor { f | deprecated = True }


{-| Its proto name, such as `page_size`: the name a field mask's paths use.
-}
name : Descriptor -> String
name (Descriptor f) =
    f.name


{-| Its name in proto3 JSON, such as `pageSize`; an explicit `json_name` when
the proto gives one.
-}
jsonName : Descriptor -> String
jsonName (Descriptor f) =
    f.jsonName


{-| Its field number.
-}
number : Descriptor -> Int
number (Descriptor f) =
    f.number


{-| How many values it holds.
-}
cardinality : Descriptor -> Cardinality
cardinality (Descriptor f) =
    f.cardinality


{-| The type of each value; for a map, of each map value.
-}
kind : Descriptor -> Kind
kind (Descriptor f) =
    f.kind


{-| The name of the oneof it is a member of, if any.
-}
oneof : Descriptor -> Maybe String
oneof (Descriptor f) =
    f.oneof


{-| Its `google.api.field_behavior` annotations, in the order the proto gives
them; `[]` for a field without any.
-}
behavior : Descriptor -> List Behavior
behavior (Descriptor f) =
    f.behavior


{-| Whether the proto marks it `[deprecated = true]`.
-}
deprecated : Descriptor -> Bool
deprecated (Descriptor f) =
    f.deprecated
