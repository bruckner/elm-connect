module Proto.Internal.ValueJson exposing (Kinds, level, read)

{-| How a `google.protobuf.Value` is read from JSON, shared by `Proto.Value`
and `Proto.Json`. Each builds its own table of decoders by depth with
[`level`](#level), handing over the constructors as `Kinds`: `Proto.Json`
imports `Proto.Value`, so neither can take the other's table.
-}

import Dict exposing (Dict)
import Json.Decode exposing (Decoder)
import Proto.Internal.Depth as Depth


{-| The constructors of JSON's six kinds.
-}
type alias Kinds v =
    { null : v
    , bool : Bool -> v
    , number : Float -> v
    , string : String -> v
    , list : List v -> v
    , object : Dict String v -> v
    }


{-| The decoder of a value at `depth`: each kind tried in turn, an array's or
object's members read with `node (depth + 1)`, and an array or object at the
limit failing. The table reads in one pass, but its failure holds each way
every level above the refused one failed, so it runs only through
[`read`](#read).
-}
level : Kinds v -> (Int -> Decoder v) -> Int -> Decoder v
level kinds node depth =
    let
        member =
            Json.Decode.lazy (\_ -> node (depth + 1))

        containers =
            if depth < Depth.limit then
                [ Json.Decode.map kinds.list (Json.Decode.list member)
                , Json.Decode.map kinds.object (Json.Decode.dict member)
                ]

            else
                [ Depth.tooDeep ]
    in
    Json.Decode.oneOf
        (Json.Decode.map kinds.number Json.Decode.float
            :: Json.Decode.map kinds.string Json.Decode.string
            :: Json.Decode.map kinds.bool Json.Decode.bool
            :: Json.Decode.null kinds.null
            :: containers
        )


{-| Read the JSON with `table`, a decoder built from [`level`](#level); if it
fails, with `otherwise` instead, which fails with the error to return. The
table's own failure is dropped, so its size never reaches an error.
-}
read : Decoder a -> Decoder a -> Decoder a
read table otherwise =
    Json.Decode.value
        |> Json.Decode.andThen
            (\json ->
                case Json.Decode.decodeValue table json of
                    Ok value ->
                        Json.Decode.succeed value

                    Err _ ->
                        otherwise
            )
