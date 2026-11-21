module Proto.Internal.Guard exposing (run)

{-| A step run so that a JavaScript exception in it, a stack overflow on a
value nested too deeply, becomes `Nothing` instead of escaping.

elm/json's `decodeString` runs `JSON.parse` and the whole decoder inside one
`try`/`catch` and turns anything thrown into an `Err`; the step is run as
the function of a `Json.Decode.map` over the text `0`, so it runs inside
that `try`. Pure Elm promises nothing of the kind: this rests on how elm/json
1.1.3 and 1.1.4 write `_Json_runOnString`, and `tests/Proto/GuardTest.elm`
fails if a release stops catching. The step is pure, so a step cut short
leaves nothing behind but the garbage it allocated. A JSON-only program
links nothing more for it: elm/json is already there.

-}

import Json.Decode


{-| `Just` the step's value, or `Nothing` when it threw.
-}
run : (() -> a) -> Maybe a
run step =
    case Json.Decode.decodeString (Json.Decode.map step (Json.Decode.succeed ())) "0" of
        Ok value ->
            Just value

        Err _ ->
            Nothing
