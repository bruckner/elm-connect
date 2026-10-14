module Proto.EnumTest exposing (suite)

import Expect
import Json.Decode
import Json.Encode
import Proto.Enum as Enum exposing (Enum)
import Test exposing (Test, describe, test)


type Priority
    = PriorityNone
    | PriorityHigh
    | PriorityLow


{-| An enum as generated: `URGENT` aliases `HIGH`, declared after `LOW`.
-}
enumPriority : Enum Priority
enumPriority =
    { encodeJson =
        \priority ->
            case priority of
                PriorityNone ->
                    Json.Encode.string "NONE"

                PriorityHigh ->
                    Json.Encode.string "HIGH"

                PriorityLow ->
                    Json.Encode.string "LOW"
    , jsonDecoder = Json.Decode.fail "unused"
    , values =
        [ { name = "NONE", number = 0, value = PriorityNone }
        , { name = "HIGH", number = 2, value = PriorityHigh }
        , { name = "LOW", number = 1, value = PriorityLow }
        , { name = "URGENT", number = 2, value = PriorityHigh }
        ]
    , descriptor = { typeName = "t.v1.Priority", values = [] }
    }


suite : Test
suite =
    describe "Proto.Enum"
        [ test "the type name is the descriptor's" <|
            \_ ->
                Enum.typeName enumPriority
                    |> Expect.equal "t.v1.Priority"
        , test "a value's name and number are its first entry's" <|
            \_ ->
                List.map (\p -> ( Enum.toName enumPriority p, Enum.toNumber enumPriority p )) [ PriorityNone, PriorityHigh, PriorityLow ]
                    |> Expect.equal [ ( "NONE", 0 ), ( "HIGH", 2 ), ( "LOW", 1 ) ]
        , test "names, aliases included, read as their values" <|
            \_ ->
                List.map (Enum.fromName enumPriority) [ "NONE", "HIGH", "URGENT", "LOW", "low", "MEDIUM" ]
                    |> Expect.equal [ Just PriorityNone, Just PriorityHigh, Just PriorityHigh, Just PriorityLow, Nothing, Nothing ]
        , test "numbers read as their values, unknown ones as nothing" <|
            \_ ->
                List.map (Enum.fromNumber enumPriority) [ 0, 1, 2, 3, -1 ]
                    |> Expect.equal [ Just PriorityNone, Just PriorityLow, Just PriorityHigh, Nothing, Nothing ]
        , test "a value missing from the list is named by its encoder" <|
            \_ ->
                Enum.toName { enumPriority | values = [] } PriorityLow
                    |> Expect.equal "LOW"
        ]
