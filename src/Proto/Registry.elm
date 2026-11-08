module Proto.Registry exposing (Registry, empty, register, union, unionAll, wellKnown)

{-| The table a [`google.protobuf.Any`](Proto-Any#Any) is converted through
when its message crosses between proto3 JSON and protobuf binary: each
message's codecs, found by the type URL's full name. An `Any` holds its
message's binary, so only proto3 JSON needs a registry: reading an `Any`
from JSON, writing one as JSON, and [`Proto.Any.toJson`](Proto-Any#toJson).
Over protobuf binary no table is needed.

A program builds the one it needs from typed values and from the registries
generated code gives each package (`Notes.V1.registry`, which holds that
package's own messages and nothing else), and gives it to its client
([`Rpc.withRegistry`](Rpc#withRegistry)):

    types : Proto.Registry.Registry
    types =
        Proto.Registry.unionAll
            [ Notes.V1.registry
            , Proto.Registry.wellKnown
            , Proto.ErrorDetails.registry
            ]

An `Any` of a type the registry lacks is a loud miss: reading it from JSON
fails, and writing it gives [`UnregisteredType`](Proto-Any#Problem) naming
its type URL.

A message's codecs are closed over its fields' types, and each entry takes
the registry it is read through, so an `Any` nested in a registered message
is converted with the same table at any depth: registering one message
needs nothing else registered beside it, but the types its `Any`s hold.

There is no `registerAll`: a list of `Message a` holds one `a`, so a list
of several types is a list of registries, which [`unionAll`](#unionAll)
joins. Register several messages in a pipeline:

    Proto.Registry.empty
        |> Proto.Registry.register Notes.V1.messageNote
        |> Proto.Registry.register Notes.V1.messageNoteList

A registry holds no descriptors; those are
[`Proto.Descriptors`](Proto-Descriptors). The package site may show the type
as `Proto.Internal.Registry.Registry`, its name inside the package.

@docs Registry, empty, register, union, unionAll, wellKnown

-}

import Bytes.Encode
import Dict
import Json.Decode
import Proto.Bytes
import Proto.Internal.Binary
import Proto.Internal.Message as Message exposing (Message)
import Proto.Internal.Registry as Internal exposing (Failure(..))
import Proto.WellKnown


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


{-| The registry with a message's codecs too, by its full name. Of two
entries for one name, the later is kept.

    Proto.Registry.empty
        |> Proto.Registry.register Notes.V1.messageNote

-}
register : Message a -> Registry -> Registry
register (Message.Message name codecs) (Internal.Registry entries) =
    let
        entry =
            { toJson =
                \registry base64 ->
                    case Proto.Bytes.fromBase64 base64 |> Maybe.andThen (Proto.Internal.Binary.run codecs.decode) of
                        Just value ->
                            codecs.encodeJson registry value
                                |> Result.fromMaybe HoldsUnwritable

                        Nothing ->
                            Err NotTheMessage
            , toBytes =
                \registry json ->
                    Json.Decode.decodeValue (codecs.decoder registry) json
                        |> Result.map (codecs.encode >> Bytes.Encode.encode >> Proto.Bytes.toBase64)
                        |> Result.mapError Json.Decode.errorToString
            }
    in
    Internal.Registry (Dict.insert name entry entries)


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


{-| The well-known message types: `google.protobuf.Any`, `Timestamp`,
`Duration`, `FieldMask`, `Empty`, `Struct`, `Value`, `ListValue` and the
wrappers. Generated registries leave them out; add this one beside them
when an `Any` may hold one.
-}
wellKnown : Registry
wellKnown =
    empty
        |> register Proto.WellKnown.timestamp
        |> register Proto.WellKnown.duration
        |> register Proto.WellKnown.fieldMask
        |> register Proto.WellKnown.empty
        |> register Proto.WellKnown.struct
        |> register Proto.WellKnown.value
        |> register Proto.WellKnown.listValue
        |> register Proto.WellKnown.doubleValue
        |> register Proto.WellKnown.floatValue
        |> register Proto.WellKnown.int64Value
        |> register Proto.WellKnown.uint64Value
        |> register Proto.WellKnown.int32Value
        |> register Proto.WellKnown.uint32Value
        |> register Proto.WellKnown.boolValue
        |> register Proto.WellKnown.stringValue
        |> register Proto.WellKnown.bytesValue
        |> register Proto.WellKnown.any
