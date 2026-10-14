module Proto.Method exposing (Method)

{-| A method as a value: its request and response types and its descriptor.
Generated code gives one to [`Rpc.call`](Rpc#call) per method.

@docs Method

-}

import Proto.Descriptor exposing (MethodDescriptor)
import Proto.Message exposing (Message)


{-| A method taking a `req` and answering a `res`:

  - `request` and `response`: the message types, with their codecs.
  - `descriptor`: what the proto says about the method: its service and name,
    idempotency, the full names of its types, and its HTTP bindings.

-}
type alias Method req res =
    { request : Message req
    , response : Message res
    , descriptor : MethodDescriptor
    }
