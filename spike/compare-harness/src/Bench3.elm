port module Bench3 exposing (main)

{-| Time one library's generated codecs of the reduced codec corpus, the same
way `spike/codec-harness/src/Bench2.elm` times elm-connect's: `side` is
`ours` or `epb`. `init` prepares the inputs, untimed; each message on `go`
runs one mode `rounds` times and answers on `done` (spike/compare-bench.js).

The inputs are the corpus samples (prost-reflect's binary and canonical
JSON) whose JSON does not name `KIND_NEGATIVE`, the value the reduced corpus
drops, or the 1,000-leaf `Repeated`, whose binary elm-connect's encoder
writes once for both sides.

-}

import Bytes exposing (Bytes)
import Bytes.Decode
import Bytes.Encode
import Dict
import Entry exposing (Entry)
import EpbCodecs
import Generated.Codec.Data
import OursCodecs


port go : ({ mode : String, rounds : Int } -> msg) -> Sub msg


port done : Int -> Cmd msg


port texts : List String -> Cmd msg


type alias Input =
    { entry : Entry, json : String, binary : Bytes, name : String, bothReadJson : Bool }


main : Program { side : String, message : String, large : String } (List Input) { mode : String, rounds : Int }
main =
    Platform.worker
        { init = \flags -> ( prepare flags, Cmd.none )
        , update = \job inputs -> ( inputs, run job inputs )
        , subscriptions = \_ -> go identity
        }


prepare : { side : String, message : String, large : String } -> List Input
prepare flags =
    let
        table =
            if flags.side == "epb" then
                EpbCodecs.table

            else
                OursCodecs.table
    in
    if flags.large /= "" then
        Maybe.map2 (\e binary -> [ Input e flags.large binary "1,000 leaves" True ])
            (Dict.get "codec.v1.Repeated" table)
            (Dict.get "codec.v1.Repeated" OursCodecs.table |> Maybe.andThen (\o -> o.toBinary flags.large))
            |> Maybe.withDefault []

    else
        Generated.Codec.Data.samples
            |> List.filter (\s -> (flags.message == "*" || s.message == flags.message) && not (String.contains "KIND_NEGATIVE" s.canonical))
            |> List.filterMap
                (\s ->
                    Maybe.map2 (\e b -> Input e s.canonical b s.name (readsJson OursCodecs.table s && readsJson EpbCodecs.table s))
                        (Dict.get s.message table)
                        (fromHex s.binary)
                )


{-| Whether a library's JSON decoder reads the sample's canonical JSON: the
JSON modes time only the samples both read.
-}
readsJson : Dict.Dict String Entry -> { s | message : String, canonical : String } -> Bool
readsJson table s =
    Dict.get s.message table |> Maybe.map (\e -> e.decodeJson s.canonical) |> Maybe.withDefault False


run : { mode : String, rounds : Int } -> List Input -> Cmd msg
run job allInputs =
    let
        inputs =
            if String.contains "Json" job.mode then
                List.filter .bothReadJson allInputs

            else
                allInputs
    in
    case job.mode of
        "wire" ->
            texts (List.map (.binary >> toHex) inputs)

        "wireJson" ->
            texts (List.map .json inputs)

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

        "failures" ->
            texts
                (List.filterMap
                    (\i ->
                        if i.entry.decodeJson i.json && i.entry.decodeBinary i.binary then
                            Nothing

                        else
                            Just
                                (i.name
                                    ++ (if i.entry.decodeJson i.json then
                                            ""

                                        else
                                            " [json] " ++ Maybe.withDefault "" (i.entry.jsonError i.json)
                                       )
                                    ++ (if i.entry.decodeBinary i.binary then
                                            ""

                                        else
                                            " [binary]"
                                       )
                                )
                    )
                    inputs
                )

        "encodedWire" ->
            texts (List.filterMap (\i -> i.entry.prepareBinary i.binary |> Maybe.map (\thunk -> toHex (thunk ()))) inputs)

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
