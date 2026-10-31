module Proto.Codec exposing (Json, Proto)

{-| The codec tags: the first type parameter of a method, a call, a protocol
and a client, naming the codec it speaks. A method generated with proto3 JSON
codecs is a `Method Json req res`, one with protobuf binary codecs a
`Method Proto req res`, and one with both is free in it.

The tags have no values: they are only ever types. Write them as
[`Rpc.Json`](Rpc#Json) and [`Rpc.Proto`](Rpc#Proto), which are these, as
generated code does; [`Proto.Method`](Proto-Method)'s signatures name them here.

@docs Json, Proto

-}


{-| proto3 JSON.
-}
type Json
    = Json Never


{-| Protobuf binary.
-}
type Proto
    = Proto Never
