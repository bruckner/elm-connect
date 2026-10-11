module Connect.JsonTest exposing (suite)

import Connect.Duration
import Connect.Json
import Dict
import Expect
import Json.Decode exposing (Decoder)
import Json.Encode
import Test exposing (Test, describe, test)
import Time


suite : Test
suite =
    describe "Connect.Json"
        [ fieldTests
        , fieldEitherTests
        , presenceTests
        , oneofTests
        , enumTests
        , intDictTests
        , int32Tests
        , uint32Tests
        , int64Tests
        , int64AsIntTests
        , floatTests
        , bytesTests
        , wellKnownTests
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


type alias Event =
    { id : String, kind : EventKind }


type EventKind
    = EventKindUnset
    | EventKindText String
    | EventKindTitleChanged String


decodeEvent : Decoder Event
decodeEvent =
    Json.Decode.succeed Event
        |> Connect.Json.field "id" "" Json.Decode.string
        |> Connect.Json.oneof decodeEventKind


decodeEventKind : Decoder EventKind
decodeEventKind =
    Json.Decode.oneOf
        [ Connect.Json.member "text" (Json.Decode.map EventKindText Json.Decode.string)
        , Connect.Json.memberEither "titleChanged" "title_changed" (Json.Decode.map EventKindTitleChanged Json.Decode.string)
        , Json.Decode.succeed EventKindUnset
        ]


oneofTests : Test
oneofTests =
    describe "oneof and member"
        [ test "a member" <|
            \_ -> decodes decodeEvent """{"id":"a","text":"t"}""" (Event "a" (EventKindText "t"))
        , test "a member under its proto name" <|
            \_ -> decodes decodeEvent """{"title_changed":"x"}""" (Event "" (EventKindTitleChanged "x"))
        , test "no member is unset" <|
            \_ -> decodes decodeEvent """{"id":"a"}""" (Event "a" EventKindUnset)
        , test "a member present as null is unset" <|
            \_ -> decodes decodeEvent """{"text":null}""" (Event "" EventKindUnset)
        , test "a null member falls through to the next" <|
            \_ -> decodes decodeEvent """{"text":null,"titleChanged":"x"}""" (Event "" (EventKindTitleChanged "x"))
        , test "two members: the first declared wins" <|
            \_ -> decodes decodeEvent """{"titleChanged":"x","text":"t"}""" (Event "" (EventKindText "t"))
        , test "a malformed member reads as unset" <|
            \_ -> decodes decodeEvent """{"text":1}""" (Event "" EventKindUnset)
        , test "member fails without the key" <|
            \_ -> fails (Connect.Json.member "text" Json.Decode.string) "{}"
        , test "member fails on null" <|
            \_ -> fails (Connect.Json.member "text" Json.Decode.string) """{"text":null}"""
        , test "emptyMember reads {}" <|
            \_ -> decodes (Connect.Json.emptyMember "clear" "set") """{"clear":{}}""" "set"
        , test "emptyMember fails on null" <|
            \_ -> fails (Connect.Json.emptyMember "clear" "set") """{"clear":null}"""
        , test "emptyMember fails without the key" <|
            \_ -> fails (Connect.Json.emptyMember "clear" "set") "{}"
        , test "emptyMember fails on a value that is not an object" <|
            \_ -> fails (Connect.Json.emptyMember "clear" "set") """{"clear":1}"""
        , test "emptyMemberEither reads the proto name" <|
            \_ -> decodes (Connect.Json.emptyMemberEither "clearAll" "clear_all" "set") """{"clear_all":{}}""" "set"
        ]


type Status
    = StatusUnspecified
    | StatusActive
    | StatusStarted


decodeStatus : Decoder Status
decodeStatus =
    Connect.Json.enum StatusUnspecified
        [ ( "STATUS_UNSPECIFIED", 0, StatusUnspecified )
        , ( "STATUS_ACTIVE", 1, StatusActive )
        , ( "STATUS_STARTED", 1, StatusStarted )
        ]


enumTests : Test
enumTests =
    describe "enum"
        [ test "a name" <|
            \_ -> decodes decodeStatus "\"STATUS_ACTIVE\"" StatusActive
        , test "a number" <|
            \_ -> decodes decodeStatus "1" StatusActive
        , test "zero by number" <|
            \_ -> decodes decodeStatus "0" StatusUnspecified
        , test "an alias by name" <|
            \_ -> decodes decodeStatus "\"STATUS_STARTED\"" StatusStarted
        , test "an unknown name is the zero value" <|
            \_ -> decodes decodeStatus "\"STATUS_ARCHIVED\"" StatusUnspecified
        , test "an unknown number is the zero value" <|
            \_ -> decodes decodeStatus "7" StatusUnspecified
        , test "a name is matched exactly" <|
            \_ -> decodes decodeStatus "\"status_active\"" StatusUnspecified
        , test "a fractional number fails" <|
            \_ -> fails decodeStatus "1.5"
        , test "a boolean fails" <|
            \_ -> fails decodeStatus "true"
        , test "a field holding an enum reads absence as the zero value" <|
            \_ ->
                decodes
                    (Json.Decode.succeed identity
                        |> Connect.Json.field "status" StatusUnspecified decodeStatus
                    )
                    """{"status":null}"""
                    StatusUnspecified
        ]


intDictTests : Test
intDictTests =
    describe "intDict"
        [ test "decimal keys" <|
            \_ ->
                decodes (Connect.Json.intDict Json.Decode.string)
                    """{"1":"a","-2":"b","0":"c"}"""
                    (Dict.fromList [ ( 1, "a" ), ( -2, "b" ), ( 0, "c" ) ])
        , test "an empty object" <|
            \_ -> decodes (Connect.Json.intDict Json.Decode.string) "{}" Dict.empty
        , test "a key that is not an integer fails" <|
            \_ -> fails (Connect.Json.intDict Json.Decode.string) """{"a":"x"}"""
        , test "a fractional key fails" <|
            \_ -> fails (Connect.Json.intDict Json.Decode.string) """{"1.5":"x"}"""
        , test "a value of the wrong type fails" <|
            \_ -> fails (Connect.Json.intDict Json.Decode.string) """{"1":2}"""
        , test "round-trips through Json.Encode.dict String.fromInt" <|
            \_ ->
                let
                    dict =
                        Dict.fromList [ ( 3, "c" ), ( -1, "a" ) ]
                in
                Json.Encode.dict String.fromInt Json.Encode.string dict
                    |> Json.Decode.decodeValue (Connect.Json.intDict Json.Decode.string)
                    |> Expect.equal (Ok dict)
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
        , test "the bounds decode" <|
            \_ ->
                Expect.all
                    [ \_ -> decodes Connect.Json.int32 "2147483647" 2147483647
                    , \_ -> decodes Connect.Json.int32 "-2147483648" -2147483648
                    , \_ -> decodes Connect.Json.int32 "\"-2147483648\"" -2147483648
                    ]
                    ()
        , test "past the upper bound fails" <|
            \_ -> fails Connect.Json.int32 "2147483648"
        , test "past the lower bound fails" <|
            \_ -> fails Connect.Json.int32 "\"-2147483649\""
        , test "a huge number fails" <|
            \_ -> fails Connect.Json.int32 "1e30"
        , test "says why it fails" <|
            \_ ->
                Json.Decode.decodeString Connect.Json.int32 "2147483648"
                    |> Result.mapError Json.Decode.errorToString
                    |> Result.mapError (String.contains "Expecting an int32 (-2147483648 to 2147483647), but got 2147483648")
                    |> Expect.equal (Err True)
        ]


uint32Tests : Test
uint32Tests =
    describe "uint32"
        [ test "a number" <|
            \_ -> decodes Connect.Json.uint32 "42" 42
        , test "a string" <|
            \_ -> decodes Connect.Json.uint32 "\"42\"" 42
        , test "the bounds decode" <|
            \_ ->
                Expect.all
                    [ \_ -> decodes Connect.Json.uint32 "0" 0
                    , \_ -> decodes Connect.Json.uint32 "4294967295" 4294967295
                    , \_ -> decodes Connect.Json.uint32 "\"4294967295\"" 4294967295
                    ]
                    ()
        , test "a negative number fails" <|
            \_ -> fails Connect.Json.uint32 "-1"
        , test "past the upper bound fails" <|
            \_ -> fails Connect.Json.uint32 "4294967296"
        , test "a fractional number fails" <|
            \_ -> fails Connect.Json.uint32 "1.5"
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


int64AsIntTests : Test
int64AsIntTests =
    describe "int64AsInt"
        [ test "a number" <|
            \_ -> decodes Connect.Json.int64AsInt "42" 42
        , test "a string" <|
            \_ -> decodes Connect.Json.int64AsInt "\"-42\"" -42
        , test "the largest exact Int, as a string and a number" <|
            \_ ->
                Expect.all
                    [ \_ -> decodes Connect.Json.int64AsInt "\"9007199254740991\"" 9007199254740991
                    , \_ -> decodes Connect.Json.int64AsInt "9007199254740991" 9007199254740991
                    , \_ -> decodes Connect.Json.int64AsInt "\"-9007199254740991\"" -9007199254740991
                    , \_ -> decodes Connect.Json.int64AsInt "-9007199254740991" -9007199254740991
                    ]
                    ()
        , test "2^53 as a string fails" <|
            \_ -> fails Connect.Json.int64AsInt "\"9007199254740992\""
        , test "2^53 as a number fails" <|
            \_ -> fails Connect.Json.int64AsInt "9007199254740992"
        , test "-2^53 fails" <|
            \_ -> fails Connect.Json.int64AsInt "\"-9007199254740992\""
        , test "a fractional number fails" <|
            \_ -> fails Connect.Json.int64AsInt "4.5"
        , test "a string in exponent notation fails" <|
            \_ -> fails Connect.Json.int64AsInt "\"1e3\""
        , test "an empty string fails" <|
            \_ -> fails Connect.Json.int64AsInt "\"\""
        , test "a boolean fails" <|
            \_ -> fails Connect.Json.int64AsInt "true"
        , test "says why it fails" <|
            \_ ->
                Json.Decode.decodeString Connect.Json.int64AsInt "\"9007199254740992\""
                    |> Result.mapError Json.Decode.errorToString
                    |> Result.mapError (String.contains "Expecting an integer from -9007199254740991 to 9007199254740991, the 64-bit integers an Elm Int holds exactly, but got \"9007199254740992\"")
                    |> Expect.equal (Err True)
        , test "encodes as a decimal string" <|
            \_ ->
                Connect.Json.encodeInt64AsInt -9007199254740991
                    |> Json.Encode.encode 0
                    |> Expect.equal "\"-9007199254740991\""
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
    let
        accepts text =
            test ("accepts \"" ++ text ++ "\"") <|
                \_ -> decodes Connect.Json.bytes ("\"" ++ text ++ "\"") text

        rejects text =
            test ("rejects \"" ++ text ++ "\"") <|
                \_ -> fails Connect.Json.bytes ("\"" ++ text ++ "\"")
    in
    describe "bytes"
        [ accepts ""
        , accepts "aGk="
        , accepts "aGk"
        , accepts "aA=="
        , accepts "aA"
        , accepts "aGVsbG8h"
        , accepts "+/+/"
        , accepts "-_-_"
        , accepts "-_8="
        , accepts "+/8"
        , rejects "a"
        , rejects "aGVsbG8hA"
        , rejects "a==="
        , rejects "aGk=="
        , rejects "aA="
        , rejects "aGVs="
        , rejects "aGVsbG8h===="
        , rejects "=="
        , rejects "aG=k"
        , rejects "aG k"
        , rejects "aGk!"
        , rejects "+/-_"
        , rejects "aGkß"
        , test "keeps the string as received" <|
            \_ -> decodes Connect.Json.bytes "\"-_8\"" "-_8"
        , test "a number fails" <|
            \_ -> fails Connect.Json.bytes "1"
        , test "says why it fails" <|
            \_ ->
                Json.Decode.decodeString Connect.Json.bytes "\"a\""
                    |> Result.mapError (Json.Decode.errorToString >> String.contains "Expecting base64 (standard or URL-safe, padding optional), but got \"a\"")
                    |> Expect.equal (Err True)
        , test "encodes as a string" <|
            \_ -> encodesTo (Connect.Json.encodeBytes "aGk=") "\"aGk=\""
        ]


encodesTo : Json.Encode.Value -> String -> Expect.Expectation
encodesTo value json =
    Json.Encode.encode 0 value
        |> Expect.equal json


wellKnownTests : Test
wellKnownTests =
    describe "well-known types"
        [ test "struct reads an object" <|
            \_ ->
                Json.Decode.decodeString Connect.Json.struct """{"a":1,"b":null}"""
                    |> Result.map (Dict.map (\_ value -> Json.Encode.encode 0 value) >> Dict.toList)
                    |> Expect.equal (Ok [ ( "a", "1" ), ( "b", "null" ) ])
        , test "struct fails on an array" <|
            \_ -> fails Connect.Json.struct "[1]"
        , test "struct fails on null" <|
            \_ -> fails Connect.Json.struct "null"
        , test "encodeStruct writes an object" <|
            \_ ->
                encodesTo
                    (Connect.Json.encodeStruct (Dict.fromList [ ( "a", Json.Encode.int 1 ) ]))
                    """{"a":1}"""
        , test "listValue reads an array" <|
            \_ ->
                Json.Decode.decodeString Connect.Json.listValue """[1,"x",null]"""
                    |> Result.map (List.map (Json.Encode.encode 0))
                    |> Expect.equal (Ok [ "1", "\"x\"", "null" ])
        , test "listValue fails on an object" <|
            \_ -> fails Connect.Json.listValue """{"a":1}"""
        , test "encodeListValue writes an array" <|
            \_ ->
                encodesTo
                    (Connect.Json.encodeListValue [ Json.Encode.int 1, Json.Encode.null ])
                    "[1,null]"
        , test "a timestamp" <|
            \_ -> decodes Connect.Json.timestamp "\"1970-01-01T00:00:01.5Z\"" (Time.millisToPosix 1500)
        , test "a malformed timestamp fails" <|
            \_ -> fails Connect.Json.timestamp "\"yesterday\""
        , test "a timestamp as a number fails" <|
            \_ -> fails Connect.Json.timestamp "1500"
        , test "encodes a timestamp" <|
            \_ -> encodesTo (Connect.Json.encodeTimestamp (Time.millisToPosix 1500)) "\"1970-01-01T00:00:01.500Z\""
        , test "a duration" <|
            \_ -> decodes Connect.Json.duration "\"-1.5s\"" (Connect.Duration.fromSeconds -1.5)
        , test "a malformed duration fails" <|
            \_ -> fails Connect.Json.duration "\"1.5\""
        , test "encodes a duration" <|
            \_ -> encodesTo (Connect.Json.encodeDuration (Connect.Duration.fromSeconds 1.5)) "\"1.500s\""
        , test "a field mask comes back with proto field names" <|
            \_ ->
                decodes Connect.Json.fieldMask
                    "\"displayName,author.emailAddress,id\""
                    [ "display_name", "author.email_address", "id" ]
        , test "the empty field mask" <|
            \_ -> decodes Connect.Json.fieldMask "\"\"" []
        , test "encodes a field mask in lowerCamelCase" <|
            \_ ->
                encodesTo (Connect.Json.encodeFieldMask [ "display_name", "author.email_address" ])
                    "\"displayName,author.emailAddress\""
        , test "encodes the empty field mask" <|
            \_ -> encodesTo (Connect.Json.encodeFieldMask []) "\"\""
        , test "Empty is any object" <|
            \_ -> decodes Connect.Json.empty """{"ignored":1}""" ()
        , test "Empty is not an array" <|
            \_ -> fails Connect.Json.empty "[]"
        , test "encodes Empty as {}" <|
            \_ -> encodesTo (Connect.Json.encodeEmpty ()) "{}"
        ]
