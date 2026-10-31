port module Bench exposing (main)

{-| Time the generated binary decoders of `codec=both`, whichever form of
`merge*Bytes` the build's generated module has. `init` turns the inputs
into `Bytes` (from the sample's hex, or by encoding the large input),
untimed; each message on `go` runs one mode `rounds` times and answers on
`done`, so the time around `go`'s send is the work's (spike/merge-bench.js).

Modes: `decodeBinary`, `encodeBinary`; `wire` answers the inputs' binary as
hex on `texts`, `roundTrip` each input decoded and encoded again (`FAIL`
when it does not decode), to check two builds decode alike.

-}

import BothCodecs
import Bytes exposing (Bytes)
import Bytes.Decode
import Bytes.Encode
import Dict
import Generated.Codec.Data
import Proto.Binary


port go : ({ mode : String, rounds : Int } -> msg) -> Sub msg


port done : Int -> Cmd msg


port texts : List String -> Cmd msg


type alias Input =
    { entry : BothCodecs.Entry, json : String, binary : Bytes }


main : Program { message : String, large : String } (List Input) { mode : String, rounds : Int }
main =
    Platform.worker
        { init = \flags -> ( prepare flags, Cmd.none )
        , update = \job inputs -> ( inputs, run job inputs )
        , subscriptions = \_ -> go identity
        }


prepare : { message : String, large : String } -> List Input
prepare flags =
    if flags.large /= "" then
        Dict.get "codec.v1.Repeated" BothCodecs.table
            |> Maybe.andThen (\e -> e.toBinary flags.large |> Maybe.map (Input e flags.large))
            |> Maybe.map List.singleton
            |> Maybe.withDefault []

    else
        Generated.Codec.Data.samples
            |> List.filter (\s -> flags.message == "*" || s.message == flags.message)
            |> List.filterMap
                (\s ->
                    Maybe.map2 (\e b -> Input e s.canonical b)
                        (Dict.get s.message BothCodecs.table)
                        (fromHex s.binary)
                )


run : { mode : String, rounds : Int } -> List Input -> Cmd msg
run job inputs =
    case job.mode of
        "wire" ->
            texts (List.map (.binary >> toHex) inputs)

        "decodeBinary" ->
            done (repeat job.rounds 0 (\acc -> List.foldl (\i n -> count (i.entry.decodeBinary i.binary) n) acc inputs))

        "encodeBinary" ->
            let
                thunks =
                    List.filterMap (\i -> i.entry.prepareBinary i.binary) inputs
            in
            done (repeat job.rounds 0 (\acc -> List.foldl (\thunk n -> n + Bytes.width (thunk ())) acc thunks))

        "roundTrip" ->
            texts
                (List.map
                    (\i ->
                        case i.entry.prepareBinary i.binary of
                            Just thunk ->
                                toHex (thunk ())

                            Nothing ->
                                "FAIL"
                    )
                    inputs
                )

        _ ->
            done -1


count : Bool -> Int -> Int
count ok n =
    if ok then
        n + 1

    else
        n


repeat : Int -> Int -> (Int -> Int) -> Int
repeat n acc step =
    if n <= 0 then
        acc

    else
        repeat (n - 1) (step acc) step


fromHex : String -> Maybe Bytes
fromHex hex =
    let
        digit c =
            String.indexes (String.fromChar c) "0123456789abcdef" |> List.head

        go_ chars acc =
            case chars of
                a :: b :: rest ->
                    case ( digit a, digit b ) of
                        ( Just x, Just y ) ->
                            go_ rest (Bytes.Encode.unsignedInt8 (x * 16 + y) :: acc)

                        _ ->
                            Nothing

                [] ->
                    Just (Bytes.Encode.encode (Bytes.Encode.sequence (List.reverse acc)))

                _ ->
                    Nothing
    in
    go_ (String.toList hex) []


toHex : Bytes -> String
toHex bytes =
    Bytes.Decode.decode
        (Bytes.Decode.loop ( Bytes.width bytes, [] )
            (\( left, acc ) ->
                if left == 0 then
                    Bytes.Decode.succeed (Bytes.Decode.Done (String.concat (List.reverse acc)))

                else
                    Bytes.Decode.map (\b -> Bytes.Decode.Loop ( left - 1, hexByte b :: acc )) Bytes.Decode.unsignedInt8
            )
        )
        bytes
        |> Maybe.withDefault ""


hexByte : Int -> String
hexByte b =
    String.slice (b // 16) (b // 16 + 1) "0123456789abcdef" ++ String.slice (modBy 16 b) (modBy 16 b + 1) "0123456789abcdef"
