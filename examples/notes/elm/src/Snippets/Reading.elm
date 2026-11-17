module Snippets.Reading exposing (Model, Msg(..), describe, slowDown, update)

{-| docs/quickstart.md's "Read the result": a call's result, and one `case` on
the `Rpc.Error`'s response; and docs/calling.md's check that the server
stated the code.
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
    case Rpc.Error.response error of
        Ok _ ->
            -- The server answered with a failure: the status it stated, or
            -- one inferred from the HTTP status, as of a proxy's 502 page.
            Rpc.Error.toString error

        Err (Rpc.Error.BadResponse _) ->
            -- A success that could not be read as the response.
            "unexpected answer: " ++ Rpc.Error.message error

        Err Rpc.Error.Timeout ->
            "no answer in time"

        Err Rpc.Error.NetworkError ->
            "the server could not be reached"

        Err Rpc.Error.BadCall ->
            -- Nothing was sent: a bad URL or header, say.
            Rpc.Error.toString error



-- endregion reading
-- region server-said


{-| Whether the server asked the caller to slow down: a `ResourceExhausted`
it stated, not the client's for a request over its limit, nor one inferred
from an edge's bare status.
-}
slowDown : Rpc.Error -> Bool
slowDown error =
    Rpc.Error.source error /= Nothing && Rpc.Error.code error == Rpc.Code.ResourceExhausted



-- endregion server-said
