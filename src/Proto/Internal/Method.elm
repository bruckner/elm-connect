module Proto.Internal.Method exposing (BinaryHalf, JsonHalf, Method(..))

{-| The `Method` type, which `Proto.Method` names by an alias. It is defined
here so that `Rpc` can read what a method holds while users cannot. The
endpoint is a parameter because its type, with `Idempotency`, stays in
`Proto.Method`, which exposes that union's constructors.

The `codec` parameter is a phantom: `Proto.Method.json` gives a method in
`Json` with `json = Just`, `Proto.Method.proto` one in `Proto` with
`binary = Just`, and `Proto.Method.both`, free in the codec, both. A protocol
in a codec only meets a method in the same codec, so the half it reads is
always there; `Rpc.Internal.Send` says what it does when it is not.

Each half holds only elm/core, elm/json and elm/bytes types, so that the
code reading or writing protobuf binary is reached only from a method built
with binary codecs.

-}

import Bytes exposing (Bytes)
import Json.Decode
import Json.Encode
import Proto.Route exposing (Route)


type Method endpoint codec req res
    = Method
        { endpoint : endpoint
        , json : Maybe (JsonHalf req res)
        , binary : Maybe (BinaryHalf req res)
        , routes : List (req -> Route)
        }


{-| A request's proto3 JSON and the response's decoder.
-}
type alias JsonHalf req res =
    { encode : req -> Json.Encode.Value
    , decoder : Json.Decode.Decoder res
    }


{-| A request's protobuf binary and the response read from bytes, `Nothing`
when they are not one.
-}
type alias BinaryHalf req res =
    { encode : req -> Bytes
    , decode : Bytes -> Maybe res
    }
