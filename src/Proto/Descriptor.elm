module Proto.Descriptor exposing
    ( MessageDescriptor, message
    , Field, field, inOneof, withBehavior, withDeprecated
    , Cardinality(..), Kind(..), Scalar(..), Behavior(..)
    , EnumDescriptor, enum, EnumValue, value, withDeprecatedValue
    , MethodDescriptor, method, Idempotency(..)
    )

{-| Descriptors: what the proto says about a message, an enum or a method, as
data. Generated code builds one per type and per method with the functions
here (`Notes.V1.descriptorNote`), and the values of
[`Proto.Message`](Proto-Message), [`Proto.Enum`](Proto-Enum) and
[`Proto.Method`](Proto-Method) carry them.

A descriptor is faithful to the proto, not to the Elm the generator makes of
it: a singular message field is [`Singular`](#Cardinality) of a
[`Message`](#Kind), though Elm holds it as a `Maybe`. Types refer to each
other by full name, never by value, so a message can contain itself; a
[`Registry`](Proto-Registry) resolves the names.

The descriptor types are opaque, built by the functions here and read through
a module per type, named for it: [`Proto.MessageDescriptor`](Proto-MessageDescriptor),
[`Proto.Field`](Proto-Field), [`Proto.EnumDescriptor`](Proto-EnumDescriptor),
[`Proto.EnumValue`](Proto-EnumValue) and
[`Proto.MethodDescriptor`](Proto-MethodDescriptor). Each module names its type
too; the two names are one type. So a later release can
say more about a type, as a new modifier like [`withBehavior`](#withBehavior)
and a new accessor, without breaking code that builds or reads descriptors.
The unions below are public, to match on.

    twoFields : Proto.Descriptor.MessageDescriptor
    twoFields =
        Proto.Descriptor.message "t.Pair"
            [ Proto.Descriptor.field "left" "left" 1 Proto.Descriptor.Singular (Proto.Descriptor.Scalar Proto.Descriptor.Int32)
            , Proto.Descriptor.field "right" "right" 2 Proto.Descriptor.Singular (Proto.Descriptor.Message "t.Pair")
            ]


# Messages

@docs MessageDescriptor, message
@docs Field, field, inOneof, withBehavior, withDeprecated
@docs Cardinality, Kind, Scalar, Behavior


# Enums

@docs EnumDescriptor, enum, EnumValue, value, withDeprecatedValue


# Methods

@docs MethodDescriptor, method, Idempotency

-}

import Proto.Http exposing (Binding)
import Proto.Internal.Descriptor as Internal



-- MESSAGES


{-| A message: its full name, its fields, and the names of its oneofs.
[`Proto.MessageDescriptor`](Proto-MessageDescriptor) reads it.
-}
type alias MessageDescriptor =
    Internal.MessageDescriptor Field


{-| A message of this full name, such as `notes.v1.Note` (or
`notes.v1.Note.Revision` for a nested message), with these fields in
declaration order, the members of its oneofs among them.

Its oneofs are the ones its fields name ([`inOneof`](#inOneof)), in the order
they first appear, so they are not written twice. A proto3 `optional` field's
synthetic oneof is not one of them: such a field is [`Optional`](#Cardinality).

-}
message : String -> List Field -> MessageDescriptor
message typeName fields =
    Internal.MessageDescriptor
        { typeName = typeName
        , fields = fields
        , oneofs = oneofsOf fields
        }


oneofsOf : List Field -> List String
oneofsOf fields =
    List.foldl
        (\(Internal.Field f) seen ->
            case f.oneof of
                Just name ->
                    if List.member name seen then
                        seen

                    else
                        name :: seen

                Nothing ->
                    seen
        )
        []
        fields
        |> List.reverse


{-| A field of a message. [`Proto.Field`](Proto-Field)
reads it.
-}
type alias Field =
    Internal.Field Cardinality Kind Behavior


{-| A field: its proto name (`page_size`), its name in proto3 JSON
(`pageSize`, or the proto's explicit `json_name`), its number, how many values
it holds, and the type of each value (for a map, of each map value).

It is in no oneof, has no [`Behavior`](#Behavior) and is not deprecated until
the modifiers below say otherwise.

-}
field : String -> String -> Int -> Cardinality -> Kind -> Field
field name jsonName number cardinality kind =
    Internal.Field
        { name = name
        , jsonName = jsonName
        , number = number
        , cardinality = cardinality
        , kind = kind
        , oneof = Nothing
        , behavior = []
        , deprecated = False
        }


{-| The field as a member of the oneof of this name.
-}
inOneof : String -> Field -> Field
inOneof oneof (Internal.Field f) =
    Internal.Field { f | oneof = Just oneof }


{-| The field with these `google.api.field_behavior` annotations after any it
has, in the order the proto gives them.
-}
withBehavior : List Behavior -> Field -> Field
withBehavior behavior (Internal.Field f) =
    Internal.Field { f | behavior = f.behavior ++ behavior }


{-| The field as `[deprecated = true]`.
-}
withDeprecated : Field -> Field
withDeprecated (Internal.Field f) =
    Internal.Field { f | deprecated = True }


{-| How many values a field holds:

  - `Singular`: one, without presence unless it is a message or a oneof
    member.
  - `Optional`: one, with presence: a proto3 `optional` field.
  - `Required`: one, which must be present: proto2's `required`. The
    generator reads proto3 alone, so it never gives this today.
  - `Repeated`: a list.
  - `Map`: a map, keyed by this scalar.

-}
type Cardinality
    = Singular
    | Optional
    | Required
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


{-| A field's `google.api.field_behavior` annotation, one constructor per
value of `google.api.FieldBehavior` but its unspecified zero:
`OPTIONAL`, `REQUIRED`, `OUTPUT_ONLY`, `INPUT_ONLY`, `IMMUTABLE`,
`UNORDERED_LIST`, `NON_EMPTY_DEFAULT` and `IDENTIFIER`.

`BehaviorOptional` and `BehaviorRequired` carry a prefix the others do not:
the constructors of this module share one namespace, and
[`Cardinality`](#Cardinality) already has `Optional` and `Required`, which
mean something else (presence on the wire, not an API's contract). The
prefix goes on those two alone so the common `OutputOnly` and `Immutable` stay
short, and `Behavior` stays in this module so generated code needs one import
for its descriptors.

-}
type Behavior
    = BehaviorOptional
    | BehaviorRequired
    | OutputOnly
    | InputOnly
    | Immutable
    | UnorderedList
    | NonEmptyDefault
    | Identifier



-- ENUMS


{-| An enum: its full name and its values.
[`Proto.EnumDescriptor`](Proto-EnumDescriptor) reads it.
-}
type alias EnumDescriptor =
    Internal.EnumDescriptor


{-| An enum of this full name, such as `notes.v1.Visibility`, with these values
in declaration order. An alias (`allow_alias`) is a value of its own, with the
number of the value it aliases.
-}
enum : String -> List EnumValue -> EnumDescriptor
enum typeName values =
    Internal.EnumDescriptor { typeName = typeName, values = values }


{-| One value of an enum.
[`Proto.EnumValue`](Proto-EnumValue) reads it.
-}
type alias EnumValue =
    Internal.EnumValue


{-| A value of this name and number, such as `VISIBILITY_PUBLIC` and `2`, not
deprecated.
-}
value : String -> Int -> EnumValue
value name number =
    Internal.EnumValue { name = name, number = number, deprecated = False }


{-| The value as `[deprecated = true]`. Named apart from
[`withDeprecated`](#withDeprecated), which marks a field, since one function
cannot take both.
-}
withDeprecatedValue : EnumValue -> EnumValue
withDeprecatedValue (Internal.EnumValue v) =
    Internal.EnumValue { v | deprecated = True }



-- METHODS


{-| A method: its service and name, its idempotency, its types and its HTTP
bindings. [`Proto.MethodDescriptor`](Proto-MethodDescriptor) reads it.
-}
type alias MethodDescriptor =
    Internal.MethodDescriptor Idempotency


{-| A method: the full name of its service (`notes.v1.NotesService`), its name
as declared (`GetNote`), its idempotency, the full names of its request and
response types, and its `google.api.http` rule as
[`Proto.Http`](Proto-Http) data, the rule's own binding first and then its
`additional_bindings` in order (`[]` for a method without one).
-}
method : String -> String -> Idempotency -> String -> String -> List Binding -> MethodDescriptor
method service name idempotency input output bindings =
    Internal.MethodDescriptor
        { service = service
        , name = name
        , idempotency = idempotency
        , input = input
        , output = output
        , bindings = bindings
        }


{-| A method's `idempotency_level`, as `google.protobuf.MethodOptions` declares
it:

  - `Unknown`: not declared, so the method may have side effects.
  - `NoSideEffects`: it changes nothing, so Connect may send it as a GET,
    and a retry policy for idempotent calls may retry it.
  - `Idempotent`: calling it again has no further effect, so a retry policy
    for idempotent calls may retry it, but it is never a GET.

-}
type Idempotency
    = Unknown
    | NoSideEffects
    | Idempotent
