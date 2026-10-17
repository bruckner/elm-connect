module Proto.EnumTest exposing (suite)

import Expect
import Json.Encode
import Proto.Enum as Enum exposing (Enum)
import Proto.EnumValue as EnumValue
import Proto.Json
import Test exposing (Test, describe, test)


type Priority
    = PriorityNone
    | PriorityHigh
    | PriorityLow


{-| An enum as generated: `URGENT` aliases `HIGH`, declared after `LOW`.
-}
enumPriority : Enum Priority
enumPriority =
    priorityAs
        (Enum.descriptor "t.v1.Priority"
            [ EnumValue.descriptor "NONE" 0
            , EnumValue.descriptor "HIGH" 2
            , EnumValue.descriptor "LOW" 1
            , EnumValue.descriptor "URGENT" 2
            ]
        )


{-| Priority's codecs under another descriptor.
-}
priorityAs : Enum.Descriptor -> Enum Priority
priorityAs =
    Enum.enum
        (\priority ->
            case priority of
                PriorityNone ->
                    Json.Encode.string "NONE"

                PriorityHigh ->
                    Json.Encode.string "HIGH"

                PriorityLow ->
                    Json.Encode.string "LOW"
        )
        (Proto.Json.enum "Priority"
            PriorityNone
            [ ( "NONE", 0, PriorityNone )
            , ( "HIGH", 2, PriorityHigh )
            , ( "URGENT", 2, PriorityHigh )
            , ( "LOW", 1, PriorityLow )
            ]
        )
        PriorityNone


suite : Test
suite =
    describe "Proto.Enum"
        [ test "the type name is the descriptor's" <|
            \_ ->
                Enum.typeName (Enum.toDescriptor enumPriority)
                    |> Expect.equal "t.v1.Priority"
        , test "a value's name is the one its encoder writes, its number the one declared for it" <|
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
        , test "a name the descriptor does not declare reads as nothing, though the decoder would take it" <|
            \_ ->
                Enum.fromName (priorityAs (Enum.descriptor "t.v1.Priority" [])) "HIGH"
                    |> Expect.equal Nothing
        ]
