module Proto.JsonTryTest exposing (suite)

import Dict
import Expect
import Json.Encode exposing (Value)
import Proto.Json as Json
import Test exposing (Test, describe, test)


{-| An encoder that fails on negative numbers, naming the first.
-}
positive : Int -> Result String Value
positive n =
    if n < 0 then
        Err ("negative " ++ String.fromInt n)

    else
        Ok (Json.Encode.int n)


written : Result String (Maybe Value) -> Result String (Maybe String)
written =
    Result.map (Maybe.map (Json.Encode.encode 0))


suite : Test
suite =
    describe "Proto.Json's encoders that can fail"
        [ test "an object of fields, the ones given Nothing left out" <|
            \_ ->
                Json.tryObjectOfFields
                    [ ( "a", Ok (Just (Json.Encode.int 1)) )
                    , ( "b", Ok Nothing )
                    , ( "c", Result.map Just (positive 2) )
                    ]
                    |> Result.map (Json.Encode.encode 0)
                    |> Expect.equal (Ok "{\"a\":1,\"c\":2}")
        , test "an object fails with its first field's Err" <|
            \_ ->
                Json.tryObjectOfFields
                    [ ( "a", Ok Nothing )
                    , ( "b", Result.map Just (positive -1) )
                    , ( "c", Result.map Just (positive -2) )
                    ]
                    |> Result.map (Json.Encode.encode 0)
                    |> Expect.equal (Err "negative -1")
        , test "an optional field: Nothing is left out, Just is its value or its Err" <|
            \_ ->
                [ Json.tryOptionalField positive Nothing
                , Json.tryOptionalField positive (Just 3)
                , Json.tryOptionalField positive (Just -3)
                ]
                    |> List.map written
                    |> Expect.equal [ Ok Nothing, Ok (Just "3"), Err "negative -3" ]
        , test "a repeated field: empty is left out, else the array or the first Err" <|
            \_ ->
                [ Json.tryRepeatedField positive []
                , Json.tryRepeatedField positive [ 1, 2 ]
                , Json.tryRepeatedField positive [ 1, -2, -3 ]
                ]
                    |> List.map written
                    |> Expect.equal [ Ok Nothing, Ok (Just "[1,2]"), Err "negative -2" ]
        , test "a map field: empty is left out, else the object or the first Err by key" <|
            \_ ->
                [ Json.tryDictField String.fromInt positive Dict.empty
                , Json.tryDictField String.fromInt positive (Dict.fromList [ ( 2, 20 ), ( 1, 10 ) ])
                , Json.tryDictField String.fromInt positive (Dict.fromList [ ( 2, -20 ), ( 1, -10 ) ])
                ]
                    |> List.map written
                    |> Expect.equal [ Ok Nothing, Ok (Just "{\"1\":10,\"2\":20}"), Err "negative -10" ]
        , test "a map field keeps a __proto__ key" <|
            \_ ->
                Json.tryDictField identity positive (Dict.fromList [ ( "__proto__", 1 ) ])
                    |> written
                    |> Expect.equal (Ok (Just "{\"__proto__\":1}"))
        , test "a bool-keyed map: empty is left out, else the object or the first Err" <|
            \_ ->
                [ Json.tryBoolMapField positive []
                , Json.tryBoolMapField positive [ ( False, 0 ), ( True, 1 ) ]
                , Json.tryBoolMapField positive [ ( False, 0 ), ( True, -1 ) ]
                ]
                    |> List.map written
                    |> Expect.equal [ Ok Nothing, Ok (Just "{\"false\":0,\"true\":1}"), Err "negative -1" ]
        ]
