module Proto.Internal.ValueJson exposing (Kinds(..), level, limit, tooDeep)

{-| The JSON decoders of a `google.protobuf.Value`, one per nesting depth.
They are written over the six kinds, not over `Proto.Value.Value` itself, so
that both `Proto.Value` and `Proto.Json` can build their table from them:
`Proto.Json` imports `Proto.Value`, which therefore cannot import a module
that imports it back.

Each module keeps its table as a top-level `Array` of `limit + 1` decoders,
built once, as `Proto.Json` keeps a recursive message's decoders by depth.
A decoder reads the members of an array or object with the next depth's
decoder, so a read can never go deeper than the table, and fails past the
limit instead of overflowing the stack.

-}

import Dict exposing (Dict)
import Json.Decode exposing (Decoder)


{-| The constructors of the six kinds of JSON: null, bool, number, string,
object and array. Positional rather than a record: Elm's optimized output
names record fields by their use across every module a program loads, so
new field names would rename fields in programs that never read a `Value`.
-}
type Kinds v
    = Kinds v (Bool -> v) (Float -> v) (String -> v) (Dict String v -> v) (List v -> v)


{-| The decoder of a value at `depth`, whose arrays' and objects' members
`next` reads one level deeper. At the limit an array or object fails.

The value's kind is found first and then read, rather than each kind tried in
a `oneOf`: a `oneOf` that fails keeps every way it failed, so a value refused
at the limit would carry six failures at each level above it.

-}
level : Kinds v -> (Int -> Decoder v) -> Int -> Decoder v
level ((Kinds _ _ _ _ struct list) as kinds) next depth =
    let
        child =
            Json.Decode.lazy (\_ -> next (depth + 1))
    in
    kindOf kinds
        |> Json.Decode.andThen
            (\found ->
                case found of
                    Scalar value ->
                        Json.Decode.succeed value

                    Array ->
                        if depth < limit then
                            Json.Decode.map list (Json.Decode.list child)

                        else
                            tooDeep

                    Object ->
                        if depth < limit then
                            Json.Decode.map struct (Json.Decode.dict child)

                        else
                            tooDeep
            )


type Kind v
    = Scalar v
    | Array
    | Object


{-| A scalar read, or which container the JSON is. Anything else is taken
for an object, which then fails to read as one.
-}
kindOf : Kinds v -> Decoder (Kind v)
kindOf (Kinds null bool number string _ _) =
    Json.Decode.oneOf
        [ Json.Decode.map (number >> Scalar) Json.Decode.float
        , Json.Decode.map (string >> Scalar) Json.Decode.string
        , Json.Decode.map (bool >> Scalar) Json.Decode.bool
        , Json.Decode.null (Scalar null)
        , Json.Decode.map (\_ -> Array) (Json.Decode.list (Json.Decode.succeed ()))
        , Json.Decode.succeed Object
        ]


{-| The most levels a read nests: messages entered along a cycle, `Any`
values and the arrays and objects of a `Value` count against one budget.
-}
limit : Int
limit =
    100


{-| The failure past the limit, the same text as a message's.
-}
tooDeep : Decoder a
tooDeep =
    Json.Decode.fail "Expecting messages nested at most 100 deep"
