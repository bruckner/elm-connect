module Proto.Method exposing
    ( Method, json, proto, both, withRoutes, withBindings, endpointOf
    , Endpoint, endpoint, service, name, idempotency
    , Descriptor, descriptor, toEndpoint, input, output, bindings
    , Idempotency(..)
    )

{-| A method: its typed value, which holds the codecs of its request and
response, its identity (an [`Endpoint`](#Endpoint)) and its routes, and its
[`Descriptor`](#Descriptor), what the proto says about it as data. Generated
code builds both once per method in its service's module and gives the typed
value to [`Rpc.call`](Rpc#call):

    getNote =
        Rpc.call
            (Proto.Method.json Notes.V1.encodeGetNoteRequest
                Notes.V1.decodeNote
                endpointGetNote
                |> Proto.Method.withRoutes [ routeGetNote0 ]
            )

A method's first type parameter is its codec, [`Rpc.Json`](Rpc#Json) or
[`Rpc.Proto`](Rpc#Proto): the codecs it was generated with, which decide the
protocols its calls can go over. A method with both is free in it.

The idempotency is a union whose constructors carry its name as a prefix
(`IdempotencyNoSideEffects`), so it can be exposed with `(..)` beside any
other union.

@docs Method, json, proto, both, withRoutes, withBindings, endpointOf


# Endpoints

@docs Endpoint, endpoint, service, name, idempotency


# Descriptors

@docs Descriptor, descriptor, toEndpoint, input, output, bindings


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
[`both`](#both). The package site and compiler errors may show it as
`Proto.Internal.Method.Method`, its name inside the package.
-}
type alias Method codec req res =
    Internal.Method Endpoint codec req res


{-| A method from its request's proto3 JSON encoder, its response's proto3
JSON decoder and its endpoint, as generated code under `codec=json` writes
it. Its calls go over a protocol speaking JSON.
-}
json : (req -> Json.Encode.Value) -> Json.Decode.Decoder res -> Endpoint -> Method Proto.Internal.Codec.Json req res
json encode decoder methodEndpoint =
    Internal.Method
        { endpoint = methodEndpoint
        , json = Just { encode = encode, decoder = decoder }
        , binary = Nothing
        , routes = []
        }


{-| A method from its request's protobuf binary encoder, its response's
binary decoder and its endpoint, as generated code under `codec=proto`
writes it. Its calls go over a protocol speaking protobuf binary.
-}
proto : (req -> Bytes.Encode.Encoder) -> Proto.Binary.Decoder res -> Endpoint -> Method Proto.Internal.Codec.Proto req res
proto encode decoder methodEndpoint =
    Internal.Method
        { endpoint = methodEndpoint
        , json = Nothing
        , binary = Just (binaryHalf encode decoder)
        , routes = []
        }


{-| A method with both codecs, as generated code under `codec=both` writes
it: free in the codec, so its calls go over any protocol.
-}
both : (req -> Json.Encode.Value) -> Json.Decode.Decoder res -> (req -> Bytes.Encode.Encoder) -> Proto.Binary.Decoder res -> Endpoint -> Method codec req res
both encode decoder encodeBinary binaryDecoder methodEndpoint =
    Internal.Method
        { endpoint = methodEndpoint
        , json = Just { encode = encode, decoder = decoder }
        , binary = Just (binaryHalf encodeBinary binaryDecoder)
        , routes = []
        }


binaryHalf : (req -> Bytes.Encode.Encoder) -> Proto.Binary.Decoder res -> Internal.BinaryHalf req res
binaryHalf encode decoder =
    { encode = Proto.Binary.encode encode
    , decode = Proto.Binary.decode decoder
    }


{-| The method's routes for HTTP transcoding: one function of the typed
request per binding of its `google.api.http` rule, the rule's own first, as
generated code writes them (`routeGetNote0`). A method without routes is
transcoded over the implicit route, `POST /<service>/<method>`.
-}
withRoutes : List (req -> Route) -> Method codec req res -> Method codec req res
withRoutes routes (Internal.Method m) =
    Internal.Method { m | routes = routes }


{-| The method's routes from its `google.api.http` bindings written as
[`Proto.Http`](Proto-Http) data, for a method written by hand: each route
is read from the request's proto3 JSON. Only a program naming this function
carries the code that reads a binding.
-}
withBindings : List Binding -> Method codec req res -> Method codec req res
withBindings methodBindings (Internal.Method m) =
    Internal.Method
        { m
            | routes =
                case m.json of
                    Just half ->
                        List.map (\(Proto.Internal.Binding.Binding rule) req -> Proto.Internal.Interpret.route rule (half.encode req)) methodBindings

                    Nothing ->
                        []
        }


{-| The method's endpoint.
-}
endpointOf : Method codec req res -> Endpoint
endpointOf (Internal.Method m) =
    m.endpoint



-- ENDPOINTS


{-| What a call of the method needs to know of it: the full name of its
service, its name, and its idempotency. It is data: endpoints built alike
are `==`.
-}
type Endpoint
    = Endpoint { service : String, name : String, idempotency : Idempotency }


{-| An endpoint, as generated code writes one per method:

    endpointGetNote =
        Proto.Method.endpoint "notes.v1.NotesService" "GetNote" Proto.Method.IdempotencyNoSideEffects

-}
endpoint : String -> String -> Idempotency -> Endpoint
endpoint serviceName methodName level =
    Endpoint { service = serviceName, name = methodName, idempotency = level }


{-| The full name of its service, such as `notes.v1.NotesService`.
-}
service : Endpoint -> String
service (Endpoint e) =
    e.service


{-| The method's name as declared, such as `GetNote`. With the service, its
Connect path.
-}
name : Endpoint -> String
name (Endpoint e) =
    e.name


{-| Its declared `idempotency_level`.
-}
idempotency : Endpoint -> Idempotency
idempotency (Endpoint e) =
    e.idempotency


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



-- DESCRIPTORS


{-| What the proto says about a method, as data: its endpoint, the full names
of its request and response types, and its `google.api.http` rule. Generated
code writes one per method (`descriptorGetNote`), apart from the method: a
program keeps it only if it names it.
-}
type Descriptor
    = Descriptor
        { endpoint : Endpoint
        , input : String
        , output : String
        , bindings : List Binding
        }


{-| A descriptor: the method's endpoint, the full names of its request and
response types, and its rule as [`Proto.Http`](Proto-Http) data, the rule's
own binding first and then its `additional_bindings` in order (`[]` for a
method without one).
-}
descriptor : Endpoint -> String -> String -> List Binding -> Descriptor
descriptor methodEndpoint inputType outputType methodBindings =
    Descriptor
        { endpoint = methodEndpoint
        , input = inputType
        , output = outputType
        , bindings = methodBindings
        }


{-| The method's endpoint.
-}
toEndpoint : Descriptor -> Endpoint
toEndpoint (Descriptor d) =
    d.endpoint


{-| The full name of its request type, such as `notes.v1.GetNoteRequest`.
-}
input : Descriptor -> String
input (Descriptor d) =
    d.input


{-| The full name of its response type, such as `notes.v1.Note`.
-}
output : Descriptor -> String
output (Descriptor d) =
    d.output


{-| Its `google.api.http` rule: the rule's own binding first, then its
`additional_bindings` in order; `[]` for a method without one.
-}
bindings : Descriptor -> List Binding
bindings (Descriptor d) =
    d.bindings
