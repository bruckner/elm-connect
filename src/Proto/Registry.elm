module Proto.Registry exposing
    ( Registry, empty, union
    , withBinary, toBinary
    )

{-| The table an [`Any`](Proto-Any#Any) resolves through: messages' codecs
by full name, so that an `Any` holding a message's JSON alone, as one read
from proto3 JSON does, can be written as protobuf binary
([`Proto.Binary.anyWith`](Proto-Binary#anyWith)). Code generated with
`codec=both` gives each package one, `binaryRegistry`
(`Notes.V1.binaryRegistry`), holding the codecs of the package's messages,
of those of every package it imports and of the well-known types they hold,
and its binary encoders write an `Any` with it.

A registry holds no descriptors; those are
[`Proto.Descriptors`](Proto-Descriptors). A program reading descriptors keeps
no codecs for it, nor one writing binary any descriptors.

@docs Registry, empty, union


# Binary codecs

@docs withBinary, toBinary

-}

import Bytes exposing (Bytes)
import Bytes.Encode
import Dict exposing (Dict)
import Json.Decode
import Json.Encode


{-| Messages' conversions from proto3 JSON to protobuf binary, each by the
message's full name. A registry holds functions, so `==` on it fails at run
time.
-}
type Registry
    = Registry (Dict String (Json.Encode.Value -> Maybe Bytes))


{-| The registry with nothing in it.
-}
empty : Registry
empty =
    Registry Dict.empty


{-| Both registries' codecs. Of two for one name, the left one's are kept.
-}
union : Registry -> Registry -> Registry
union (Registry left) (Registry right) =
    Registry (Dict.union left right)


{-| The registry with a message's codecs too, by its full name: its proto3
JSON decoder and its protobuf binary encoder, so that its JSON can be written
as binary ([`toBinary`](#toBinary)). Of two codecs for one name, the later is
kept.

    Proto.Registry.empty
        |> Proto.Registry.withBinary "notes.v1.Note" Notes.V1.decodeNote Notes.V1.encodeNoteBytes

-}
withBinary : String -> Json.Decode.Decoder a -> (a -> Bytes.Encode.Encoder) -> Registry -> Registry
withBinary typeName decoder encode (Registry registry) =
    let
        convert json =
            Json.Decode.decodeValue decoder json
                |> Result.toMaybe
                |> Maybe.map (encode >> Bytes.Encode.encode)
    in
    Registry (Dict.insert typeName convert registry)


{-| A message's protobuf binary from its proto3 JSON, by the message's full
name: `Nothing` when the registry has no codecs for it
([`withBinary`](#withBinary)) or the JSON is not the message's.
-}
toBinary : String -> Json.Encode.Value -> Registry -> Maybe Bytes
toBinary typeName json (Registry registry) =
    Dict.get typeName registry
        |> Maybe.andThen (\convert -> convert json)
