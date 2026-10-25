port module SizeNull exposing (main)

{-| SizeJson without the codecs: the same program shape, echoing `input`.
-}

import Dict


port done : String -> Cmd msg


main : Program { message : String, input : String } () ()
main =
    Platform.worker
        { init =
            \flags ->
                ( ()
                , Dict.get flags.message (Dict.fromList [ ( "codec.v1.Leaf", identity ) ])
                    |> Maybe.map (\f -> f flags.input)
                    |> Maybe.withDefault ""
                    |> done
                )
        , update = \_ model -> ( model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
