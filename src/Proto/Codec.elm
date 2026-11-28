module Proto.Codec exposing (Json, Binary)

{-| The codec tags: the first type parameter of a method, a call, a protocol
and a client, naming the codec it speaks.

A codec is an encoder paired with the decoder that reads what it writes. Every
message has two, one for proto3 JSON and one for protobuf binary. A method
generated with proto3 JSON codecs is a `Method Json req res`, one with
protobuf binary codecs a `Method Binary req res`, and one with both is free in
it.

The tags have no values: they are only ever types. Write them as
[`Rpc.Json`](Rpc#Json) and [`Rpc.Binary`](Rpc#Binary), which are these, as
generated code does; [`Proto.Method`](Proto-Method)'s signatures name them here.

@docs Json, Binary

-}


{-| proto3 JSON.
-}
type Json
    = Json Never


{-| Protobuf binary.
-}
type Binary
    = Binary Never
