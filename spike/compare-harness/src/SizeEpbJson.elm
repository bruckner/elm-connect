port module SizeEpbJson exposing (main)

{-| Every json codec of the reduced corpus by EpbCodecs, reachable: read
`input` as `message` and send back its re-encoding. Measured against
SizeNull (JSON) or SizeNullBytes (binary, both).
-}

import Dict
import EpbCodecs


port done : String -> Cmd msg


main : Program { message : String, input : String } () ()
main =
    Platform.worker
        { init =
            \flags ->
                ( ()
                , Dict.get flags.message EpbCodecs.jsonEchoes
                    |> Maybe.andThen
                        (\e ->
                            e flags.input
                        )
                    |> Maybe.withDefault ""
                    |> done
                )
        , update = \_ model -> ( model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
