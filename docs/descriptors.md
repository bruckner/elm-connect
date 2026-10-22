# Descriptors, Any and error details

Besides its types and codecs, generated code describes the protos as
data: each message, enum, field and method has a descriptor, and each
package a registry of them by full name. They are what `Proto.Any` and
`Rpc.Error.details` read, and what a program uses to walk a message it
was not written for.
`google.rpc.Status`, the error detail types and the well-known types
are listed with the other specifications in [specs.md](specs.md).

## Typed values

Each message and enum has a typed value, holding its codecs, its
default and its descriptor: `Notes.V1.messageNote :
Proto.Message.Message Note` and `Notes.V1.enumVisibility :
Proto.Enum.Enum Visibility`. `Proto.Message.encode`, `decoder`,
`default` and `toDescriptor` read one; `Proto.Enum` adds `toName`,
`fromName`, `toNumber` and `fromNumber`. A function that takes a typed
value works for every message, as `Proto.Any.pack` and
`Rpc.Error.details` below do.

## Descriptors

A descriptor holds a type's full name and its fields (or values) as
data, each field with its `google.api.field_behavior` and whether it is
deprecated. The descriptors live in modules of their own beside the
package's, so the values a program sends and receives stay in
`Notes.V1`: `Notes.V1.Note.descriptor`, with one value per field
(`Notes.V1.Note.title`), and `Notes.V1.Visibility.descriptor`. A
service's module holds a descriptor per method, `descriptorGetNote`,
with its idempotency and its `google.api.http` bindings. All are opaque,
read through the module of their concept (`Proto.Message`, with
`Proto.Field` for a field; `Proto.Enum` with `Proto.EnumValue`;
`Proto.Method`).

## The registry

`Notes.V1.registry` holds the descriptors of the package, of every
package it imports and of the well-known types, by full name:

```elm examples/notes/elm/src/Snippets/Descriptors.elm#descriptors
import Notes.V1
import Notes.V1.Note
import Proto.Field
import Proto.Message
import Proto.Registry


noteUrl : String
noteUrl =
    -- "type.googleapis.com/notes.v1.Note"
    Proto.Message.typeUrl Notes.V1.Note.descriptor


noteFields : List String
noteFields =
    -- the proto names of Note's fields, in declaration order
    Proto.Registry.message "notes.v1.Note" Notes.V1.registry
        |> Maybe.map (Proto.Message.fields >> List.map Proto.Field.name)
        |> Maybe.withDefault []
```

## Any

`Proto.Any` packs a message into a `google.protobuf.Any` with its typed
value, and unpacks one the same way: `Nothing` when it holds another
type, `Just (Err problem)` when it holds this type but cannot be read.

```elm examples/notes/elm/src/Snippets/Any.elm#any
import Notes.V1
import Proto.Any


packed : Proto.Any.Any
packed =
    -- {"@type": "type.googleapis.com/notes.v1.Note", "title": "groceries"}
    let
        note =
            Notes.V1.defaultNote
    in
    Proto.Any.pack Notes.V1.messageNote { note | title = "groceries" }


title : Proto.Any.Any -> Maybe String
title any =
    case Proto.Any.unpack Notes.V1.messageNote any of
        Just (Ok note) ->
            Just note.title

        _ ->
            Nothing
```

`Proto.Any.is` tests an `Any`'s type, `typeUrl` and `typeName` read it,
and `Proto.Any.describe registry any` finds its descriptor.

## Error details

An error's details are `Any`s, and `Rpc.Error.details` gives those of one
type, here `google.rpc.BadRequest` from a package generated from
`google/rpc/error_details.proto` (the notes example generates it with buf
from googleapis):

```elm examples/notes/elm/src/Snippets/Details.elm#details
import Google.Rpc
import Rpc
import Rpc.Error


violations : Rpc.Error -> List String
violations error =
    Rpc.Error.details Google.Rpc.messageBadRequest error
        |> List.concatMap .fieldViolations
        |> List.map .description
```

`google.rpc`'s types are not part of the runtime: generate them from
googleapis' `google/rpc/error_details.proto` like any other proto
([`examples/notes/buf.gen.google-rpc.yaml`](../examples/notes/buf.gen.google-rpc.yaml)
does). A Connect server sends each detail as protobuf binary, with its
JSON beside it as `debug` when it chooses to; a detail without `debug`
keeps its type but does not unpack (`Proto.Any.BinaryOnly`).

## Update masks

The descriptors are enough to walk a message. The example's
`Snippets.UpdateMask` builds an update request's
`google.protobuf.FieldMask` from the value before and after an edit,
naming a nested message's changed fields through the registry:

```elm examples/notes/elm/src/Snippets/UpdateMask.elm#update-mask-use
{-| The `google.protobuf.FieldMask` of what changed from `before` to
`after`, for an update request such as `UpdateNoteRequest`.
-}
updateMask : Registry -> Message a -> a -> a -> List String
updateMask registry message before after =
    changedPaths registry
        (Message.toDescriptor message)
        (Message.encode message before)
        (Message.encode message after)
```

`changedPaths`, in the same file, compares the two values' JSON field by
field, walking into a singular message field set on both sides, and
`validMask` checks that every path of a mask names a field. The
example's tests (`examples/notes/elm/tests/Snippets/UpdateMaskTest.elm`)
run both against the notes package. The runtime has no mask helper of
its own; copy the file and adapt it.
