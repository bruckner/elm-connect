port module SizeOursBinary exposing (main)

{-| Every binary codec of the reduced corpus by OursCodecs, reachable: read
`input` as `message` and send back its re-encoding. Measured against
SizeNull (JSON) or SizeNullBytes (binary, both).
-}

import Dict
import OursCodecs
import Proto.Bytes


port done : String -> Cmd msg


main : Program { message : String, input : String } () ()
main =
    Platform.worker
        { init =
            \flags ->
                ( ()
                , Dict.get flags.message OursCodecs.binaryEchoes
                    |> Maybe.andThen
                        (\e ->
                            Proto.Bytes.fromBase64 flags.input |> Maybe.andThen e |> Maybe.map Proto.Bytes.toBase64
                        )
                    |> Maybe.withDefault ""
                    |> done
                )
        , update = \_ model -> ( model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
