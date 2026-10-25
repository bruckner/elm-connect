module Proto.SurrogateTest exposing (suite)

{-| Text holding a lone low surrogate (U+DC00 to U+DFFF without the high half
before it), which elm/core's `String.foldr`, `String.toList`, `String.any`
and `String.all` misread: they take it together with the code unit before it,
and at the start of a string with what lies before the string, where some of
them never return. Every reader of text here refuses such text, or keeps it as
it is, and returns.
-}

import Expect
import Json.Decode
import Proto.Bytes
import Proto.Duration
import Proto.Int64
import Proto.Json
import Proto.Timestamp
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "a lone low surrogate"
        [ test "is not a timestamp's fraction" <|
            \_ ->
                [ "1970-01-01T00:00:00.\u{DC00}Z", "1970-01-01T00:00:00.5\u{DC00}Z", "1970-01-01T00:00:00.\u{DC00}5Z" ]
                    |> List.map Proto.Timestamp.fromString
                    |> Expect.equal [ Nothing, Nothing, Nothing ]
        , test "is not in a timestamp read from JSON" <|
            \_ ->
                Json.Decode.decodeString Proto.Json.timestamp "\"1970-01-01T00:00:00.\\udc00Z\""
                    |> Result.toMaybe
                    |> Expect.equal Nothing
        , test "is not base64" <|
            \_ ->
                [ "\u{DC00}AAA", "AA\u{DC00}A", "AAAA\u{DC00}", "\u{DC00}", "\u{DC00}=" ]
                    |> List.map (Proto.Bytes.fromBase64 >> Maybe.map (\_ -> ()))
                    |> Expect.equal [ Nothing, Nothing, Nothing, Nothing, Nothing ]
        , test "is not base64 read from JSON" <|
            \_ ->
                [ "\"\\udc00AAA\"", "\"AA\\udc00A\"", "\"\\udc00+-\"" ]
                    |> List.map (Json.Decode.decodeString Proto.Json.bytes >> Result.toMaybe)
                    |> Expect.equal [ Nothing, Nothing, Nothing ]
        , test "is not a digit of a 64-bit integer" <|
            \_ ->
                ( List.map Proto.Int64.toInt [ "1\u{DC00}2", "\u{DC00}1", "12\u{DC00}" ]
                , List.map (Json.Decode.decodeString Proto.Json.int64 >> Result.toMaybe) [ "\"1\\udc002\"", "\"\\udc001\"" ]
                )
                    |> Expect.equal ( [ Nothing, Nothing, Nothing ], [ Nothing, Nothing ] )
        , test "is not a digit of a duration" <|
            \_ ->
                [ "1.\u{DC00}s", "1\u{DC00}2s", "\u{DC00}s" ]
                    |> List.map (Proto.Duration.fromString >> Maybe.map (\_ -> ()))
                    |> Expect.equal [ Nothing, Nothing, Nothing ]
        , test "stays as it is in a field mask's paths" <|
            \_ ->
                Json.Decode.decodeString Proto.Json.fieldMask "\"\\udc00Ab,a.b\\udc00C\""
                    |> Expect.equal (Ok [ "\u{DC00}_ab", "a.b\u{DC00}_c" ])
        ]
