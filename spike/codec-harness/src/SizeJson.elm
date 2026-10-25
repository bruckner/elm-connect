port module SizeJson exposing (main)

{-| Every JSON codec of the codec corpus, reachable: decode `input` as
`message` and send back its re-encoding. Measured against SizeNull.
-}

import Dict
import JsonCodecs


port done : String -> Cmd msg


main : Program { message : String, input : String } () ()
main =
    Platform.worker
        { init =
            \flags ->
                ( ()
                , Dict.get flags.message JsonCodecs.table
                    |> Maybe.andThen (\e -> e.prepare flags.input)
                    |> Maybe.map (\thunk -> thunk ())
                    |> Maybe.withDefault ""
                    |> done
                )
        , update = \_ model -> ( model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
