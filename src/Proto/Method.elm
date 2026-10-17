module Proto.Method exposing
    ( Method, method
    , encodeRequest, responseDecoder, descriptor
    )

{-| A method as a value: the codecs of its request and response, and its
descriptor. Generated code gives one to [`Rpc.call`](Rpc#call) per method.

@docs Method, method


# Reading

@docs encodeRequest, responseDecoder, descriptor

-}

import Json.Decode
import Json.Encode
import Proto.Descriptor exposing (MethodDescriptor)


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
        , descriptor : MethodDescriptor
        }


{-| A method from its request's proto3 JSON encoder, its response's proto3
JSON decoder and its descriptor. Generated code writes:

    getNote =
        Rpc.call
            (Proto.Method.method Notes.V1.encodeGetNoteRequest
                Notes.V1.decodeNote
                { service = "notes.v1.NotesService", name = "GetNote", … }
            )

-}
method : (req -> Json.Encode.Value) -> Json.Decode.Decoder res -> MethodDescriptor -> Method req res
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
the full names of its types, and its HTTP bindings.
-}
descriptor : Method req res -> MethodDescriptor
descriptor (Method m) =
    m.descriptor
