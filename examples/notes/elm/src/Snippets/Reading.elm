module Snippets.Reading exposing (Model, Msg(..), describe, update)

{-| docs/quickstart.md's "Read the result": a call's result, and one `case` on
who produced the `Rpc.Error`.
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
    case Rpc.Error.cause error of
        Nothing ->
            -- The server answered with a failure: the status it stated, or
            -- one inferred from the HTTP status, as of a proxy's 502 page.
            Rpc.Code.toString (Rpc.Error.code error) ++ ": " ++ Rpc.Error.message error

        Just Rpc.Error.BadResponse ->
            -- A success that could not be read as the response.
            "unexpected answer: " ++ Rpc.Error.message error

        Just _ ->
            -- A timeout, a network failure, or a call that was never sent.
            Rpc.Error.toString error



-- endregion reading
