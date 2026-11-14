# Descriptors, Any and error details

Besides its types and codecs, generated code describes the protos as
data: each message, enum, field and method has a descriptor, and each
package holds its descriptors by full name. They are what
`Proto.Any.describe` reads, and what a program uses to walk a message
it was not written for.
`google.rpc.Status`, the error detail types and the well-known types
are listed with the other specifications in [specs.md](specs.md).

## Typed values

Each message and enum has a typed value: `Notes.V1.messageNote :
Proto.Message.Message Note` holds the message's full name and both its
codecs, proto3 JSON and protobuf binary, whatever the `wire` option
says; `Notes.V1.enumVisibility : Proto.Enum.Enum Visibility` holds an
enum's codecs, zero value and descriptor. `Proto.Message.typeName`
reads a message's; `Proto.Enum` reads an enum's with `encode`,
`decoder`, `default`, `toDescriptor`, `toName`, `fromName`, `toNumber`
and `fromNumber`. A function that takes a typed value works for every
message, as `Proto.Any.pack` and `Proto.Registry.register` below do. A
message's descriptor and default are the generated
`Notes.V1.Note.descriptor` and `Notes.V1.defaultNote`.

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
value, and unpacks one the same way. An `Any` holds a type URL and the
message's protobuf binary, whatever codec the calls use; `unpack` gives
`Nothing` when it holds another type or its binary is not the message,
and `tryUnpack` says which with a `Proto.Error` (`TypeMismatch`,
`BadBinary`).

```elm examples/notes/elm/src/Snippets/Any.elm#any
import Notes.V1
import Proto.Any


packed : Proto.Any.Any
packed =
    -- {"@type": "type.googleapis.com/notes.v1.Note", "title": "groceries"}
    -- as proto3 JSON (Proto.Any.toJson, through a registry holding notes.v1.Note);
    -- the Any itself holds the note's protobuf binary
    let
        note =
            Notes.V1.defaultNote
    in
    Proto.Any.pack Notes.V1.messageNote { note | title = "groceries" }


title : Proto.Any.Any -> Maybe String
title any =
    Proto.Any.unpack Notes.V1.messageNote any
        |> Maybe.map .title
```

`Proto.Any.is` tests an `Any`'s type, `typeUrl` and `typeName` read it,
`bytes` reads its binary, and `Proto.Any.describe descriptors any` finds
its descriptor.

### Registries

An `Any`'s proto3 JSON is converted from and to its binary through a
`Proto.Registry`: reading an `Any` from JSON (`Proto.Json.anyWith`),
writing one as JSON (`Proto.Json.encodeAnyWith`), and
`Proto.Any.toJson`. A type the registry lacks is a loud miss, as in
protobuf's own runtimes: the read fails naming its type URL, and the
write gives `UnregisteredType` with it. Over protobuf binary no
registry is needed.

To read a message's proto3 JSON yourself, `Proto.Message.decodeJson
registry Notes.V1.messageNote json` gives a `Result Proto.Error.Error`,
in which a type the registry lacks is `UnregisteredType url` rather than
a sentence in elm/json's error, and anything else that is not the message
is `BadJson`. `Proto.Message.decodeBinary Notes.V1.messageNote bytes` is
its binary twin, which needs no registry; it can fail only one way, so it
gives the binary report, `Proto.Error.Binary`, as `Proto.Binary.decode`
does.

A program that passes `Any`s along without registering every type it
may meet makes its registry lenient, `Proto.Registry.lenient
Proto.Registry.empty` or a composed one piped through it: an `Any` of a
type it lacks is then read as its JSON alone, written back as JSON as
it arrived, and unpacked with its typed value. It has no binary
(`Proto.Any.bytes` is `Nothing`), and written as protobuf binary it is
its type URL alone, its message lost, so test `bytes` before sending one
over binary, or register its type.

Each generated package has a `registry` holding its own messages and
nothing else; the runtime has `Proto.WellKnown.registry` and
`Proto.ErrorDetails.registry`. A program composes the one its `Any`s
need and gives it to its client, which converts its calls' `Any`s and
its errors' details through it:

```elm examples/notes/elm/src/Api.elm#registry
{-| The types an `Any` this page reads as proto3 JSON may hold: a note's
attachment (the package's own messages or a well-known type), and the
`google.rpc` error details a transcoder's status body carries.
-}
registry : Proto.Registry.Registry
registry =
    Proto.Registry.unionAll
        [ Notes.V1.registry
        , Proto.WellKnown.registry
        , Proto.ErrorDetails.registry
        ]
```

`Proto.Registry.register` adds one message by its typed value, in a
pipeline (`Proto.Registry.empty |> Proto.Registry.register
Notes.V1.messageNote`). Registering a message needs nothing else
registered but the types its `Any`s hold: an entry converts a nested
`Any` through the registry it is read through.

## Error details

A status's details are `List (Result Proto.Error.Error
Proto.Any.Any)`, in the order the server sent them: each an `Any`, or
why it could not be read. Unpack those of one type with its typed
value, here `google.rpc.BadRequest` from the runtime's
`Proto.ErrorDetails`:

```elm examples/notes/elm/src/Snippets/Details.elm#details
import Proto.Any
import Proto.ErrorDetails
import Rpc
import Rpc.Error


violations : Rpc.Error -> List String
violations error =
    case error of
        Rpc.Error.RpcStatus status _ ->
            status.details
                |> List.filterMap Result.toMaybe
                |> List.filterMap (Proto.Any.unpack Proto.ErrorDetails.badRequest)
                |> List.concatMap .fieldViolations
                |> List.map .description

        _ ->
            []
```

`Proto.ErrorDetails` holds `google/rpc/error_details.proto`'s messages
(`ErrorInfo`, `BadRequest` and the rest, a nested message named as the
generator flattens it, `BadRequestFieldViolation`). A Connect server
and gRPC-Web send each detail as protobuf binary, which needs no
registry. A transcoder (grpc-gateway, Envoy, Vanguard) sends a
`google.rpc.Status` body whose details are proto3 JSON, which the
client reads through its registry: without `Proto.ErrorDetails.registry`
in it they read as `Err (UnregisteredType url)`, the error's code and
message kept; under a lenient registry they read as `Any`s held as JSON
alone, which unpack the same way. A detail that is not one at all is
`BadJson`, or over gRPC-Web `BadBinary`, with what was wrong;
`Rpc.Trace.toJson` lists every kind.

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
updateMask : Descriptors -> Message a -> (a -> Value) -> a -> a -> List String
updateMask descriptors message encode before after =
    case Descriptors.message (Message.typeName message) descriptors of
        Just descriptor ->
            changedPaths descriptors descriptor (encode before) (encode after)

        Nothing ->
            []
```

`changedPaths`, in the same file, compares the two values' JSON field by
field, walking into a singular message field set on both sides, and
`validMask` checks that every path of a mask names a field. The
example's tests (`examples/notes/elm/tests/Snippets/UpdateMaskTest.elm`)
run both against the notes package. The runtime has no mask helper of
its own; copy the file and adapt it.
