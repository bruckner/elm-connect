module Proto.Internal.JsonError exposing (nestsDeeperThan, scrub)

{-| A JSON read's error made safe to print: elm/json keeps, in each
`Failure`, the JSON the failing decoder ran on, which can be nested
arbitrarily deeply, and `Json.Decode.errorToString` prints it, indented.
`scrub` keeps the error's shape, paths and texts, and replaces a failure's
JSON nested more than 50 levels deep with a short string saying so. It runs
only on a failure.
-}

import Json.Decode
import Json.Encode


{-| The error, each `Failure` whose JSON nests deeper than 50 levels holding
the marker in its place.
-}
scrub : Json.Decode.Error -> Json.Decode.Error
scrub error =
    case error of
        Json.Decode.Field name inner ->
            Json.Decode.Field name (scrub inner)

        Json.Decode.Index index inner ->
            Json.Decode.Index index (scrub inner)

        Json.Decode.OneOf ways ->
            Json.Decode.OneOf (List.map scrub ways)

        Json.Decode.Failure text json ->
            if nestsDeeperThan bound json then
                Json.Decode.Failure text marker

            else
                error


bound : Int
bound =
    50


marker : Json.Encode.Value
marker =
    Json.Encode.string "(JSON nested more than 50 levels deep, left out)"


type Node
    = Children (List Json.Decode.Value)
    | Leaf


node : Json.Decode.Decoder Node
node =
    Json.Decode.oneOf
        [ Json.Decode.map Children (Json.Decode.list Json.Decode.value)
        , Json.Decode.map (List.map Tuple.second >> Children) (Json.Decode.keyValuePairs Json.Decode.value)
        , Json.Decode.succeed Leaf
        ]


{-| Whether JSON nests deeper than `limit` levels, a scalar or an empty array
or object being one: a walk by a work list, which stops at the first value
past the limit and cannot overflow the stack however deep the JSON.
-}
nestsDeeperThan : Int -> Json.Decode.Value -> Bool
nestsDeeperThan limit json =
    walk limit [ ( 1, json ) ]


walk : Int -> List ( Int, Json.Decode.Value ) -> Bool
walk limit work =
    case work of
        [] ->
            False

        ( depth, json ) :: rest ->
            if depth > limit then
                True

            else
                case Json.Decode.decodeValue node json of
                    Ok (Children children) ->
                        walk limit (List.foldl (\child acc -> ( depth + 1, child ) :: acc) rest children)

                    _ ->
                        walk limit rest
