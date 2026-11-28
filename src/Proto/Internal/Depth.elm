module Proto.Internal.Depth exposing (limit, tooDeep, tooDeepText)

{-| The nesting limit of a read, the one definition every reader takes it
from: `Proto.Binary`, `Proto.Json.Decode`, `Proto.Value`, `Proto.Internal.ValueJson`
and `Proto.Internal.Registry`. It imports nothing of the package, so any of
them can import it, and a program links only what it uses of it.

A level is a message that nests (one that reaches a cycle of references, a
`Value`, `Struct` or `ListValue`, or an `Any`), the outermost at 1, an
`Any`, or an array or object of a `Value`, `Struct` or `ListValue`; all count against [`limit`](#limit). Every reader compares the
same way: a read at depth `d` enters the level below only while
`d < limit`, at `d + 1`, so 100 levels read and the 101st is the first
refused. A table of readers by depth holds one per depth a read can be at:
`limit` of them for messages (depths 1 to 100), `limit + 1` for a `Value`,
whose depth starts at 0 outside any array or object.

The places that write the number out, for a change of the limit, are listed
in design §5.5.

-}

import Json.Decode exposing (Decoder)


{-| The most levels a read nests: messages that nest, `Any` values and the
arrays and objects of a `Value` count against one budget, as
protobuf's own runtimes allow. The generator's `ir::nesting::LIMIT` is the
same number, held to it by `crates/elm-connect-gen/tests/lockstep.rs`.
-}
limit : Int
limit =
    100


{-| The text a JSON read fails with past the limit. It states the limit, and
a test holds it to [`limit`](#limit).
-}
tooDeepText : String
tooDeepText =
    "Expecting messages nested at most 100 deep"


{-| The failure past the limit.
-}
tooDeep : Decoder a
tooDeep =
    Json.Decode.fail tooDeepText
