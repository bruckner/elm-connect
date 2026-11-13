module Proto.Message exposing
    ( Message, init, initWith, typeName
    , decodeJson, decodeBinary
    , Descriptor, descriptor
    , fullName, typeUrl, fields, fieldNumbered, fieldNamed, oneofs
    )

{-| A message type: its typed value, which holds its full name and its codecs,
and its descriptor, what the proto says about it as data. Generated code gives
one of each per message: the typed value in the package's module
(`Notes.V1.messageNote : Message Note`), the descriptor in a module of the
message's own, beside one value per field (`Notes.V1.Note.descriptor :
Descriptor`, `Notes.V1.Note.title`); and [`Proto.WellKnown`](Proto-WellKnown)
gives one per well-known type.

@docs Message, init, initWith, typeName


# Reading a message

@docs decodeJson, decodeBinary


# Descriptors

@docs Descriptor, descriptor


# Reading a descriptor

@docs fullName, typeUrl, fields, fieldNumbered, fieldNamed, oneofs

-}

import Bytes exposing (Bytes)
import Bytes.Encode
import Json.Decode
import Json.Encode
import Proto.Error
import Proto.Field as Field
import Proto.Internal.Binary
import Proto.Internal.Message as Internal
import Proto.Internal.Registry as Registry exposing (Registry)


{-| A message type whose Elm values are `a`, with both its codecs: proto3 JSON
and protobuf binary. It is what [`Proto.Any`](Proto-Any) packs and unpacks
with, and is opaque: the package site and compiler errors may show it as
`Proto.Internal.Message.Message`, its name inside the package.
-}
type alias Message a =
    Internal.Message a


{-| A message type from its full name, its proto3 JSON encoder and decoder,
and its protobuf binary encoder and decoder, as generated code writes it for
a message that holds no `google.protobuf.Any`:

    messageNote : Proto.Message.Message Note
    messageNote =
        Proto.Message.init "notes.v1.Note" encodeNote decodeNote encodeNoteBytes decodeNoteBytes

The binary decoder is a [`Proto.Binary.Decoder`](Proto-Binary#Decoder), which
the package site may show as `Proto.Internal.Binary.Decoder`.

A message built by `init` is taken at its word that it holds no `Any`:
[`Proto.Any.pack`](Proto-Any#pack) writes its binary straight away, without
looking for an `Any` that only JSON could carry (see [`initWith`](#initWith)).

-}
init : String -> (a -> Json.Encode.Value) -> Json.Decode.Decoder a -> (a -> Bytes.Encode.Encoder) -> Proto.Internal.Binary.Decoder a -> Message a
init name jsonEncoder jsonDecoder binaryEncoder binaryDecoder =
    Internal.Message name
        { encodeJson = \_ value -> Ok (jsonEncoder value)
        , decodeJson = \_ -> jsonDecoder
        , encodeBinary = binaryEncoder
        , decodeBinary = binaryDecoder
        , holdsAny = False
        }


{-| [`init`](#init) for a message that holds a `google.protobuf.Any`, directly
or through its fields: its proto3 JSON codecs take the registry the `Any`
converts through, and its encoder can fail, with a
[`Proto.Error.Error`](Proto-Error#Error): the `Any`'s type is not in the
registry (`UnregisteredType`), or its binary is not that type's message
(`BadBinary`), at any depth.

    messageEnvelope =
        Proto.Message.initWith "notes.v1.Envelope" encodeEnvelopeWith decodeEnvelopeWith encodeEnvelopeBytes decodeEnvelopeBytes

-}
initWith : String -> (Registry -> a -> Result Proto.Error.Error Json.Encode.Value) -> (Registry -> Json.Decode.Decoder a) -> (a -> Bytes.Encode.Encoder) -> Proto.Internal.Binary.Decoder a -> Message a
initWith name jsonEncoder jsonDecoder binaryEncoder binaryDecoder =
    Internal.Message name
        { encodeJson = jsonEncoder
        , decodeJson = jsonDecoder
        , encodeBinary = binaryEncoder
        , decodeBinary = binaryDecoder
        , holdsAny = True
        }


{-| The message's full name, such as `notes.v1.Note`.
-}
typeName : Message a -> String
typeName (Internal.Message name _) =
    name


{-| A message read from proto3 JSON, converting any
`google.protobuf.Any` it holds through the registry:

    Proto.Message.decodeJson Proto.WellKnown.registry Proto.WellKnown.any json

It fails two ways, so it gives a [`Proto.Error.Error`](Proto-Error#Error):

  - `UnregisteredType`, with its type URL, for an `Any` of a type the
    registry has no entry for (a [lenient](Proto-Registry#lenient) registry
    reads one as its JSON alone instead);
  - `BadJson`, with elm/json's error, for anything else that is not the
    message, an `Any` of a registered type whose JSON is not that type
    included.

-}
decodeJson : Registry -> Message a -> Json.Encode.Value -> Result Proto.Error.Error a
decodeJson registry (Internal.Message _ codecs) json =
    case Json.Decode.decodeValue (codecs.decodeJson registry) json of
        Ok value ->
            Ok value

        Err problem ->
            case Registry.unregistered registry problem of
                Just url ->
                    Err (Proto.Error.UnregisteredType url)

                Nothing ->
                    Err (Proto.Error.BadJson problem)


{-| A message read from protobuf binary. An `Any` it holds keeps its binary,
so no registry is needed.

It fails only one way, so it gives that way's own type, the binary report
[`Proto.Error.Binary`](Proto-Error#Binary), as
[`Proto.Binary.decode`](Proto-Binary#decode) does, where
[`decodeJson`](#decodeJson), which fails two ways, gives a
[`Proto.Error.Error`](Proto-Error#Error); `Result.mapError
Proto.Error.BadBinary` lifts one into the other.

-}
decodeBinary : Message a -> Bytes -> Result Proto.Error.Binary a
decodeBinary (Internal.Message _ codecs) bytes =
    Proto.Internal.Binary.run codecs.decodeBinary bytes


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
        { fullName : String
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
        { fullName = name
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
    m.fullName


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


{-| The field of this number, which a [`Proto.Error.Binary`](Proto-Error#Binary)
path names fields by.
-}
fieldNumbered : Int -> Descriptor -> Maybe Field.Descriptor
fieldNumbered number (Descriptor m) =
    List.filter (\field -> Field.number field == number) m.fields |> List.head


{-| The field of this declared name, such as `user_id`.
-}
fieldNamed : String -> Descriptor -> Maybe Field.Descriptor
fieldNamed name (Descriptor m) =
    List.filter (\field -> Field.name field == name) m.fields |> List.head


{-| The names of its oneofs, in the order their first members are declared. A
proto3 `optional` field's synthetic oneof is not one of them.
-}
oneofs : Descriptor -> List String
oneofs (Descriptor m) =
    m.oneofs
