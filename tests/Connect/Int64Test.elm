module Connect.Int64Test exposing (suite)

import Connect.Int64
import Expect
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "Connect.Int64"
        [ describe "toInt"
            [ reads "0" (Just 0)
            , reads "-0" (Just 0)
            , reads "42" (Just 42)
            , reads "-42" (Just -42)
            , reads "9007199254740991" (Just 9007199254740991)
            , reads "-9007199254740991" (Just -9007199254740991)
            , reads "9007199254740992" Nothing
            , reads "-9007199254740992" Nothing
            , reads "9007199254740993" Nothing
            , reads "10000000000000000" Nothing
            , reads "99999999999999999999" Nothing
            , reads "007" (Just 7)
            , reads "0009007199254740991" (Just 9007199254740991)
            , reads "0009007199254740992" Nothing
            , reads "" Nothing
            , reads "-" Nothing
            , reads "+1" Nothing
            , reads "1e3" Nothing
            , reads "1.0" Nothing
            , reads " 1" Nothing
            , reads "1 " Nothing
            , reads "--1" Nothing
            , reads "0x10" Nothing
            ]
        , describe "fromInt"
            [ test "a positive Int" <|
                \_ -> Connect.Int64.fromInt 42 |> Expect.equal "42"
            , test "a negative Int" <|
                \_ -> Connect.Int64.fromInt -42 |> Expect.equal "-42"
            , test "the largest exact Int" <|
                \_ -> Connect.Int64.fromInt 9007199254740991 |> Expect.equal "9007199254740991"
            , test "the smallest exact Int" <|
                \_ -> Connect.Int64.fromInt -9007199254740991 |> Expect.equal "-9007199254740991"
            , test "round-trips through toInt" <|
                \_ ->
                    Connect.Int64.fromInt -1234567890123
                        |> Connect.Int64.toInt
                        |> Expect.equal (Just -1234567890123)
            ]
        ]


reads : String -> Maybe Int -> Test
reads text expected =
    test ("\"" ++ text ++ "\"") <|
        \_ -> Connect.Int64.toInt text |> Expect.equal expected
