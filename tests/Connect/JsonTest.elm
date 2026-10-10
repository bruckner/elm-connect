module Connect.JsonTest exposing (suite)

import Connect.Json
import Expect
import Json.Decode exposing (Decoder)
import Json.Encode
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "Connect.Json"
        [ fieldTests
        , fieldEitherTests
        , presenceTests
        , int32Tests
        , int64Tests
        , floatTests
        , bytesTests
        ]


type alias Pair =
    { name : String, count : Int }


decodePair : Decoder Pair
decodePair =
    Json.Decode.succeed Pair
        |> Connect.Json.field "name" "" Json.Decode.string
        |> Connect.Json.field "count" 0 Json.Decode.int


decodes : Decoder a -> String -> a -> Expect.Expectation
decodes decoder json expected =
    Json.Decode.decodeString decoder json
        |> Expect.equal (Ok expected)


fails : Decoder a -> String -> Expect.Expectation
fails decoder json =
    case Json.Decode.decodeString decoder json of
        Ok value ->
            Expect.fail ("expected a failure, decoded " ++ Debug.toString value)

        Err _ ->
            Expect.pass


fieldTests : Test
fieldTests =
    describe "field"
        [ test "a present key decodes its value" <|
            \_ -> decodes decodePair """{"name":"a","count":3}""" (Pair "a" 3)
        , test "a missing key gives the default" <|
            \_ -> decodes decodePair """{"name":"a"}""" (Pair "a" 0)
        , test "null gives the default" <|
            \_ -> decodes decodePair """{"name":null,"count":null}""" (Pair "" 0)
        , test "an empty object gives every default" <|
            \_ -> decodes decodePair "{}" (Pair "" 0)
        , test "unknown keys are ignored" <|
            \_ -> decodes decodePair """{"other":true,"count":1}""" (Pair "" 1)
        , test "a value of the wrong type fails" <|
            \_ -> fails decodePair """{"count":"three"}"""
        , test "a value that is not an object fails" <|
            \_ -> fails decodePair "[]"
        ]


type alias Named =
    { displayName : String }


decodeNamed : Decoder Named
decodeNamed =
    Json.Decode.succeed Named
        |> Connect.Json.fieldEither "displayName" "display_name" "" Json.Decode.string


fieldEitherTests : Test
fieldEitherTests =
    describe "fieldEither"
        [ test "the JSON name" <|
            \_ -> decodes decodeNamed """{"displayName":"a"}""" (Named "a")
        , test "the proto name" <|
            \_ -> decodes decodeNamed """{"display_name":"b"}""" (Named "b")
        , test "the JSON name wins over the proto name" <|
            \_ -> decodes decodeNamed """{"display_name":"b","displayName":"a"}""" (Named "a")
        , test "neither gives the default" <|
            \_ -> decodes decodeNamed "{}" (Named "")
        , test "null under the JSON name gives the default" <|
            \_ -> decodes decodeNamed """{"displayName":null,"display_name":"b"}""" (Named "")
        , test "null under the proto name gives the default" <|
            \_ -> decodes decodeNamed """{"display_name":null}""" (Named "")
        , test "a wrong type under the proto name fails" <|
            \_ -> fails decodeNamed """{"display_name":1}"""
        ]


type alias Shapes =
    { count : Maybe Int, tags : List String }


decodeShapes : Decoder Shapes
decodeShapes =
    Json.Decode.succeed Shapes
        |> Connect.Json.field "count" Nothing (Json.Decode.map Just Connect.Json.int32)
        |> Connect.Json.field "tags" [] (Json.Decode.list Json.Decode.string)


presenceTests : Test
presenceTests =
    describe "presence and repetition"
        [ test "present values" <|
            \_ -> decodes decodeShapes """{"count":0,"tags":["a","b"]}""" (Shapes (Just 0) [ "a", "b" ])
        , test "missing keys give Nothing and []" <|
            \_ -> decodes decodeShapes "{}" (Shapes Nothing [])
        , test "null gives Nothing and []" <|
            \_ -> decodes decodeShapes """{"count":null,"tags":null}""" (Shapes Nothing [])
        , test "a null element of a list fails" <|
            \_ -> fails decodeShapes """{"tags":[null]}"""
        , test "encodeMaybe encodes a value" <|
            \_ -> encodesTo (Connect.Json.encodeMaybe Json.Encode.int (Just 3)) "3"
        , test "encodeMaybe encodes Nothing as null" <|
            \_ -> encodesTo (Connect.Json.encodeMaybe Json.Encode.int Nothing) "null"
        ]


int32Tests : Test
int32Tests =
    describe "int32"
        [ test "a number" <|
            \_ -> decodes Connect.Json.int32 "42" 42
        , test "a negative number" <|
            \_ -> decodes Connect.Json.int32 "-7" -7
        , test "an integral number written with a fraction" <|
            \_ -> decodes Connect.Json.int32 "4.0" 4
        , test "a number in exponent notation" <|
            \_ -> decodes Connect.Json.int32 "1e2" 100
        , test "a string" <|
            \_ -> decodes Connect.Json.int32 "\"42\"" 42
        , test "a negative string" <|
            \_ -> decodes Connect.Json.int32 "\"-42\"" -42
        , test "a string in exponent notation" <|
            \_ -> decodes Connect.Json.int32 "\"1e2\"" 100
        , test "a fractional number fails" <|
            \_ -> fails Connect.Json.int32 "4.5"
        , test "a fractional string fails" <|
            \_ -> fails Connect.Json.int32 "\"4.5\""
        , test "an empty string fails" <|
            \_ -> fails Connect.Json.int32 "\"\""
        , test "\"Infinity\" fails" <|
            \_ -> fails Connect.Json.int32 "\"Infinity\""
        , test "a boolean fails" <|
            \_ -> fails Connect.Json.int32 "true"
        ]


int64Tests : Test
int64Tests =
    describe "int64"
        [ test "a string" <|
            \_ -> decodes Connect.Json.int64 "\"9007199254740993\"" "9007199254740993"
        , test "a negative string" <|
            \_ -> decodes Connect.Json.int64 "\"-42\"" "-42"
        , test "a number" <|
            \_ -> decodes Connect.Json.int64 "42" "42"
        , test "a negative number" <|
            \_ -> decodes Connect.Json.int64 "-7" "-7"
        , test "a string that is not an integer fails" <|
            \_ -> fails Connect.Json.int64 "\"4.2\""
        , test "an empty string fails" <|
            \_ -> fails Connect.Json.int64 "\"\""
        , test "a fractional number fails" <|
            \_ -> fails Connect.Json.int64 "4.2"
        , test "a boolean fails" <|
            \_ -> fails Connect.Json.int64 "true"
        , test "encodes as a string" <|
            \_ ->
                Connect.Json.encodeInt64 "9007199254740993"
                    |> Json.Encode.encode 0
                    |> Expect.equal "\"9007199254740993\""
        ]


floatTests : Test
floatTests =
    describe "float"
        [ test "a number" <|
            \_ -> decodes Connect.Json.float "1.5" 1.5
        , test "an integral number" <|
            \_ -> decodes Connect.Json.float "2" 2
        , test "a numeric string" <|
            \_ -> decodes Connect.Json.float "\"1.5\"" 1.5
        , test "\"NaN\"" <|
            \_ ->
                Json.Decode.decodeString Connect.Json.float "\"NaN\""
                    |> Result.map isNaN
                    |> Expect.equal (Ok True)
        , test "\"Infinity\"" <|
            \_ -> decodes Connect.Json.float "\"Infinity\"" (1 / 0)
        , test "\"-Infinity\"" <|
            \_ -> decodes Connect.Json.float "\"-Infinity\"" -(1 / 0)
        , test "another string fails" <|
            \_ -> fails Connect.Json.float "\"infinity\""
        , test "a boolean fails" <|
            \_ -> fails Connect.Json.float "false"
        , test "encodes a finite value as a number" <|
            \_ -> encodesTo (Connect.Json.encodeFloat 1.5) "1.5"
        , test "encodes NaN as a string" <|
            \_ -> encodesTo (Connect.Json.encodeFloat (0 / 0)) "\"NaN\""
        , test "encodes infinity as a string" <|
            \_ -> encodesTo (Connect.Json.encodeFloat (1 / 0)) "\"Infinity\""
        , test "encodes negative infinity as a string" <|
            \_ -> encodesTo (Connect.Json.encodeFloat -(1 / 0)) "\"-Infinity\""
        ]


bytesTests : Test
bytesTests =
    describe "bytes"
        [ test "a string passes through" <|
            \_ -> decodes Connect.Json.bytes "\"aGk=\"" "aGk="
        , test "a number fails" <|
            \_ -> fails Connect.Json.bytes "1"
        , test "encodes as a string" <|
            \_ -> encodesTo (Connect.Json.encodeBytes "aGk=") "\"aGk=\""
        ]


encodesTo : Json.Encode.Value -> String -> Expect.Expectation
encodesTo value json =
    Json.Encode.encode 0 value
        |> Expect.equal json
