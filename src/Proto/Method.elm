module Proto.Method exposing
    ( Method, json, proto, both, withIdempotency, withRoutes, withBindings
    , encodeRequest, responseDecoder, hasJson
    , Descriptor, descriptor
    , service, name, idempotency, input, output, bindings
    , Idempotency(..)
    )

{-| A method: its typed value, which holds the codecs of its request and
response, its identity and its routes, and its descriptor, what the proto
says about it as data. Generated code builds both once per method in its
service's module and gives the typed value to [`Rpc.call`](Rpc#call):

    getNote =
        Rpc.call
            (Proto.Method.json "notes.v1.NotesService"
                "GetNote"
                Notes.V1.encodeGetNoteRequest
                Notes.V1.decodeNote
                |> Proto.Method.withIdempotency Proto.Method.IdempotencyNoSideEffects
                |> Proto.Method.withRoutes [ routeGetNote0 ]
            )

A method's first type parameter is its codec, [`Rpc.Json`](Rpc#Json) or
[`Rpc.Proto`](Rpc#Proto): the codecs it was generated with, which decide the
protocols its calls can go over. A method with both is free in it.

The descriptor (`descriptorGetNote : Descriptor`) is a separate value: a
program keeps it only if it names it.

The idempotency is a union whose constructors carry its name as a prefix
(`IdempotencyNoSideEffects`), so it can be exposed with `(..)` beside any
other union.

@docs Method, json, proto, both, withIdempotency, withRoutes, withBindings


# Reading a typed value

@docs encodeRequest, responseDecoder, hasJson


# Descriptors

@docs Descriptor, descriptor


# Reading a descriptor

@docs service, name, idempotency, input, output, bindings


# Unions

@docs Idempotency

-}

import Bytes.Encode
import Json.Decode
import Json.Encode
import Proto.Binary
import Proto.Http exposing (Binding)
import Proto.Internal.Binding
import Proto.Internal.Codec
import Proto.Internal.Interpret
import Proto.Internal.Method as Internal
import Proto.Route exposing (Route)


{-| A method taking a `req` and answering a `res`, with the codecs `codec`
says. It is opaque: built by [`json`](#json), [`proto`](#proto) or
[`both`](#both), adjusted by the `with` functions, and read by the functions
below. The package site and compiler errors may show it as
`Proto.Internal.Method.Method`, its name inside the package.

It holds what sending a call needs: the request's encoder, the response's
decoder, the full name of the method's service, its name, its idempotency,
and its routes for HTTP transcoding. The types'
[`Message`](Proto-Message#Message) values, with their defaults and field
trees, and the method's [`Descriptor`](#Descriptor) are not part of it.

-}
type alias Method codec req res =
    Internal.Method Idempotency codec req res


{-| A method with proto3 JSON codecs, as generated code under `codec=json`
writes it: from the full name of its service (`notes.v1.NotesService`), its
name as declared (`GetNote`), its request's JSON encoder and its response's
JSON decoder. Its calls go over a protocol speaking JSON.

Its idempotency is `IdempotencyUnknown` until
[`withIdempotency`](#withIdempotency) says otherwise, and it has no routes
until [`withRoutes`](#withRoutes) or [`withBindings`](#withBindings) gives
them, so that transcoding sends it over the implicit route.

-}
json : String -> String -> (req -> Json.Encode.Value) -> Json.Decode.Decoder res -> Method Proto.Internal.Codec.Json req res
json serviceName methodName encode decoder =
    Internal.Method
        { service = serviceName
        , name = methodName
        , idempotency = IdempotencyUnknown
        , codecs = { json = True, binary = False }
        , json = { encode = encode, decoder = decoder }
        , binary = Internal.noBinary
        , routes = []
        }


{-| A method with protobuf binary codecs, as generated code under
`codec=proto` writes it: from its service's full name, its name, its
request's binary encoder and its response's binary decoder. Its calls go over a
protocol speaking protobuf binary, which transcoding is not, so it takes no
routes.
-}
proto : String -> String -> (req -> Bytes.Encode.Encoder) -> Proto.Binary.Decoder res -> Method Proto.Internal.Codec.Proto req res
proto serviceName methodName encode decoder =
    Internal.Method
        { service = serviceName
        , name = methodName
        , idempotency = IdempotencyUnknown
        , codecs = { json = False, binary = True }
        , json = Internal.noJson
        , binary = binaryHalf encode decoder
        , routes = []
        }


{-| A method with both codecs, as generated code under `codec=both` writes
it: free in the codec, so its calls go over any protocol.

    Proto.Method.both "notes.v1.NotesService"
        "GetNote"
        Notes.V1.encodeGetNoteRequest
        Notes.V1.decodeNote
        Notes.V1.encodeGetNoteRequestBytes
        Notes.V1.decodeNoteBytes

-}
both : String -> String -> (req -> Json.Encode.Value) -> Json.Decode.Decoder res -> (req -> Bytes.Encode.Encoder) -> Proto.Binary.Decoder res -> Method codec req res
both serviceName methodName encode decoder encodeBinary binaryDecoder =
    Internal.Method
        { service = serviceName
        , name = methodName
        , idempotency = IdempotencyUnknown
        , codecs = { json = True, binary = True }
        , json = { encode = encode, decoder = decoder }
        , binary = binaryHalf encodeBinary binaryDecoder
        , routes = []
        }


binaryHalf : (req -> Bytes.Encode.Encoder) -> Proto.Binary.Decoder res -> Internal.BinaryHalf req res
binaryHalf encode decoder =
    { encode = encode
    , decode = Proto.Binary.decode decoder
    }


{-| The method's declared `idempotency_level`. Generated code writes it only
for a method that declares one.
-}
withIdempotency : Idempotency -> Method codec req res -> Method codec req res
withIdempotency level (Internal.Method m) =
    Internal.Method { m | idempotency = level }


{-| The method's routes for HTTP transcoding: one function of the typed
request per binding of its `google.api.http` rule, the rule's own first and
then its `additional_bindings` in order, as generated code writes them
(`routeGetNote0`). A route function gives its binding's route whatever the
request holds, with the first path value its variable's template cannot
match, which sending refuses.
-}
withRoutes : List (req -> Route) -> Method codec req res -> Method codec req res
withRoutes routes (Internal.Method m) =
    Internal.Method { m | routes = routes }


{-| The method's routes from its `google.api.http` bindings written as
[`Proto.Http`](Proto-Http) data, for a method written by hand: each route is
read from the request's proto3 JSON. Only a program naming this function
carries the code that reads a binding.

    Proto.Method.json "notes.v1.NotesService"
        "GetNote"
        encodeGetNoteRequest
        decodeNote
        |> Proto.Method.withBindings
            [ Proto.Http.binding { … } ]

-}
withBindings : List Binding -> Method codec req res -> Method codec req res
withBindings methodBindings (Internal.Method m) =
    Internal.Method
        { m
            | routes =
                List.map
                    (\(Proto.Internal.Binding.Binding rule) req -> Proto.Internal.Interpret.route rule (m.json.encode req))
                    methodBindings
        }


{-| A request as proto3 JSON; `null` for a method built with
[`proto`](#proto), which has no JSON codecs.
-}
encodeRequest : Method codec req res -> req -> Json.Encode.Value
encodeRequest (Internal.Method m) =
    m.json.encode


{-| The response's proto3 JSON decoder; one that always fails for a method
built with [`proto`](#proto).
-}
responseDecoder : Method codec req res -> Json.Decode.Decoder res
responseDecoder (Internal.Method m) =
    m.json.decoder


{-| Whether the method has proto3 JSON codecs: `False` for one built with
[`proto`](#proto).
-}
hasJson : Method codec req res -> Bool
hasJson (Internal.Method m) =
    m.codecs.json


{-| What the proto says about a method, as data: its service and name, its
idempotency, its types and its HTTP bindings. It is opaque, built by
[`descriptor`](#descriptor) and read by the functions below. Generated code
writes one per method (`descriptorGetNote`) apart from the method, which
does not hold it: a program keeps it only if it names it.
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
