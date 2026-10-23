module Snippets.Reading exposing (Model, Msg(..), describe, update)

{-| docs/quickstart.md's "Read the result": a call's result, and one `case` on
the kinds of `Rpc.Error`.
-}

-- region reading

import Notes.V1
import Rpc
import Rpc.Code
import Rpc.Error


type Msg
    = GotNote (Result Rpc.Error Notes.V1.Note)


type alias Model =
    { note : Maybe Notes.V1.Note
    , problem : Maybe String
    }


update : Msg -> Model -> Model
update msg model =
    case msg of
        GotNote (Ok note) ->
            { model | note = Just note, problem = Nothing }

        GotNote (Err error) ->
            { model | problem = Just (describe error) }


describe : Rpc.Error -> String
describe error =
    case error of
        Rpc.Error.RpcStatus status _ ->
            -- The server stated a status: a Connect error body, a
            -- google.rpc.Status body or the grpc-status headers.
            Rpc.Code.toString status.code ++ ": " ++ status.message

        Rpc.Error.HttpStatus response ->
            -- A failure with no status in it, such as a proxy's 502 page.
            "HTTP " ++ String.fromInt response.statusCode

        Rpc.Error.BadResponse problem _ ->
            -- A success whose body is not the response.
            "unexpected answer: " ++ problem

        Rpc.Error.NoAnswer _ ->
            -- A timeout, a network failure, or a call that was never sent.
            Rpc.Error.toString error



-- endregion reading
