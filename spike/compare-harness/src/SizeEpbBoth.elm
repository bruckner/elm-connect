port module SizeEpbBoth exposing (main)

{-| Every both codec of the reduced corpus by EpbCodecs, reachable: read
`input` as `message` and send back its re-encoding. Measured against
SizeNull (JSON) or SizeNullBytes (binary, both).
-}

import Dict
import EpbCodecs
import Proto.Bytes


port done : String -> Cmd msg


main : Program { message : String, input : String } () ()
main =
    Platform.worker
        { init =
            \flags ->
                ( ()
                , Maybe.map2 Tuple.pair (Dict.get flags.message EpbCodecs.binaryEchoes) (Dict.get flags.message EpbCodecs.jsonEchoes)
                    |> Maybe.andThen
                        (\( binary, json ) ->
                            if String.startsWith "{" flags.input then
                                json flags.input

                            else
                                Proto.Bytes.fromBase64 flags.input |> Maybe.andThen binary |> Maybe.map Proto.Bytes.toBase64
                        )
                    |> Maybe.withDefault ""
                    |> done
                )
        , update = \_ model -> ( model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
