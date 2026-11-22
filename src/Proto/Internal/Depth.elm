module Proto.Internal.Depth exposing (limit, tooDeep)

{-| The nesting limit of a JSON read, shared by `Proto.Json` and
`Proto.Value`: `Proto.Json` imports `Proto.Value`, so neither can take it from
the other.
-}

import Json.Decode exposing (Decoder)


{-| The most levels a read nests: messages entered along a cycle, `Any`
values and the arrays and objects of a `Value` count against one budget, as
protobuf's own runtimes allow.
-}
limit : Int
limit =
    100


{-| The failure past the limit.
-}
tooDeep : Decoder a
tooDeep =
    Json.Decode.fail "Expecting messages nested at most 100 deep"
