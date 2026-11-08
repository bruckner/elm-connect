module Proto.Registry exposing
    ( Registry, empty, union, unionAll, wellKnown
    , withCodecs, toJson, toBytes
    , fromDescriptors
    )

{-| The table an [`Any`](Proto-Any#Any) resolves through: each message's codecs
by full name, so that an `Any` holding a message's protobuf binary can be
written as proto3 JSON and read back from it. Code generated with
`codec=both` gives each package one, `registry` (`Notes.V1.registry`): the
codecs of the package's messages, its imports' registries and the well-known
types it holds. Its JSON codecs of a message holding an `Any` take a registry
(`Notes.V1.encodeNoteWith`, `Notes.V1.decodeNoteWith`), and its calls use
the package's, or the client's ([`Rpc.withRegistry`](Rpc#withRegistry)).

A registry holds no descriptors; those are
[`Proto.Descriptors`](Proto-Descriptors). The package site may show the type
as `Proto.Internal.Registry.Registry`, its name inside the package.

@docs Registry, empty, union, unionAll, wellKnown


# Codecs

@docs withCodecs, toJson, toBytes


# From descriptors

@docs fromDescriptors

-}

import Bytes exposing (Bytes)
import Bytes.Encode
import Dict
import Json.Decode exposing (Decoder)
import Json.Encode exposing (Value)
import Proto.Any exposing (Problem)
import Proto.Binary
import Proto.Descriptors exposing (Descriptors)
import Proto.Internal.Dynamic as Dynamic
import Proto.Internal.Registry as Internal
import Proto.Json


{-| Messages' codecs by full name. A registry holds functions, so `==` on it
fails at run time.
-}
type alias Registry =
    Internal.Registry


{-| The registry with nothing in it.
-}
empty : Registry
empty =
    Internal.Registry Dict.empty


{-| Both registries' entries. Of two for one name, the left one's is kept.
-}
union : Registry -> Registry -> Registry
union (Internal.Registry left) (Internal.Registry right) =
    Internal.Registry (Dict.union left right)


{-| Every registry's entries. Of two for one name, the earlier one's is kept.
-}
unionAll : List Registry -> Registry
unionAll registries =
    List.foldr union empty registries


{-| The registry with a message's codecs too, by its full name: its proto3
JSON decoder and encoder, each given the registry it is used through, and
its protobuf binary encoder and decoder. Of two entries for one name, the
later is kept.

    Proto.Registry.empty
        |> Proto.Registry.withCodecs "notes.v1.Note"
            Notes.V1.decodeNoteWith
            Notes.V1.encodeNoteBytes
            Notes.V1.decodeNoteBytes
            Notes.V1.encodeNoteWith

A message holding no `Any` has codecs that take no registry, and goes in
with `\_ -> Notes.V1.decodeNote` and `\_ -> Ok << Notes.V1.encodeNote`.

-}
withCodecs : String -> (Registry -> Decoder a) -> (a -> Bytes.Encode.Encoder) -> Proto.Binary.Decoder a -> (Registry -> a -> Result Problem Value) -> Registry -> Registry
withCodecs typeName decoder encodeBinary binaryDecoder encode (Internal.Registry entries) =
    let
        entry =
            { toJson =
                \registry binary ->
                    Proto.Binary.decode binaryDecoder binary
                        |> Maybe.andThen (encode registry >> Result.toMaybe)
            , toBytes =
                \registry json ->
                    Json.Decode.decodeValue (decoder registry) json
                        |> Result.toMaybe
                        |> Maybe.map (encodeBinary >> Bytes.Encode.encode)
            }
    in
    Internal.Registry (Dict.insert typeName entry entries)


{-| A message's proto3 JSON from its protobuf binary, by its full name:
`Nothing` when the registry has no entry for it, the binary is not the
message, or the message holds an `Any` of a type the registry has no entry
for.
-}
toJson : Registry -> String -> Bytes -> Maybe Value
toJson =
    Internal.toJson


{-| A message's protobuf binary from its proto3 JSON, by its full name:
`Nothing` when the registry has no entry for it, or the JSON is not the
message.
-}
toBytes : Registry -> String -> Value -> Maybe Bytes
toBytes =
    Internal.toBytes


{-| The well-known message types: `google.protobuf.Any`, `Timestamp`,
`Duration`, `FieldMask`, `Empty`, `Struct`, `Value`, `ListValue` and the
wrappers.
-}
wellKnown : Registry
wellKnown =
    empty
        |> total "google.protobuf.Timestamp" Proto.Json.timestamp Proto.Json.encodeTimestamp Proto.Binary.timestamp
        |> total "google.protobuf.Duration" Proto.Json.duration Proto.Json.encodeDuration Proto.Binary.duration
        |> total "google.protobuf.FieldMask" Proto.Json.fieldMask Proto.Json.encodeFieldMask Proto.Binary.fieldMask
        |> total "google.protobuf.Empty" Proto.Json.empty Proto.Json.encodeEmpty Proto.Binary.empty
        |> total "google.protobuf.Struct" Proto.Json.struct Proto.Json.encodeStruct Proto.Binary.struct
        |> total "google.protobuf.Value" Json.Decode.value identity Proto.Binary.value
        |> total "google.protobuf.ListValue" Proto.Json.listValue Proto.Json.encodeListValue Proto.Binary.listValue
        |> total "google.protobuf.DoubleValue" Proto.Json.float Proto.Json.encodeFloat Proto.Binary.doubleValue
        |> total "google.protobuf.FloatValue" Proto.Json.float32 Proto.Json.encodeFloat Proto.Binary.floatValue
        |> total "google.protobuf.Int64Value" Proto.Json.int64 Proto.Json.encodeInt64 Proto.Binary.int64Value
        |> total "google.protobuf.UInt64Value" Proto.Json.uint64 Proto.Json.encodeInt64 Proto.Binary.uint64Value
        |> total "google.protobuf.Int32Value" Proto.Json.int32 Json.Encode.int Proto.Binary.int32Value
        |> total "google.protobuf.UInt32Value" Proto.Json.uint32 Json.Encode.int Proto.Binary.uint32Value
        |> total "google.protobuf.BoolValue" Json.Decode.bool Json.Encode.bool Proto.Binary.boolValue
        |> total "google.protobuf.StringValue" Proto.Json.string Json.Encode.string Proto.Binary.stringValue
        |> total "google.protobuf.BytesValue" Proto.Json.bytes Proto.Json.encodeBytes Proto.Binary.bytesValue
        |> withCodecs "google.protobuf.Any"
            Proto.Json.anyWith
            (Proto.Binary.messageEncoder Proto.Binary.any)
            (Proto.Binary.messageDecoder Proto.Binary.any)
            Proto.Json.encodeAnyWith


{-| An entry of codecs that hold no `Any`.
-}
total : String -> Decoder a -> (a -> Value) -> Proto.Binary.Codec a -> Registry -> Registry
total typeName decoder encode codec =
    withCodecs typeName
        (\_ -> decoder)
        (Proto.Binary.messageEncoder codec)
        (Proto.Binary.messageDecoder codec)
        (\_ -> encode >> Ok)


{-| A registry of every message the descriptors hold, converting each by
walking its descriptor rather than through generated codecs. An `Any` a
message holds converts through the registry the entry is called through, so
a union with a codec registry serves both. The descriptors must hold every
type a converted message's fields refer to; a package's generated
`descriptors` holds its imports' and the well-known types.

    Proto.Registry.fromDescriptors Notes.V1.descriptors

-}
fromDescriptors : Descriptors -> Registry
fromDescriptors descriptors =
    let
        table =
            Dynamic.compile descriptors
    in
    Dynamic.names table
        |> List.map
            (\name ->
                ( name
                , { toJson = \registry binary -> Dynamic.toJson registry table name binary
                  , toBytes = \registry json -> Dynamic.toBytes registry table name json
                  }
                )
            )
        |> Dict.fromList
        |> Internal.Registry
