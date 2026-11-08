module Proto.Method exposing
    ( Method, init, initJson, initProto, withIdempotency, withRoutes, withBindings
    , encodeRequest, responseDecoder
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
            (Proto.Method.initJson "notes.v1.NotesService"
                "GetNote"
                (\_ -> Ok << Notes.V1.encodeGetNoteRequest)
                (\_ -> Notes.V1.decodeNote)
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

@docs Method, init, initJson, initProto, withIdempotency, withRoutes, withBindings


# Reading a typed value

@docs encodeRequest, responseDecoder


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
import Proto.Any exposing (Problem)
import Proto.Binary
import Proto.Codec
import Proto.Http exposing (Binding)
import Proto.Internal.Binding
import Proto.Internal.Interpret
import Proto.Internal.Method as Internal
import Proto.Registry exposing (Registry)
import Proto.Route exposing (Route)


{-| A method taking a `req` and answering a `res`, with the codecs `codec`
says. It is opaque: built by [`initJson`](#initJson),
[`initProto`](#initProto) or [`init`](#init), adjusted by the `with` functions, and read by the functions
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
JSON decoder, each taking the registry an [`Any`](Proto-Any#Any) they hold
converts through: the client's ([`Rpc.withRegistry`](Rpc#withRegistry)). A
type that reaches no `Any` ignores it, as generated code writes. Its calls go
over a protocol speaking JSON.

    Proto.Method.initJson "notes.v1.NotesService"
        "GetNote"
        (\_ -> Ok << Notes.V1.encodeGetNoteRequest)
        (\_ -> Notes.V1.decodeNote)

Its idempotency is `IdempotencyUnknown` until
[`withIdempotency`](#withIdempotency) says otherwise, and it has no routes
until [`withRoutes`](#withRoutes) or [`withBindings`](#withBindings) gives
them, so that transcoding sends it over the implicit route.

-}
initJson : String -> String -> (Registry -> req -> Result Problem Json.Encode.Value) -> (Registry -> Json.Decode.Decoder res) -> Method Proto.Codec.Json req res
initJson serviceName methodName encode decoder =
    Internal.Method
        { service = serviceName
        , name = methodName
        , idempotency = IdempotencyUnknown
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
initProto : String -> String -> (req -> Bytes.Encode.Encoder) -> Proto.Binary.Decoder res -> Method Proto.Codec.Proto req res
initProto serviceName methodName encode decoder =
    Internal.Method
        { service = serviceName
        , name = methodName
        , idempotency = IdempotencyUnknown
        , json = Internal.noJson
        , binary = binaryHalf encode decoder
        , routes = []
        }


{-| A method with both codecs, as generated code under `codec=both` writes
it: free in the codec, so its calls go over any protocol. Its JSON codecs
take the registry an [`Any`](Proto-Any#Any) they hold converts through, the
client's ([`Rpc.withRegistry`](Rpc#withRegistry)), as for
[`initJson`](#initJson):

    Proto.Method.init "notes.v1.NotesService"
        "GetNote"
        (\_ -> Ok << Notes.V1.encodeGetNoteRequest)
        (\_ -> Notes.V1.decodeNote)
        Notes.V1.encodeGetNoteRequestBytes
        Notes.V1.decodeNoteBytes

A call whose request holds an `Any` the client's registry cannot write is not
sent over JSON: it fails with
[`NoAnswer (UnwritableRequest problem)`](Rpc-Error#Reason).

-}
init : String -> String -> (Registry -> req -> Result Problem Json.Encode.Value) -> (Registry -> Json.Decode.Decoder res) -> (req -> Bytes.Encode.Encoder) -> Proto.Binary.Decoder res -> Method codec req res
init serviceName methodName encode decoder encodeBinary binaryDecoder =
    Internal.Method
        { service = serviceName
        , name = methodName
        , idempotency = IdempotencyUnknown
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
    Internal.Method { m | routes = List.map Internal.Typed routes }


{-| The method's routes from its `google.api.http` bindings written as
[`Proto.Http`](Proto-Http) data, for a method written by hand: each route is
read from the request's proto3 JSON, written with the registry in use and
encoded once per send for the route and the body alike. Only a program
naming this function carries the code that reads a binding.

    Proto.Method.initJson "notes.v1.NotesService"
        "GetNote"
        (\_ -> Ok << encodeGetNoteRequest)
        (\_ -> decodeNote)
        |> Proto.Method.withBindings
            [ Proto.Http.binding { … } ]

-}
withBindings : List Binding -> Method codec req res -> Method codec req res
withBindings methodBindings (Internal.Method m) =
    Internal.Method
        { m
            | routes =
                List.map
                    (\(Proto.Internal.Binding.Binding rule) -> Internal.FromJson rule.responseBody (Proto.Internal.Interpret.route rule))
                    methodBindings
        }


{-| A request as proto3 JSON, writing an `Any` it holds through the registry
(see [`Proto.Any.Problem`](Proto-Any#Problem) for why that can fail). It
takes a method with JSON codecs: one built with [`initProto`](#initProto)
has none, and is refused by the compiler.
-}
encodeRequest : Registry -> Method Proto.Codec.Json req res -> req -> Result Problem Json.Encode.Value
encodeRequest registry (Internal.Method m) req =
    m.json.encode registry req


{-| The response's proto3 JSON decoder, reading an `Any` it holds through the
registry, for a method with JSON codecs, as for
[`encodeRequest`](#encodeRequest).
-}
responseDecoder : Registry -> Method Proto.Codec.Json req res -> Json.Decode.Decoder res
responseDecoder registry (Internal.Method m) =
    m.json.decoder registry


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
