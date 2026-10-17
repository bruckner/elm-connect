module Proto.Method exposing
    ( Method, method
    , encodeRequest, responseDecoder, toDescriptor
    , Descriptor, descriptor
    , service, name, idempotent, input, output, bindings
    )

{-| A method: its typed value, which holds the codecs of its request and
response and its descriptor, and its descriptor, what the proto says about it
as data. Generated code builds the descriptor once per method in its
service's module (`Notes.V1.NotesService.descriptorGetNote : Descriptor`) and
gives the typed value to [`Rpc.call`](Rpc#call).

@docs Method, method


# Reading a typed value

@docs encodeRequest, responseDecoder, toDescriptor


# Descriptors

@docs Descriptor, descriptor


# Reading a descriptor

@docs service, name, idempotent, input, output, bindings

-}

import Json.Decode
import Json.Encode
import Proto.Http exposing (Binding)


{-| A method taking a `req` and answering a `res`. It is opaque: built by
[`method`](#method) and read by the functions below, so that what it carries
can grow as a new modifier without breaking code generated before.

A method carries only what the wire needs. The types'
[`Message`](Proto-Message#Message) values, with their defaults and field
trees, are not part of it, so a program that only sends calls does not keep
them.

-}
type Method req res
    = Method
        { encodeRequest : req -> Json.Encode.Value
        , responseDecoder : Json.Decode.Decoder res
        , descriptor : Descriptor
        }


{-| A method from its request's proto3 JSON encoder, its response's proto3
JSON decoder and its descriptor. Generated code writes:

    descriptorGetNote =
        Proto.Method.descriptor "notes.v1.NotesService"
            "GetNote"
            True
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
method encode decoder methodDescriptor =
    Method
        { encodeRequest = encode
        , responseDecoder = decoder
        , descriptor = methodDescriptor
        }


{-| A request as proto3 JSON.
-}
encodeRequest : Method req res -> req -> Json.Encode.Value
encodeRequest (Method m) =
    m.encodeRequest


{-| The response's proto3 JSON decoder.
-}
responseDecoder : Method req res -> Json.Decode.Decoder res
responseDecoder (Method m) =
    m.responseDecoder


{-| What the proto says about the method: its service and name, idempotency,
the full names of its types, and its HTTP bindings, read by the functions
below.
-}
toDescriptor : Method req res -> Descriptor
toDescriptor (Method m) =
    m.descriptor


{-| A method's descriptor: its service and name, its idempotency, its types
and its HTTP bindings. It is opaque, built by [`descriptor`](#descriptor) and
read by the functions below, so that a later release can say more about a
method without breaking code that builds or reads one.
-}
type Descriptor
    = Descriptor
        { service : String
        , name : String
        , idempotent : Bool
        , input : String
        , output : String
        , bindings : List Binding
        }


{-| A method: the full name of its service (`notes.v1.NotesService`), its name
as declared (`GetNote`), whether it is idempotent (below), the full names of
its request and response types, and its `google.api.http` rule as
[`Proto.Http`](Proto-Http) data, the rule's own binding first and then its
`additional_bindings` in order (`[]` for a method without one).
-}
descriptor : String -> String -> Bool -> String -> String -> List Binding -> Descriptor
descriptor serviceName methodName noSideEffects inputType outputType methodBindings =
    Descriptor
        { service = serviceName
        , name = methodName
        , idempotent = noSideEffects
        , input = inputType
        , output = outputType
        , bindings = methodBindings
        }


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


{-| Whether the proto declares `idempotency_level = NO_SIDE_EFFECTS`, which
lets Connect send it as a GET and a retry policy retry it.
-}
idempotent : Descriptor -> Bool
idempotent (Descriptor m) =
    m.idempotent


{-| The full name of its request type, such as `notes.v1.GetNoteRequest`.
-}
input : Descriptor -> String
input (Descriptor m) =
    m.input


{-| The full name of its response type, such as `notes.v1.Note`.
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
