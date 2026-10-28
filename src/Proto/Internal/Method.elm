module Proto.Internal.Method exposing (BinaryHalf, Codecs, JsonHalf, Method(..), noBinary, noJson)

{-| The `Method` type, which `Proto.Method` names by an alias. It is defined
here so that `Rpc` can read what a method holds while users cannot. The
idempotency is a parameter because its type stays in `Proto.Method`, which
exposes its constructors. Its types are elm/core's, elm/json's, elm/bytes'
and `Proto.Route`'s, so that no `Proto` module imports an `Rpc` one.

A method holds its identity (service, name, idempotency), its two codec
halves and one route function per HTTP binding, not its descriptor: the
descriptor's type names and bindings as data are a separate value a program
keeps only if it names it.

The `codec` parameter is a phantom: `Proto.Method.json` gives a method in
`Json`, `Proto.Method.proto` one in `Proto`, and `Proto.Method.both`, free in
the codec, one with both. A protocol in a codec only meets a method in the
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
import Proto.Route exposing (Route)


type Method idempotency codec req res
    = Method
        { service : String
        , name : String
        , idempotency : idempotency
        , codecs : Codecs
        , json : JsonHalf req res
        , binary : BinaryHalf req res
        , routes : List (req -> Route)
        }


{-| Which halves the method was built with.
-}
type alias Codecs =
    { json : Bool
    , binary : Bool
    }


{-| A request's proto3 JSON and the response's decoder.
-}
type alias JsonHalf req res =
    { encode : req -> Json.Encode.Value
    , decoder : Json.Decode.Decoder res
    }


{-| A request's protobuf binary encoder, which only the binary protocols'
functions run, and the response read from bytes, `Nothing` when they are not
one. It holds the encoder rather than the bytes so that a JSON program, whose
methods hold the filler, never calls elm/bytes.
-}
type alias BinaryHalf req res =
    { encode : req -> Bytes.Encode.Encoder
    , decode : Bytes -> Maybe res
    }


{-| The JSON half of a method built with binary codecs alone. No protocol
speaking JSON meets such a method, since the phantom rules the pairing out;
if one ever did, its answer would fail to decode as an ordinary bad
response.
-}
noJson : JsonHalf req res
noJson =
    { encode = \_ -> Json.Encode.null
    , decoder = Json.Decode.fail "a method without proto3 JSON codecs"
    }


{-| The binary half of a method built with JSON codecs alone. As with
[`noJson`](#noJson), an impossible pairing (unreachable through the
builders) would surface as the ordinary decode failure "the body is not the
response of svc/Method in protobuf binary".

The encoder must be a constructor: `Bytes.Encode.sequence []` measures
widths, which reaches elm/bytes' whole kernel (590 B gzipped on a minimal
program) from every JSON program.

-}
noBinary : BinaryHalf req res
noBinary =
    { encode = \_ -> Bytes.Encode.unsignedInt8 0
    , decode = \_ -> Nothing
    }
