module Proto.Method exposing (Method)

{-| A method as a value: the codecs of its request and response, and its
descriptor. Generated code gives one to [`Rpc.call`](Rpc#call) per method.

@docs Method

-}

import Json.Decode
import Json.Encode
import Proto.Descriptor exposing (MethodDescriptor)


{-| A method taking a `req` and answering a `res`:

  - `encodeRequest`: the request's proto3 JSON encoder.
  - `responseDecoder`: the response's proto3 JSON decoder.
  - `descriptor`: what the proto says about the method: its service and name,
    idempotency, the full names of its types, and its HTTP bindings.

A method carries only what the wire needs. The types'
[`Message`](Proto-Message#Message) records, with their defaults and field
trees, are not part of it, so a program that only sends calls does not keep
them.

-}
type alias Method req res =
    { encodeRequest : req -> Json.Encode.Value
    , responseDecoder : Json.Decode.Decoder res
    , descriptor : MethodDescriptor
    }
