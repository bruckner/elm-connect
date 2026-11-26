module Snippets.WritingTest exposing (suite)

import Expect
import Json.Encode
import Proto.Error
import Proto.Json.Encode
import Snippets.Writing exposing (encodeEvent)
import Test exposing (Test, describe, test)
import Time


suite : Test
suite =
    describe "Snippets.Writing"
        [ test "writes the title, and the time when there is one" <|
            \_ ->
                Proto.Json.Encode.encode (encodeEvent { title = "launch", at = Just (Time.millisToPosix 1760116785250) })
                    |> Result.map (Json.Encode.encode 0)
                    |> Expect.equal (Ok "{\"title\":\"launch\",\"at\":\"2025-10-10T17:19:45.250Z\"}")
        , test "leaves out a missing time" <|
            \_ ->
                Proto.Json.Encode.encode (encodeEvent { title = "launch", at = Nothing })
                    |> Result.map (Json.Encode.encode 0)
                    |> Expect.equal (Ok "{\"title\":\"launch\"}")
        , test "refuses a time outside years 1 to 9999" <|
            \_ ->
                case Proto.Json.Encode.encode (encodeEvent { title = "launch", at = Just (Time.millisToPosix 253402300800000) }) of
                    Err (Proto.Error.BadValue refusal) ->
                        Expect.equal [ "at" ] refusal.path

                    other ->
                        Expect.fail ("expected a refusal, got " ++ Debug.toString other)
        ]
