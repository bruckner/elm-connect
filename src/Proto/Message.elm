module Proto.Message exposing
    ( Message, message
    , encode, decoder, default, toDescriptor
    , Descriptor, descriptor
    , typeName, typeUrl, fields, oneofs
    )

{-| A message type: its typed value, which holds its proto3 JSON codecs, its
default and its descriptor together, and its descriptor, what the proto says
about it as data. Generated code gives one of each per message: the typed
value in the package's module (`Notes.V1.messageNote : Message Note`), the
descriptor in a module of the message's own, beside one value per field
(`Notes.V1.Note.descriptor : Descriptor`, `Notes.V1.Note.title`); and
[`Proto.WellKnown`](Proto-WellKnown) gives one per well-known type.

@docs Message, message


# Reading a typed value

@docs encode, decoder, default, toDescriptor


# Descriptors

@docs Descriptor, descriptor


# Reading a descriptor

@docs typeName, typeUrl, fields, oneofs

-}

import Json.Decode
import Json.Encode
import Proto.Field as Field


{-| A message type whose Elm values are `a`. It is opaque: built by
[`message`](#message) and read by the functions below.
-}
type Message a
    = Message
        { encode : a -> Json.Encode.Value
        , decoder : Json.Decode.Decoder a
        , default : a
        , descriptor : Descriptor
        }


{-| A message type from its proto3 JSON encoder and decoder, its default (the
value with every field at its proto3 default, which an empty JSON object
decodes to) and its descriptor. Generated code writes:

    messageNote : Proto.Message.Message Note
    messageNote =
        Proto.Message.message encodeNote decodeNote defaultNote Notes.V1.Note.descriptor

-}
message : (a -> Json.Encode.Value) -> Json.Decode.Decoder a -> a -> Descriptor -> Message a
message encodeJson jsonDecoder defaultValue messageDescriptor =
    Message
        { encode = encodeJson
        , decoder = jsonDecoder
        , default = defaultValue
        , descriptor = messageDescriptor
        }


{-| A value as proto3 JSON.
-}
encode : Message a -> a -> Json.Encode.Value
encode (Message m) =
    m.encode


{-| The proto3 JSON decoder.
-}
decoder : Message a -> Json.Decode.Decoder a
decoder (Message m) =
    m.decoder


{-| The value with every field at its proto3 default.
-}
default : Message a -> a
default (Message m) =
    m.default


{-| What the proto says about the message, read by the functions below.
-}
toDescriptor : Message a -> Descriptor
toDescriptor (Message m) =
    m.descriptor


{-| A message type's descriptor: its full name, its fields, and the names of
its oneofs. It is opaque, built by [`descriptor`](#descriptor) and read by the
functions below.

A descriptor is faithful to the proto, not to the Elm the generator makes of
it: a singular message field is
[`CardinalitySingular`](Proto-Field#Cardinality) of a
[`KindMessage`](Proto-Field#Kind), though Elm holds it as a `Maybe`. A field
refers to a message by full name, never by value, so a message can contain
itself; a [`Registry`](Proto-Registry) resolves the names.

    import Proto.Field
    import Proto.Message

    Proto.Message.fields Notes.V1.Note.descriptor
        |> List.map Proto.Field.name
    --> [ "name", "title", … ]

-}
type Descriptor
    = Descriptor
        { typeName : String
        , fields : List Field.Descriptor
        , oneofs : List String
        }


{-| A message of this full name, such as `notes.v1.Note` (or
`notes.v1.Note.Revision` for a nested message), with these fields in
declaration order, the members of its oneofs among them:

    Proto.Message.descriptor "t.Pair"
        [ Proto.Field.descriptor "left" "left" 1 Proto.Field.CardinalitySingular (Proto.Field.KindScalar Proto.Field.ScalarInt32)
        , Proto.Field.descriptor "right" "right" 2 Proto.Field.CardinalitySingular (Proto.Field.KindMessage "t.Pair")
        ]

Its oneofs are the ones its fields name
([`Proto.Field.inOneof`](Proto-Field#inOneof)), in the order they first
appear, so they are not written twice. A proto3 `optional` field's synthetic
oneof is not one of them: such a field is
[`CardinalityOptional`](Proto-Field#Cardinality).

-}
descriptor : String -> List Field.Descriptor -> Descriptor
descriptor fullName messageFields =
    Descriptor
        { typeName = fullName
        , fields = messageFields
        , oneofs = oneofsOf messageFields
        }


oneofsOf : List Field.Descriptor -> List String
oneofsOf messageFields =
    List.foldl
        (\f seen ->
            case Field.oneof f of
                Just oneofName ->
                    if List.member oneofName seen then
                        seen

                    else
                        oneofName :: seen

                Nothing ->
                    seen
        )
        []
        messageFields
        |> List.reverse


{-| The message's full name, such as `notes.v1.Note`, or
`notes.v1.Note.Revision` for a nested message.
-}
typeName : Descriptor -> String
typeName (Descriptor m) =
    m.typeName


{-| The type URL `google.protobuf.Any` names the message by:
`type.googleapis.com/notes.v1.Note`.
-}
typeUrl : Descriptor -> String
typeUrl messageDescriptor =
    "type.googleapis.com/" ++ typeName messageDescriptor


{-| Every field in declaration order, the members of its oneofs among them.
-}
fields : Descriptor -> List Field.Descriptor
fields (Descriptor m) =
    m.fields


{-| The names of its oneofs, in the order their first members are declared. A
proto3 `optional` field's synthetic oneof is not one of them.
-}
oneofs : Descriptor -> List String
oneofs (Descriptor m) =
    m.oneofs
