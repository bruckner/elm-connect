module Proto.Message exposing
    ( Message, message, withBinary, messageBinary
    , encode, decoder, default, toDescriptor, encodeBytes, bytesDecoder
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

@docs Message, message, withBinary, messageBinary


# Reading a typed value

@docs encode, decoder, default, toDescriptor, encodeBytes, bytesDecoder


# Descriptors

@docs Descriptor, descriptor


# Reading a descriptor

@docs typeName, typeUrl, fields, oneofs

-}

import Bytes.Encode
import Json.Decode
import Json.Encode
import Proto.Bytes
import Proto.Field as Field
import Proto.Internal.Binary
import Proto.Internal.Message as Internal


{-| A message type whose Elm values are `a`. It is opaque: built by
[`message`](#message) and read by the functions below. The package site and
compiler errors may show it as `Proto.Internal.Message.Message`, its name
inside the package.
-}
type alias Message a =
    Internal.Message Descriptor a


{-| A message type from its proto3 JSON encoder and decoder, its default (the
value with every field at its proto3 default, which an empty JSON object
decodes to) and its descriptor. Generated code writes:

    messageNote : Proto.Message.Message Note
    messageNote =
        Proto.Message.message encodeNote decodeNote defaultNote Notes.V1.Note.descriptor

-}
message : (a -> Json.Encode.Value) -> Json.Decode.Decoder a -> a -> Descriptor -> Message a
message encodeJson jsonDecoder defaultValue messageDescriptor =
    Internal.Message
        { encode = encodeJson
        , decoder = jsonDecoder
        , default = defaultValue
        , descriptor = messageDescriptor
        , binary = Nothing
        }


{-| The message type with protobuf binary codecs too, as generated code under
`codec=both` writes it:

    messageNote =
        Proto.Message.message encodeNote decodeNote defaultNote Notes.V1.Note.descriptor
            |> Proto.Message.withBinary encodeNoteBytes decodeNoteBytes

The binary decoder is a [`Proto.Binary.Decoder`](Proto-Binary#Decoder), which
the package site may show as `Proto.Internal.Binary.Decoder`.

-}
withBinary : (a -> Bytes.Encode.Encoder) -> Proto.Internal.Binary.Decoder a -> Message a -> Message a
withBinary encodeBinary binaryDecoder (Internal.Message m) =
    Internal.Message { m | binary = Just (binary encodeBinary binaryDecoder) }


{-| A message type with protobuf binary codecs alone, as generated code under
`codec=binary` writes it:

    messageNote =
        Proto.Message.messageBinary encodeNoteBytes decodeNoteBytes defaultNote Notes.V1.Note.descriptor

Its JSON encoder writes `null` and its JSON decoder fails.

-}
messageBinary : (a -> Bytes.Encode.Encoder) -> Proto.Internal.Binary.Decoder a -> a -> Descriptor -> Message a
messageBinary encodeBinary binaryDecoder defaultValue messageDescriptor =
    Internal.Message
        { encode = \_ -> Json.Encode.null
        , decoder = Json.Decode.fail (typeName messageDescriptor ++ " was generated with protobuf binary codecs alone (codec=binary)")
        , default = defaultValue
        , descriptor = messageDescriptor
        , binary = Just (binary encodeBinary binaryDecoder)
        }


{-| The binary codecs, with a value's binary as base64 and back, which an
`Any` holds. They are built here, under `withBinary`, so that a program
without binary codecs carries none of that code.
-}
binary : (a -> Bytes.Encode.Encoder) -> Proto.Internal.Binary.Decoder a -> Internal.Binary a
binary encodeBinary binaryDecoder =
    { encode = encodeBinary
    , decoder = binaryDecoder
    , toBase64 = \value -> Proto.Bytes.toBase64 (Bytes.Encode.encode (encodeBinary value))
    , fromBase64 =
        \base64 ->
            Proto.Bytes.fromBase64 base64
                |> Maybe.andThen (Proto.Internal.Binary.run binaryDecoder)
    }


{-| The protobuf binary encoder, when the message type has one.
-}
encodeBytes : Message a -> Maybe (a -> Bytes.Encode.Encoder)
encodeBytes (Internal.Message m) =
    Maybe.map .encode m.binary


{-| The protobuf binary decoder, when the message type has one.
-}
bytesDecoder : Message a -> Maybe (Proto.Internal.Binary.Decoder a)
bytesDecoder (Internal.Message m) =
    Maybe.map .decoder m.binary


{-| A value as proto3 JSON.
-}
encode : Message a -> a -> Json.Encode.Value
encode (Internal.Message m) =
    m.encode


{-| The proto3 JSON decoder.
-}
decoder : Message a -> Json.Decode.Decoder a
decoder (Internal.Message m) =
    m.decoder


{-| The value with every field at its proto3 default.
-}
default : Message a -> a
default (Internal.Message m) =
    m.default


{-| What the proto says about the message, read by the functions below.
-}
toDescriptor : Message a -> Descriptor
toDescriptor (Internal.Message m) =
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
