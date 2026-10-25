port module SizeNullBytes exposing (main)

{-| SizeBinary without the codecs: the same program shape, turning `input`
from base64 into bytes and back.
-}

import Dict
import Proto.Bytes


port done : String -> Cmd msg


main : Program { message : String, input : String } () ()
main =
    Platform.worker
        { init =
            \flags ->
                ( ()
                , Dict.get flags.message (Dict.fromList [ ( "codec.v1.Leaf", Proto.Bytes.fromBase64 >> Maybe.map Proto.Bytes.toBase64 ) ])
                    |> Maybe.andThen (\f -> f flags.input)
                    |> Maybe.withDefault ""
                    |> done
                )
        , update = \_ model -> ( model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
