port module Bench2 exposing (main)

{-| Time the generated JSON and binary codecs of `codec=both`. `init` turns
the inputs into what each codec reads (JSON text, or `Bytes` from the
sample's hex or from encoding the large input), untimed; each message on
`go` runs one mode `rounds` times and answers on `done`, so the time around
`go`'s send is the work's (spike/codec-bench2.js).

Modes: `decodeJson`, `encodeJson`, `decodeBinary`, `encodeBinary`, and for
the 1,000-leaf input the experiments `encodeSized`, `decodeHoisted`,
`decodeInline`. `wire` answers the inputs' binary as hex on `texts`.
-}

import BothCodecs
import Bytes exposing (Bytes)
import Bytes.Decode
import Bytes.Encode
import Dict
import Experiments
import Generated.Codec.Both.Codec.V1 as V1
import Generated.Codec.Data
import Json.Decode
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

        "decodeJson" ->
            done (repeat job.rounds 0 (\acc -> List.foldl (\i n -> count (i.entry.decodeJson i.json) n) acc inputs))

        "decodeBinary" ->
            done (repeat job.rounds 0 (\acc -> List.foldl (\i n -> count (i.entry.decodeBinary i.binary) n) acc inputs))

        "encodeJson" ->
            let
                thunks =
                    List.filterMap (\i -> i.entry.prepareJson i.json) inputs
            in
            done (repeat job.rounds 0 (\acc -> List.foldl (\thunk n -> n + String.length (thunk ())) acc thunks))

        "encodeBinary" ->
            let
                thunks =
                    List.filterMap (\i -> i.entry.prepareBinary i.binary) inputs
            in
            done (repeat job.rounds 0 (\acc -> List.foldl (\thunk n -> n + Bytes.width (thunk ())) acc thunks))

        "encodeSized" ->
            let
                values =
                    List.filterMap (\i -> Proto.Binary.decode V1.decodeRepeatedBytes i.binary) inputs
            in
            done (repeat job.rounds 0 (\acc -> List.foldl (\v n -> n + Bytes.width (Proto.Binary.encode Experiments.encodeRepeatedSized v)) acc values))

        "decodeHoisted" ->
            done (repeat job.rounds 0 (\acc -> List.foldl (\i n -> count (isJust (Proto.Binary.decode Experiments.decodeRepeatedHoisted i.binary)) n) acc inputs))

        "decodeInline" ->
            done (repeat job.rounds 0 (\acc -> List.foldl (\i n -> count (isJust (Proto.Binary.decode Experiments.decodeRepeatedInline i.binary)) n) acc inputs))

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


isJust : Maybe a -> Bool
isJust m =
    case m of
        Just _ ->
            True

        Nothing ->
            False
