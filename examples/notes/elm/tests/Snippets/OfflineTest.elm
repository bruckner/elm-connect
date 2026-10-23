module Snippets.OfflineTest exposing (suite)

{-| docs/quickstart.md's "Test without a server": what a call sends, and how
it reads an answer, checked with the pure halves.
-}

-- region offline

import Dict
import Expect
import Http
import Notes.V1.NotesService as Notes
import Rpc
import Rpc.Code
import Rpc.Error
import Test exposing (Test, describe, test)


config : Rpc.Config
config =
    Rpc.config "https://api.example.com"


answer : Int -> String -> Http.Response String
answer status body =
    let
        metadata =
            { url = "", statusCode = status, statusText = "", headers = Dict.empty }
    in
    if status == 200 then
        Http.GoodStatus_ metadata body

    else
        Http.BadStatus_ metadata body


suite : Test
suite =
    describe "GetNote"
        [ test "is a POST to its Connect path" <|
            \_ ->
                (Rpc.request config (Notes.getNote { name = "notes/42" })).url
                    |> Expect.equal "https://api.example.com/notes.v1.NotesService/GetNote"
        , test "reads a note" <|
            \_ ->
                answer 200 """{"name": "notes/42", "title": "groceries"}"""
                    |> Rpc.response config (Notes.getNote { name = "notes/42" })
                    |> Result.map .title
                    |> Expect.equal (Ok "groceries")
        , test "reads a Connect error" <|
            \_ ->
                answer 404 """{"code": "not_found", "message": "no such note"}"""
                    |> Rpc.response config (Notes.getNote { name = "notes/42" })
                    |> Result.mapError Rpc.Error.code
                    |> Expect.equal (Err Rpc.Code.NotFound)
        ]



-- endregion offline
