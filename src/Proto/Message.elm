module Proto.Message exposing
    ( Message, initJson, initProto, typeName
    , Descriptor, descriptor
    , fullName, typeUrl, fields, oneofs
    )

{-| A message type: its typed value, which holds its full name and its codecs,
and its descriptor, what the proto says about it as data. Generated code gives
one of each per message: the typed value in the package's module
(`Notes.V1.messageNote : Message Rpc.Json Note`), the descriptor in a module of
the message's own, beside one value per field
(`Notes.V1.Note.descriptor : Descriptor`, `Notes.V1.Note.title`); and
[`Proto.WellKnown`](Proto-WellKnown) gives one per well-known type and codec.

@docs Message, initJson, initProto, typeName


# Descriptors

@docs Descriptor, descriptor


# Reading a descriptor

@docs fullName, typeUrl, fields, oneofs

-}

import Bytes.Encode
import Json.Decode
import Json.Encode
import Proto.Codec exposing (Json, Proto)
import Proto.Field as Field
import Proto.Internal.Binary
import Proto.Internal.Message as Internal


{-| A message type whose Elm values are `a`, with the codecs `codec` names:
[`Proto.Codec.Json`](Proto-Codec#Json), proto3 JSON, or
[`Proto.Codec.Proto`](Proto-Codec#Proto), protobuf binary. Code generated with
`codec=json` gives a `Message Json a`, with `codec=proto` or `codec=both` a
`Message Proto a`. It is what [`Proto.Any`](Proto-Any) packs and unpacks
with, and is opaque: the package site and compiler errors may show it as
`Proto.Internal.Message.Message`, its name inside the package.
-}
type alias Message codec a =
    Internal.Message codec a


{-| A message type from its full name and its proto3 JSON encoder and decoder,
as generated code under `codec=json` writes it:

    messageNote : Proto.Message.Message Rpc.Json Note
    messageNote =
        Proto.Message.initJson "notes.v1.Note" encodeNote decodeNote

-}
initJson : String -> (a -> Json.Encode.Value) -> Json.Decode.Decoder a -> Message Json a
initJson name encode decoder =
    Internal.Message name (Internal.JsonCodecs encode decoder)


{-| A message type from its full name and its protobuf binary encoder and
decoder, as generated code under `codec=proto` and `codec=both` writes it:

    messageNote =
        Proto.Message.initProto "notes.v1.Note" encodeNoteBytes decodeNoteBytes

The binary decoder is a [`Proto.Binary.Decoder`](Proto-Binary#Decoder), which
the package site may show as `Proto.Internal.Binary.Decoder`.

-}
initProto : String -> (a -> Bytes.Encode.Encoder) -> Proto.Internal.Binary.Decoder a -> Message Proto a
initProto name encode decoder =
    Internal.Message name (Internal.ProtoCodecs encode decoder)


{-| The message's full name, such as `notes.v1.Note`.
-}
typeName : Message codec a -> String
typeName (Internal.Message name _) =
    name


{-| A message type's descriptor: its full name, its fields, and the names of
its oneofs. It is opaque, built by [`descriptor`](#descriptor) and read by the
functions below.

A descriptor is faithful to the proto, not to the Elm the generator makes of
it: a singular message field is
[`CardinalitySingular`](Proto-Field#Cardinality) of a
[`KindMessage`](Proto-Field#Kind), though Elm holds it as a `Maybe`. A field
refers to a message by full name, never by value, so a message can contain
itself; [`Proto.Descriptors`](Proto-Descriptors) resolves the names.

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
descriptor name messageFields =
    Descriptor
        { typeName = name
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
fullName : Descriptor -> String
fullName (Descriptor m) =
    m.typeName


{-| The type URL `google.protobuf.Any` names the message by:
`type.googleapis.com/notes.v1.Note`.
-}
typeUrl : Descriptor -> String
typeUrl messageDescriptor =
    "type.googleapis.com/" ++ fullName messageDescriptor


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
