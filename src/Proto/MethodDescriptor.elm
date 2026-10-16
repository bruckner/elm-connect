module Proto.MethodDescriptor exposing
    ( MethodDescriptor
    , service, name, idempotency, input, output, bindings
    )

{-| A method's descriptor, and what it says.

@docs MethodDescriptor
@docs service, name, idempotency, input, output, bindings

-}

import Proto.Descriptor exposing (Idempotency)
import Proto.Http exposing (Binding)
import Proto.Internal.Descriptor as Internal


{-| The opaque type itself, built by
[`Proto.Descriptor.method`](Proto-Descriptor#method); the same type as
[`Proto.Descriptor.MethodDescriptor`](Proto-Descriptor#MethodDescriptor), named here beside what reads it.
-}
type alias MethodDescriptor =
    Proto.Descriptor.MethodDescriptor


{-| The full name of its service, such as `notes.v1.NotesService`.
-}
service : MethodDescriptor -> String
service (Internal.MethodDescriptor m) =
    m.service


{-| The method's name as declared, such as `GetNote`. With the service, its
Connect path.
-}
name : MethodDescriptor -> String
name (Internal.MethodDescriptor m) =
    m.name


{-| Its declared `idempotency_level`.
-}
idempotency : MethodDescriptor -> Idempotency
idempotency (Internal.MethodDescriptor m) =
    m.idempotency


{-| The full name of its request type, such as `notes.v1.GetNoteRequest`.
-}
input : MethodDescriptor -> String
input (Internal.MethodDescriptor m) =
    m.input


{-| The full name of its response type, such as `notes.v1.Note`.
-}
output : MethodDescriptor -> String
output (Internal.MethodDescriptor m) =
    m.output


{-| Its `google.api.http` rule: the rule's own binding first, then its
`additional_bindings` in order; `[]` for a method without one.
-}
bindings : MethodDescriptor -> List Binding
bindings (Internal.MethodDescriptor m) =
    m.bindings
