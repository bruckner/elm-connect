# Descriptors, Any and error details

Besides its types and codecs, generated code describes the protos as
data: each message, enum, field and method has a descriptor, and each
package holds its descriptors by full name. They are what
`Proto.Any.describe` reads, and what a program uses to walk a message it
was not written for; `Proto.Any` and `Rpc.Error.details` pack and read
with the typed values.
`google.rpc.Status`, the error detail types and the well-known types
are listed with the other specifications in [specs.md](specs.md).

## Typed values

Each message has a typed value, holding its full name and the codecs of
its world: `Notes.V1.messageNote : Proto.Message.Message Rpc.Json Note`
under `codec=json`, a `Message Rpc.Proto Note` of binary codecs under
`codec=proto` and `codec=both`. `Proto.Message.typeName` reads its name;
the descriptor is `Notes.V1.Note.descriptor` and the default
`Notes.V1.defaultNote`. Each enum's, `Notes.V1.enumVisibility :
Proto.Enum.Enum Visibility`, holds its codecs, zero value and descriptor,
read by `Proto.Enum.encode`, `decoder`, `default`, `toDescriptor`,
`toName`, `fromName`, `toNumber` and `fromNumber`. A function that takes a
typed value works for every message, as `Proto.Any.pack` and
`Rpc.Error.details` below do. `Proto.WellKnown` gives the well-known
types' in each world (`timestamp`, `timestampProto`).

## Descriptors

A descriptor holds a type's full name and its fields (or values) as
data, each field with its `google.api.field_behavior` and whether it is
deprecated. The descriptors live in modules of their own beside the
package's, so the values a program sends and receives stay in
`Notes.V1`: `Notes.V1.Note.descriptor`, with one value per field
(`Notes.V1.Note.title`), and `Notes.V1.Visibility.descriptor`. A
service's module holds a descriptor per method, `descriptorGetNote`,
with its idempotency, its types' names and its `google.api.http`
bindings, apart from the call, which does not hold it: a program keeps
it only if it names it. All are opaque,
read through the module of their concept (`Proto.Message`, with
`Proto.Field` for a field; `Proto.Enum` with `Proto.EnumValue`;
`Proto.Method`).

## A package's descriptors

`Notes.V1.descriptors`, a `Proto.Descriptors.Descriptors`, holds the
descriptors of the package, of every package it imports and of the
well-known types, by full name:

```elm examples/notes/elm/src/Snippets/Descriptors.elm#descriptors
import Notes.V1
import Notes.V1.Note
import Proto.Descriptors
import Proto.Field
import Proto.Message


noteUrl : String
noteUrl =
    -- "type.googleapis.com/notes.v1.Note"
    Proto.Message.typeUrl Notes.V1.Note.descriptor


noteFields : List String
noteFields =
    -- the proto names of Note's fields, in declaration order
    Proto.Descriptors.message "notes.v1.Note" Notes.V1.descriptors
        |> Maybe.map (Proto.Message.fields >> List.map Proto.Field.name)
        |> Maybe.withDefault []
```

## Any

`Proto.Any` packs a message into a `google.protobuf.Any` with its typed
value, and unpacks one the same way. An `Any` holds the message in one
form, its codec's: code generated with `codec=json` holds an `Any
Rpc.Json`, packed with `packJson` and unpacked with `unpackJson`
(`Nothing` when it holds another type or JSON not its message); with
`codec=proto` or `codec=both` an `Any Rpc.Proto`, holding binary, packed
with `pack` and unpacked with `unpack`. `tryUnpack` and `tryUnpackJson`
say why one cannot be read: `TypeMismatch` naming the type it holds,
`InvalidProto` or `InvalidJson`.

```elm examples/notes/elm/src/Snippets/Any.elm#any
import Notes.V1
import Proto.Any
import Rpc


packed : Proto.Any.Any Rpc.Json
packed =
    -- {"@type": "type.googleapis.com/notes.v1.Note", "title": "groceries"}
    let
        note =
            Notes.V1.defaultNote
    in
    Proto.Any.packJson Notes.V1.messageNote { note | title = "groceries" }


title : Proto.Any.Any Rpc.Json -> Maybe String
title any =
    Proto.Any.unpackJson Notes.V1.messageNote any
        |> Maybe.map .title
```

`Proto.Any.is` tests an `Any`'s type, `typeUrl` and `typeName` read it,
`bytes` and `json` read its message, and `Proto.Any.describe descriptors
any` finds its descriptor. Under `codec=both` an `Any`'s proto3 JSON goes
through the package's `registry` ([generator.md](generator.md#the-registry)),
and `Proto.Any.toJson` and `toProto` convert one between the forms with
it.

## Error details

An error's details are `Any`s, each an `Rpc.Error.Detail` holding the
forms it arrived in, and `Rpc.Error.details` and `detailsJson` give those
of one type, here `google.rpc.BadRequest` from a package generated from
`google/rpc/error_details.proto` (the notes example generates it, with the
default codec, with buf from googleapis):

```elm examples/notes/elm/src/Snippets/Details.elm#details
import Google.Rpc
import Rpc
import Rpc.Error


violations : Rpc.Error -> List String
violations error =
    Rpc.Error.detailsJson Google.Rpc.messageBadRequest error
        |> List.concatMap .fieldViolations
        |> List.map .description
```

`google.rpc`'s types are not part of the runtime: generate them from
googleapis' `google/rpc/error_details.proto` like any other proto
([`examples/notes/buf.gen.google-rpc.yaml`](../examples/notes/buf.gen.google-rpc.yaml)
does). A Connect server sends each detail as protobuf binary, with its
JSON beside it as `debug` when it chooses to; `detailsJson` reads only the
JSON, and `details` only the binary. [calling.md](calling.md#error-details)
says which to use when.

## Update masks

The descriptors are enough to walk a message. The example's
`Snippets.UpdateMask` builds an update request's
`google.protobuf.FieldMask` from the value before and after an edit,
naming a nested message's changed fields through the package's
descriptors:

```elm examples/notes/elm/src/Snippets/UpdateMask.elm#update-mask-use
{-| The `google.protobuf.FieldMask` of what changed from `before` to
`after`, for an update request such as `UpdateNoteRequest`.
-}
updateMask : Descriptors -> Message Json a -> a -> a -> List String
updateMask descriptors message before after =
    let
        json value =
            Proto.Any.json (Proto.Any.packJson message value)
    in
    case Descriptors.message (Message.typeName message) descriptors of
        Just descriptor ->
            changedPaths descriptors descriptor (json before) (json after)

        Nothing ->
            []
```

`changedPaths`, in the same file, compares the two values' JSON field by
field, walking into a singular message field set on both sides, and
`validMask` checks that every path of a mask names a field. The
example's tests (`examples/notes/elm/tests/Snippets/UpdateMaskTest.elm`)
run both against the notes package. The runtime has no mask helper of
its own; copy the file and adapt it.
