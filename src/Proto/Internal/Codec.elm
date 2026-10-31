module Proto.Internal.Codec exposing (Json, Proto)

{-| The two codec tags, the phantom parameter of a method, a call, a protocol
and a client. Not exposed: `Rpc.Protocol` and `Rpc` name them by aliases.
They are defined in a module that imports nothing, so that `Proto.Method`
can index a method by them without importing an `Rpc` module, and they have
no values: a tag is only ever a type.
-}


{-| proto3 JSON.
-}
type Json
    = Json Never


{-| Protobuf binary.
-}
type Proto
    = Proto Never
