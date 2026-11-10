module Proto.Internal.Method exposing (BinaryHalf, Codecs, JsonHalf, Method(..), RouteOf(..), noBinary, noJson)

{-| The `Method` type, which `Proto.Method` names by an alias. It is defined
here so that `Rpc` can read what a method holds while users cannot. The
idempotency is a parameter because its type stays in `Proto.Method`, which
exposes its constructors. Its types are elm/core's, elm/json's, elm/bytes',
`Proto.Route`'s and `Proto.Error`'s, so that no `Proto` module imports an
`Rpc` one.

A method holds its identity (service, name, idempotency), its two codec
halves and one route function per HTTP binding, not its descriptor: the
descriptor's type names and bindings as data are a separate value a program
keeps only if it names it.

The `codec` parameter is a phantom: `Proto.Method.initJson` gives a method
in `Json`, `Proto.Method.initProto` one in `Proto`, and `Proto.Method.init`,
free in the codec, one with both. A protocol in a codec only meets a method in the
same codec, so the half it reads is always one the generated code gave.

Both halves are always present, so sending has no branch for a missing one:
the half a builder is not given is a filler ([`noJson`](#noJson),
[`noBinary`](#noBinary)). Which halves are real is data (`codecs`), read by
what reports on a method (`Proto.Method.hasJson`, `Rpc.Call.viaBinding`,
`Rpc.Call.toJson`), never by the send path.

-}

import Bytes exposing (Bytes)
import Bytes.Encode
import Json.Decode
import Json.Encode
import Proto.Error
import Proto.Internal.Registry exposing (Registry)
import Proto.Route exposing (Route)


type Method idempotency codec req res
    = Method
        { service : String
        , name : String
        , idempotency : idempotency
        , codecs : Codecs
        , json : JsonHalf req res
        , binary : BinaryHalf req res
        , routes : List (RouteOf req)
        }


{-| One binding's route of a request: built from the typed request
(`Typed`, a generated route function), or from the request's proto3 JSON
(`FromJson`, a binding written as data, with its `response_body`), which a
send encodes once for the route and its body together. A route from JSON
names its response field without the JSON, so reading an answer encodes
nothing.
-}
type RouteOf req
    = Typed (req -> Route)
    | FromJson (Maybe String) (Json.Encode.Value -> Route)


{-| Which halves the method was built with.
-}
type alias Codecs =
    { json : Bool
    , binary : Bool
    }


{-| A request's proto3 JSON and the response's decoder, given the registry
an `Any` they hold converts through, which is the client's: a method holds
none. A request holding an `Any` the registry cannot write has no JSON. A
type that reaches no `Any` ignores the registry, and its encoder never fails.
-}
type alias JsonHalf req res =
    { encode : Registry -> req -> Result Proto.Error.Error Json.Encode.Value
    , decoder : Registry -> Json.Decode.Decoder res
    }


{-| A request's protobuf binary encoder, which only the binary protocols'
functions run, and the response read from bytes, `Nothing` when they are not
one. It holds the encoder rather than the bytes so that a JSON program, whose
methods hold the filler, never calls elm/bytes.
-}
type alias BinaryHalf req res =
    { encode : req -> Bytes.Encode.Encoder
    , decode : Bytes -> Result Proto.Error.Binary res
    }


{-| The JSON half of a method built with binary codecs alone. No protocol
speaking JSON meets such a method, since the phantom rules the pairing out;
if one ever did, its answer would fail to decode as an ordinary bad
response.
-}
noJson : JsonHalf req res
noJson =
    { encode = \_ _ -> Ok Json.Encode.null
    , decoder = \_ -> Json.Decode.fail "a method without proto3 JSON codecs"
    }


{-| The binary half of a method built with JSON codecs alone. As with
[`noJson`](#noJson), an impossible pairing (unreachable through the
builders) would surface as an ordinary decode failure, a `BadResponse`
whose report is `Unlocated`, as a bug's is.

The encoder must be a constructor: `Bytes.Encode.sequence []` measures
widths, which reaches elm/bytes' whole kernel (590 B gzipped on a minimal
program) from every JSON program.

-}
noBinary : BinaryHalf req res
noBinary =
    { encode = \_ -> Bytes.Encode.unsignedInt8 0
    , decode = \_ -> Err { typeName = "", reason = Proto.Error.Unlocated, path = [], offset = 0 }
    }
