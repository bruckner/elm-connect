module Proto.Method exposing
    ( Method, method, methodWith
    , encodeRequest, responseDecoder, toDescriptor
    , Descriptor, descriptor, endpoint
    , service, name, idempotency, input, output, bindings
    , Idempotency(..)
    )

{-| A method: its typed value, which holds the codecs of its request and
response and its descriptor, and its descriptor, what the proto says about it
as data. Generated code builds the descriptor once per method in its
service's module (`Notes.V1.NotesService.descriptorGetNote : Descriptor`) and
gives the typed value to [`Rpc.call`](Rpc#call).

The descriptor's idempotency is a union whose constructors carry its name as a
prefix (`IdempotencyNoSideEffects`), so it can be exposed with `(..)` beside
any other union.

@docs Method, method, methodWith


# Reading a typed value

@docs encodeRequest, responseDecoder, toDescriptor


# Descriptors

@docs Descriptor, descriptor, endpoint


# Reading a descriptor

@docs service, name, idempotency, input, output, bindings


# Unions

@docs Idempotency

-}

import Json.Decode
import Json.Encode
import Proto.Http exposing (Binding)
import Proto.Internal.Binding
import Proto.Internal.Interpret
import Proto.Internal.Method as Internal
import Rpc.Route exposing (PathError, Route)


{-| A method taking a `req` and answering a `res`. It is opaque: built by
[`method`](#method) and read by the functions below.

It holds what sending a call needs: the request's encoder, the response's
decoder and the method's descriptor. The types'
[`Message`](Proto-Message#Message) values, with their defaults and field
trees, are not part of it.

-}
type alias Method req res =
    Internal.Method Descriptor req res


{-| A method from its request's proto3 JSON encoder, its response's proto3
JSON decoder and its descriptor. Generated code writes:

    descriptorGetNote =
        Proto.Method.descriptor "notes.v1.NotesService"
            "GetNote"
            Proto.Method.IdempotencyNoSideEffects
            "notes.v1.GetNoteRequest"
            "notes.v1.Note"
            [ Proto.Http.binding { … } ]

    getNote =
        Rpc.call
            (Proto.Method.method Notes.V1.encodeGetNoteRequest
                Notes.V1.decodeNote
                descriptorGetNote
            )

-}
method : (req -> Json.Encode.Value) -> Json.Decode.Decoder res -> Descriptor -> Method req res
method encode decoder ((Descriptor d) as methodDescriptor) =
    Internal.Method
        { encodeRequest = encode
        , responseDecoder = decoder
        , descriptor = methodDescriptor
        , routes =
            List.map
                (\(Proto.Internal.Binding.Binding rule) req -> Proto.Internal.Interpret.route rule (encode req))
                d.bindings
        }


{-| A method from its request's encoder, its response's decoder, its
descriptor, and its routes: one function of the typed request per binding
of its rule, in order. A route function gives the binding's route whatever
the request holds, with the first path value its variable's template
cannot match, which sending refuses, and the response field its answer is
read from. Generated code writes:

    getNote =
        Rpc.call
            (Proto.Method.methodWith Notes.V1.encodeGetNoteRequest
                Notes.V1.decodeNote
                descriptorGetNote
                [ routeGetNote0 ]
            )

The descriptor's bindings are not read: a program that does not refer to
them keeps none, nor the interpreter that [`method`](#method) builds its
routes with.

-}
methodWith : (req -> Json.Encode.Value) -> Json.Decode.Decoder res -> Descriptor -> List (req -> Route) -> Method req res
methodWith encode decoder methodDescriptor routes =
    Internal.Method
        { encodeRequest = encode
        , responseDecoder = decoder
        , descriptor = methodDescriptor
        , routes = routes
        }


{-| A request as proto3 JSON.
-}
encodeRequest : Method req res -> req -> Json.Encode.Value
encodeRequest (Internal.Method m) =
    m.encodeRequest


{-| The response's proto3 JSON decoder.
-}
responseDecoder : Method req res -> Json.Decode.Decoder res
responseDecoder (Internal.Method m) =
    m.responseDecoder


{-| What the proto says about the method: its service and name, idempotency,
the full names of its types, and its HTTP bindings, read by the functions
below.
-}
toDescriptor : Method req res -> Descriptor
toDescriptor (Internal.Method m) =
    m.descriptor


{-| A method's descriptor: its service and name, its idempotency, its types
and its HTTP bindings. It is opaque, built by [`descriptor`](#descriptor) and
read by the functions below.
-}
type Descriptor
    = Descriptor
        { service : String
        , name : String
        , idempotency : Idempotency
        , input : String
        , output : String
        , bindings : List Binding
        }


{-| A method's `idempotency_level`, as `google.protobuf.MethodOptions` declares
it:

  - `IdempotencyUnknown`: not declared, so the method may have side effects.
  - `IdempotencyNoSideEffects`: it changes nothing, so Connect may send it as
    a GET, and a retry policy for idempotent calls may retry it.
  - `IdempotencyIdempotent`: calling it again has no further effect, so a
    retry policy for idempotent calls may retry it, but it is never a GET.

-}
type Idempotency
    = IdempotencyUnknown
    | IdempotencyNoSideEffects
    | IdempotencyIdempotent


{-| A method: the full name of its service (`notes.v1.NotesService`), its name
as declared (`GetNote`), its idempotency, the full names of its request and
response types, and its `google.api.http` rule as
[`Proto.Http`](Proto-Http) data, the rule's own binding first and then its
`additional_bindings` in order (`[]` for a method without one).
-}
descriptor : String -> String -> Idempotency -> String -> String -> List Binding -> Descriptor
descriptor serviceName methodName level inputType outputType methodBindings =
    Descriptor
        { service = serviceName
        , name = methodName
        , idempotency = level
        , input = inputType
        , output = outputType
        , bindings = methodBindings
        }


{-| A method's descriptor holding only what a call reads: the full name of
its service, its name and its idempotency. Its types' names are `""` and it
has no bindings. Generated code builds the descriptor its call carries with
this, and writes the full one, types and HTTP rule as data, as a separate
value (`fullDescriptorGetNote`) that a program keeps only if it refers to it:

    descriptorGetNote =
        Proto.Method.endpoint "notes.v1.NotesService"
            "GetNote"
            Proto.Method.IdempotencyNoSideEffects

-}
endpoint : String -> String -> Idempotency -> Descriptor
endpoint serviceName methodName level =
    descriptor serviceName methodName level "" "" []


{-| The full name of its service, such as `notes.v1.NotesService`.
-}
service : Descriptor -> String
service (Descriptor m) =
    m.service


{-| The method's name as declared, such as `GetNote`. With the service, its
Connect path.
-}
name : Descriptor -> String
name (Descriptor m) =
    m.name


{-| Its declared `idempotency_level`.
-}
idempotency : Descriptor -> Idempotency
idempotency (Descriptor m) =
    m.idempotency


{-| The full name of its request type, such as `notes.v1.GetNoteRequest`;
`""` for a descriptor built by [`endpoint`](#endpoint), as a generated call's
is.
-}
input : Descriptor -> String
input (Descriptor m) =
    m.input


{-| The full name of its response type, such as `notes.v1.Note`; `""` for a
descriptor built by [`endpoint`](#endpoint).
-}
output : Descriptor -> String
output (Descriptor m) =
    m.output


{-| Its `google.api.http` rule: the rule's own binding first, then its
`additional_bindings` in order; `[]` for a method without one.
-}
bindings : Descriptor -> List Binding
bindings (Descriptor m) =
    m.bindings
