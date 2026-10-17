module Proto.Message exposing
    ( Message, message
    , encode, decoder, default, descriptor
    , typeName, typeUrl
    )

{-| A message type as a value: its proto3 JSON codecs, its default and its
descriptor, together. Generated code gives one per message
(`Notes.V1.messageNote : Message Note`), and
[`Proto.WellKnown`](Proto-WellKnown) one per well-known type.

@docs Message, message


# Reading

@docs encode, decoder, default, descriptor
@docs typeName, typeUrl

-}

import Json.Decode
import Json.Encode
import Proto.Descriptor exposing (MessageDescriptor)


{-| A message type whose Elm values are `a`. It is opaque: built by
[`message`](#message) and read by the functions below, so that what it carries
can grow (another encoding's codecs, say) as a new modifier, without breaking
code generated before.
-}
type Message a
    = Message
        { encode : a -> Json.Encode.Value
        , decoder : Json.Decode.Decoder a
        , default : a
        , descriptor : MessageDescriptor
        }


{-| A message type from its proto3 JSON encoder and decoder, its default (the
value with every field at its proto3 default, which an empty JSON object
decodes to) and its descriptor. Generated code writes:

    messageNote : Proto.Message.Message Note
    messageNote =
        Proto.Message.message encodeNote decodeNote defaultNote descriptorNote

-}
message : (a -> Json.Encode.Value) -> Json.Decode.Decoder a -> a -> MessageDescriptor -> Message a
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


{-| What the proto says about the message.
-}
descriptor : Message a -> MessageDescriptor
descriptor (Message m) =
    m.descriptor


{-| The message's full name, such as `notes.v1.Note`.
-}
typeName : Message a -> String
typeName (Message m) =
    m.descriptor.typeName


{-| The type URL `google.protobuf.Any` names the message by:
`type.googleapis.com/notes.v1.Note`.
-}
typeUrl : Message a -> String
typeUrl message_ =
    "type.googleapis.com/" ++ typeName message_
