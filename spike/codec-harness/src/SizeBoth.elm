port module SizeBoth exposing (main)

{-| Every JSON and binary codec of the codec corpus under `codec=both`,
reachable: decode `input` as `message`, as JSON or as base64 binary as
`binary` says, and send back its re-encoding in the same form. Measured
against SizeNullBytes.
-}

import BothCodecs
import Dict
import Proto.Bytes


port done : String -> Cmd msg


main : Program { message : String, input : String, binary : Bool } () ()
main =
    Platform.worker
        { init =
            \flags ->
                ( ()
                , Dict.get flags.message BothCodecs.table
                    |> Maybe.andThen
                        (\e ->
                            if flags.binary then
                                Proto.Bytes.fromBase64 flags.input
                                    |> Maybe.andThen e.prepareBinary
                                    |> Maybe.map (\thunk -> Proto.Bytes.toBase64 (thunk ()))

                            else
                                e.prepareJson flags.input |> Maybe.map (\thunk -> thunk ())
                        )
                    |> Maybe.withDefault ""
                    |> done
                )
        , update = \_ model -> ( model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
