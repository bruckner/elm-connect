port module Bench exposing (main)

{-| Time the generated codecs: `init` runs the work, so the time around
`Elm.Bench.init` is the time it took (spike/codec-bench.js).

Flags: `mode` is `decode` (decode every input `rounds` times) or `encode`
(decode every input once, then encode it `rounds` times) or `dump`
(send the inputs through `texts`); `message` keeps
the samples of one message (`*` for all); `large`, when not empty, is the
one input instead of the samples, a `codec.v1.Repeated`.
-}

import Dict
import Generated.Codec.Data
import JsonCodecs


port done : Int -> Cmd msg


port texts : List ( String, String ) -> Cmd msg


type alias Flags =
    { mode : String
    , message : String
    , rounds : Int
    , large : String
    }


main : Program Flags () ()
main =
    Platform.worker
        { init =
            \flags ->
                if flags.mode == "dump" then
                    ( (), texts (inputs flags) )

                else
                    ( (), done (run flags) )
        , update = \_ model -> ( model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }


inputs : Flags -> List ( String, String )
inputs flags =
    if flags.large /= "" then
        [ ( "codec.v1.Repeated", flags.large ) ]

    else
        Generated.Codec.Data.samples
            |> List.filter (\s -> flags.message == "*" || s.message == flags.message)
            |> List.map (\s -> ( s.message, s.canonical ))


run : Flags -> Int
run flags =
    let
        found =
            inputs flags
                |> List.filterMap (\( name, input ) -> Dict.get name JsonCodecs.table |> Maybe.map (\e -> ( e, input )))
    in
    case flags.mode of
        "decode" ->
            repeat flags.rounds 0 (\acc -> List.foldl (\( e, input ) n -> if e.decode input then n + 1 else n) acc found)

        _ ->
            let
                thunks =
                    List.filterMap (\( e, input ) -> e.prepare input) found
            in
            repeat flags.rounds 0 (\acc -> List.foldl (\thunk n -> n + String.length (thunk ())) acc thunks)


repeat : Int -> Int -> (Int -> Int) -> Int
repeat n acc step =
    if n <= 0 then
        acc

    else
        repeat (n - 1) (step acc) step
