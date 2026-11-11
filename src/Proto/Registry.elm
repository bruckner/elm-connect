module Proto.Registry exposing
    ( Registry, empty, register, union, unionAll
    , lenient
    )

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
            , Proto.WellKnown.registry
            , Proto.ErrorDetails.registry
            ]

An `Any` of a type the registry lacks is a loud miss: reading it from JSON
fails, and writing it gives [`UnregisteredType`](Proto-Any#Problem) naming
its type URL. A program that passes such `Any`s along without knowing their
types can make its registry [`lenient`](#lenient) instead.

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

@docs Registry, empty, register, union, unionAll


# Leniency

@docs lenient

-}

import Bytes.Encode
import Dict
import Json.Decode
import Proto.Bytes
import Proto.Internal.Binary
import Proto.Internal.Message as Message exposing (Message)
import Proto.Internal.Registry as Internal exposing (Failure(..))


{-| Messages' codecs by full name. A registry holds functions, so `==` on it
fails at run time.
-}
type alias Registry =
    Internal.Registry


{-| The registry with nothing in it.
-}
empty : Registry
empty =
    Internal.Registry Internal.Strict Dict.empty


{-| The registry with a message's codecs too, by its full name. Of two
entries for one name, the later is kept.

    Proto.Registry.empty
        |> Proto.Registry.register Notes.V1.messageNote

-}
register : Message a -> Registry -> Registry
register (Message.Message name codecs) (Internal.Registry leniency entries) =
    let
        entry =
            { toJson =
                \registry base64 ->
                    case Proto.Internal.Binary.runBase64 codecs.decodeBinary base64 of
                        Ok value ->
                            codecs.encodeJson registry value
                                |> Result.fromMaybe HoldsUnwritable

                        Err _ ->
                            Err NotTheMessage
            , toBytes =
                \registry json ->
                    Json.Decode.decodeValue (codecs.decodeJson registry) json
                        |> Result.map (codecs.encodeBinary >> Bytes.Encode.encode >> Proto.Bytes.toBase64)
                        |> Result.mapError Json.Decode.errorToString
            }
    in
    Internal.Registry leniency (Dict.insert name entry entries)


{-| Both registries' entries. Of two for one name, the left one's is kept.
The union is [`lenient`](#lenient) when either registry is.
-}
union : Registry -> Registry -> Registry
union ((Internal.Registry _ left) as l) ((Internal.Registry _ right) as r) =
    Internal.Registry
        (if Internal.isLenient l || Internal.isLenient r then
            Internal.Lenient

         else
            Internal.Strict
        )
        (Dict.union left right)


{-| Every registry's entries. Of two for one name, the earlier one's is kept.
The union is [`lenient`](#lenient) when any registry is.
-}
unionAll : List Registry -> Registry
unionAll registries =
    List.foldr union empty registries



-- LENIENCY


{-| The registry, reading an `Any` of a type it has no entry for from proto3
JSON as that `Any`'s JSON alone, where a registry fails the read: the
failure that is [`UnregisteredType`](Proto-Any#Problem) on a write, and a
detail's [`UnregisteredType`](Rpc-Error#DetailProblem) in an error. It
reads a type it has an entry for as before, and JSON that is not its
message still fails.

    Rpc.withRegistry (Proto.Registry.lenient Proto.Registry.empty) client

Every registry is strict until made lenient, and a union is lenient when
any of its registries is. Lenient suits a program that passes `Any`s along,
or reads a few of them by type, without registering every type it may meet:
an error detail of a type the registry lacks is then read, and unpacks
with its typed value. An `Any` held as JSON alone:

  - is written as proto3 JSON as it arrived, with no registry;
  - unpacks with its message's JSON decoder ([`Proto.Any.unpack`](Proto-Any#unpack)),
    an `Any` inside it read leniently too;
  - has no binary: [`Proto.Any.bytes`](Proto-Any#bytes) is `Nothing`, and
    written as protobuf binary, over a binary call or inside a message
    written as binary, it is its type URL alone, its message lost.

That loss is leniency's cost: test [`Proto.Any.bytes`](Proto-Any#bytes)
before an `Any` read this way goes out over binary, or register its type.
Over JSON nothing is lost. A program that reads every `Any` through a
lenient empty registry carries no registry entries, and none of their
codecs.

-}
lenient : Registry -> Registry
lenient (Internal.Registry _ entries) =
    Internal.Registry Internal.Lenient entries
