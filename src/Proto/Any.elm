module Proto.Any exposing
    ( Any, typeUrl, typeName, is
    , pack, packWith, unpack, Problem(..)
    , describe
    )

{-| `google.protobuf.Any`: a message of any type, with the URL naming its type.

    detail : Proto.Any.Any
    detail =
        Proto.Any.pack Notes.V1.messageNote note

    Proto.Any.unpack Notes.V1.messageNote detail
    --> Just (Ok note)

An `Any` read from proto3 JSON holds the message's JSON. One read from
protobuf binary, or from a Connect error detail without its `debug` JSON,
holds only the message's binary: [`unpack`](#unpack) reads it with a message
generated with binary codecs (`codec=both`), and gives
[`BinaryOnly`](#Problem) for one without. The proto3 JSON
codecs of an `Any` are [`Proto.Json.any`](Proto-Json#any) and
[`Proto.Json.encodeAny`](Proto-Json#encodeAny).

@docs Any, typeUrl, typeName, is


# Packing and unpacking

@docs pack, packWith, unpack, Problem


# Describing

@docs describe

-}

import Json.Decode
import Proto.Internal.Any as Internal exposing (Payload(..))
import Proto.Internal.Message
import Proto.Message as Message exposing (Message)
import Proto.Registry as Registry exposing (Registry)


{-| A packed message and its type URL. It is opaque: build one with
[`pack`](#pack), or decode one with [`Proto.Json.any`](Proto-Json#any), and
read it with the functions here. The package site and
compiler errors may show it as `Proto.Internal.Any.Any`, its name inside the
package.
-}
type alias Any =
    Internal.Any


{-| The URL naming the packed message's type, such as
`type.googleapis.com/notes.v1.Note`.
-}
typeUrl : Any -> String
typeUrl (Internal.Any url _) =
    url


{-| The packed message's full name: the type URL after its last `/`, such as
`notes.v1.Note`.
-}
typeName : Any -> String
typeName (Internal.Any url _) =
    Internal.nameOf url


{-| Whether the packed message is of this type, by full name.
-}
is : Message a -> Any -> Bool
is message any =
    typeName any == Message.typeName (Message.toDescriptor message)



-- PACKING AND UNPACKING


{-| A message as an `Any`, its type URL prefixed `type.googleapis.com/`, as
protobuf's own libraries write it.
-}
pack : Message a -> a -> Any
pack message value =
    Internal.Any (Message.typeUrl (Message.toDescriptor message)) (payloadOf message value)


{-| A message as an `Any` whose type URL has another prefix:
`packWith "example.com/types" messageNote note` has the type URL
`example.com/types/notes.v1.Note`.
-}
packWith : String -> Message a -> a -> Any
packWith prefix message value =
    let
        slashed =
            if String.endsWith "/" prefix then
                prefix

            else
                prefix ++ "/"
    in
    Internal.Any (slashed ++ Message.typeName (Message.toDescriptor message)) (payloadOf message value)


{-| A value's JSON, and its binary too when its message has binary codecs, so
the `Any` can be written in either form.
-}
payloadOf : Message a -> a -> Payload
payloadOf ((Proto.Internal.Message.Message m) as message) value =
    case m.binary of
        Just binary ->
            InBoth (Message.encode message value) (binary.toBase64 value)

        Nothing ->
            InJson (Message.encode message value)


{-| The packed message, if it is of this type: `Nothing` for another type,
`Just (Err problem)` for this type when it cannot be read.
-}
unpack : Message a -> Any -> Maybe (Result Problem a)
unpack ((Proto.Internal.Message.Message m) as message) ((Internal.Any _ payload) as any) =
    if is message any then
        case payload of
            InBinary base64 ->
                case m.binary of
                    Just binary ->
                        case binary.fromBase64 base64 of
                            Just value ->
                                Just (Ok value)

                            Nothing ->
                                Just (Err Binary)

                    Nothing ->
                        Just (Err BinaryOnly)

            _ ->
                Just (Json.Decode.decodeValue (Message.decoder message) (Internal.jsonOf payload) |> Result.mapError Json)

    else
        Nothing


{-| Why a message of the right type could not be unpacked.

  - `Json`: its JSON does not decode as the message.
  - `BinaryOnly`: only its protobuf binary arrived (read from binary, or a
    Connect error detail without `debug`), and the message has no binary
    codecs to read it with.
  - `Binary`: only its protobuf binary arrived, and it does not decode as
    the message.

-}
type Problem
    = Json Json.Decode.Error
    | BinaryOnly
    | Binary



-- DESCRIBING


{-| The descriptor of the packed message's type, if the registry has it.
-}
describe : Registry -> Any -> Maybe Message.Descriptor
describe registry any =
    Registry.message (typeName any) registry
