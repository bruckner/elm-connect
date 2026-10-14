module Proto.Message exposing (Message, typeName, typeUrl)

{-| A message type as a value: its proto3 JSON codecs, its default and its
descriptor, together. Generated code gives one per message
(`Notes.V1.messageNote : Message Note`), and
[`Proto.WellKnown`](Proto-WellKnown) one per well-known type.

@docs Message, typeName, typeUrl

-}

import Json.Decode
import Json.Encode
import Proto.Descriptor exposing (MessageDescriptor)


{-| A message type whose Elm values are `a`:

  - `encodeJson` and `jsonDecoder`: its proto3 JSON codecs, named for their
    encoding so that binary codecs can sit beside them.
  - `default`: the value with every field at its proto3 default, which an
    empty JSON object decodes to.
  - `descriptor`: what the proto says about it.

-}
type alias Message a =
    { encodeJson : a -> Json.Encode.Value
    , jsonDecoder : Json.Decode.Decoder a
    , default : a
    , descriptor : MessageDescriptor
    }


{-| The message's full name, such as `notes.v1.Note`.
-}
typeName : Message a -> String
typeName message =
    message.descriptor.typeName


{-| The type URL `google.protobuf.Any` names the message by:
`type.googleapis.com/notes.v1.Note`.
-}
typeUrl : Message a -> String
typeUrl message =
    "type.googleapis.com/" ++ typeName message
