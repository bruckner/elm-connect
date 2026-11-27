module Answers exposing (heldAnswer, metadata)

{-| An answer for the tests that read one: what `elm/http` reports of an
answer to [`Notes`](Notes)' `GetNote`, to hand to `Rpc.response` or
`Rpc.responseBytes`, and the answer an error holds.
-}

import Dict
import Http
import Rpc
import Rpc.Error exposing (Cause(..), Error)


{-| An answer to `GetNote` with this status and these headers, and no status
text.
-}
metadata : Int -> List ( String, String ) -> Http.Metadata
metadata status headers =
    { url = "https://api.example.com/notes.v1.Notes/GetNote"
    , statusCode = status
    , statusText = ""
    , headers = Dict.fromList headers
    }


{-| The answer an error holds, a failure's or a success it could not use.
-}
heldAnswer : Error -> Maybe Rpc.Response
heldAnswer error =
    case Rpc.Error.cause error of
        BadStatus answer ->
            Just answer

        BadResponse answer ->
            Just answer

        BadCall ->
            Nothing

        NetworkError ->
            Nothing

        Timeout ->
            Nothing
