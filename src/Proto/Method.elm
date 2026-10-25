module Proto.Method exposing
    ( Method, method, withBinary, methodBinary
    , encodeRequest, responseDecoder, toDescriptor, encodeRequestBytes, responseBytesDecoder, hasJson
    , Descriptor, descriptor
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

@docs Method, method, withBinary, methodBinary


# Reading a typed value

@docs encodeRequest, responseDecoder, toDescriptor, encodeRequestBytes, responseBytesDecoder, hasJson


# Descriptors

@docs Descriptor, descriptor


# Reading a descriptor

@docs service, name, idempotency, input, output, bindings


# Unions

@docs Idempotency

-}

import Bytes.Decode
import Bytes.Encode
import Json.Decode
import Json.Encode
import Proto.Http exposing (Binding)


{-| A method taking a `req` and answering a `res`. It is opaque: built by
[`method`](#method) and read by the functions below.

It holds what sending a call needs: the request's encoder, the response's
decoder and the method's descriptor. The types'
[`Message`](Proto-Message#Message) values, with their defaults and field
trees, are not part of it.

-}
type Method req res
    = Method
        { encodeRequest : req -> Json.Encode.Value
        , responseDecoder : Json.Decode.Decoder res
        , descriptor : Descriptor
        , binary : Maybe (Binary req res)
        , json : Bool
        }


type alias Binary req res =
    { encodeRequest : req -> Bytes.Encode.Encoder
    , responseDecoder : Int -> Bytes.Decode.Decoder res
    }


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
method encode decoder methodDescriptor =
    Method
        { encodeRequest = encode
        , responseDecoder = decoder
        , descriptor = methodDescriptor
        , binary = Nothing
        , json = True
        }


{-| The method with protobuf binary codecs too, for Connect's proto codec:
generated code under `codec=both` writes

    Proto.Method.method Notes.V1.encodeGetNoteRequest
        Notes.V1.decodeNote
        descriptorGetNote
        |> Proto.Method.withBinary
            Notes.V1.encodeGetNoteRequestBytes
            Notes.V1.decodeNoteBytes

-}
withBinary : (req -> Bytes.Encode.Encoder) -> (Int -> Bytes.Decode.Decoder res) -> Method req res -> Method req res
withBinary encodeBinary binaryDecoder (Method m) =
    Method { m | binary = Just { encodeRequest = encodeBinary, responseDecoder = binaryDecoder } }


{-| A method with protobuf binary codecs alone (`codec=binary`). Its JSON
encoder writes `null` and its JSON decoder fails, so it is for Connect's
proto codec only, not for transcoding.
-}
methodBinary : (req -> Bytes.Encode.Encoder) -> (Int -> Bytes.Decode.Decoder res) -> Descriptor -> Method req res
methodBinary encodeBinary binaryDecoder methodDescriptor =
    Method
        { encodeRequest = \_ -> Json.Encode.null
        , responseDecoder = Json.Decode.fail (name methodDescriptor ++ " was generated with protobuf binary codecs alone (codec=binary)")
        , descriptor = methodDescriptor
        , binary = Just { encodeRequest = encodeBinary, responseDecoder = binaryDecoder }
        , json = False
        }


{-| The request's protobuf binary encoder, when the method has one.
-}
encodeRequestBytes : Method req res -> Maybe (req -> Bytes.Encode.Encoder)
encodeRequestBytes (Method m) =
    Maybe.map .encodeRequest m.binary


{-| The response's protobuf binary decoder, when the method has one; it
takes the response's length in bytes.
-}
responseBytesDecoder : Method req res -> Maybe (Int -> Bytes.Decode.Decoder res)
responseBytesDecoder (Method m) =
    Maybe.map .responseDecoder m.binary


{-| Whether the method has proto3 JSON codecs: `False` for one built with
[`methodBinary`](#methodBinary), whose calls only Connect's proto codec can
send.
-}
hasJson : Method req res -> Bool
hasJson (Method m) =
    m.json


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
