module Proto.Field exposing
    ( Descriptor, descriptor, inOneof
    , name, jsonName, number, cardinality, kind, oneof
    , Cardinality(..), Kind(..), Scalar(..)
    )

{-| A field of a message, as its message's descriptor
([`Proto.Message.Descriptor`](Proto-Message#Descriptor)) holds it: the
descriptor type, its builder and its readers, and the unions it holds.

Each union's constructors carry the union's name as a prefix
(`CardinalitySingular`, `KindMessage`, `ScalarString`), so all three can be
exposed with `(..)` beside each other and beside the other modules' unions.

@docs Descriptor, descriptor, inOneof


# Reading

@docs name, jsonName, number, cardinality, kind, oneof


# Unions

@docs Cardinality, Kind, Scalar

-}


{-| A field's descriptor. It is opaque, built by [`descriptor`](#descriptor)
and its modifiers and read by the functions below, so that a later release can
say more about a field, as a new modifier and a new reader, without breaking
code that builds or reads one.
-}
type Descriptor
    = Descriptor
        { name : String
        , jsonName : String
        , number : Int
        , cardinality : Cardinality
        , kind : Kind
        , oneof : Maybe String
        }


{-| How many values a field holds:

  - `CardinalitySingular`: one, without presence unless it is a message or a
    oneof member.
  - `CardinalityOptional`: one, with presence: a proto3 `optional` field.
  - `CardinalityRepeated`: a list.
  - `CardinalityMap`: a map, keyed by this scalar.

-}
type Cardinality
    = CardinalitySingular
    | CardinalityOptional
    | CardinalityRepeated
    | CardinalityMap Scalar


{-| The type of a field's values: a scalar, or an enum or a message by its full
name (`google.protobuf.Timestamp` for a well-known type).
-}
type Kind
    = KindScalar Scalar
    | KindEnum String
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


{-| A field: its proto name (`page_size`), its name in proto3 JSON
(`pageSize`, or the proto's explicit `json_name`), its number, how many values
it holds, and the type of each value (for a map, of each map value). It is in
no oneof until [`inOneof`](#inOneof) says otherwise.

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
        }


{-| The field as a member of the oneof of this name.
-}
inOneof : String -> Descriptor -> Descriptor
inOneof oneofName (Descriptor f) =
    Descriptor { f | oneof = Just oneofName }


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
