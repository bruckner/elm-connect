port module SizeBinary exposing (main)

{-| Every binary codec of the codec corpus under `codec=binary`, reachable:
decode `input` (base64) as `message` and send back its re-encoding. Measured
against SizeNullBytes.
-}

import BinaryCodecs
import Dict


port done : String -> Cmd msg


main : Program { message : String, input : String } () ()
main =
    Platform.worker
        { init =
            \flags ->
                ( ()
                , Dict.get flags.message BinaryCodecs.table
                    |> Maybe.andThen (\f -> f flags.input)
                    |> Maybe.withDefault ""
                    |> done
                )
        , update = \_ model -> ( model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
