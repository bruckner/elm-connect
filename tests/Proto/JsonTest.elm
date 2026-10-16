module Proto.JsonTest exposing (suite)

import Dict
import Expect
import Json.Decode exposing (Decoder)
import Json.Encode
import Proto.Duration
import Proto.Json
import Test exposing (Test, describe, test)
import Time


suite : Test
suite =
    describe "Proto.Json"
        [ fieldTests
        , fieldEitherTests
        , lookupTests
        , presenceTests
        , encodingTests
        , oneofTests
        , enumTests
        , enumOrZeroTests
        , intDictTests
        , boolMapTests
        , protoKeyTests
        , int32Tests
        , uint32Tests
        , int64Tests
        , int64AsIntTests
        , uint64Tests
        , uint64AsIntTests
        , floatTests
        , bytesTests
        , wellKnownTests
        ]


type alias Pair =
    { name : String, count : Int }


decodePair : Decoder Pair
decodePair =
    Json.Decode.succeed Pair
        |> Proto.Json.field "name" "" Json.Decode.string
        |> Proto.Json.field "count" 0 Json.Decode.int


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
        |> Proto.Json.fieldEither "displayName" "display_name" "" Json.Decode.string


fieldEitherTests : Test
fieldEitherTests =
    describe "fieldEither"
        [ test "the JSON name" <|
            \_ -> decodes decodeNamed """{"displayName":"a"}""" (Named "a")
        , test "the proto name" <|
            \_ -> decodes decodeNamed """{"display_name":"b"}""" (Named "b")
        , test "both names fail, naming them" <|
            \_ -> failsWith decodeNamed """{"display_name":"b","displayName":"a"}""" "Expecting \"displayName\" or \"display_name\", but got both"
        , test "both names fail even when one is null" <|
            \_ -> fails decodeNamed """{"displayName":null,"display_name":"b"}"""
        , test "equal names are one key" <|
            \_ -> decodes (Json.Decode.succeed Named |> Proto.Json.fieldEither "id" "id" "" Json.Decode.string) """{"id":"a"}""" (Named "a")
        , test "neither gives the default" <|
            \_ -> decodes decodeNamed "{}" (Named "")
        , test "null under the JSON name gives the default" <|
            \_ -> decodes decodeNamed """{"displayName":null}""" (Named "")
        , test "null under the proto name gives the default" <|
            \_ -> decodes decodeNamed """{"display_name":null}""" (Named "")
        , test "a wrong type under the proto name fails" <|
            \_ -> fails decodeNamed """{"display_name":1}"""
        ]


type alias Inherited =
    { constructor : String, toString : String, proto : Int, hasOwnProperty : Int }


{-| A message whose fields are named after `Object.prototype`'s properties,
which every JavaScript object inherits.
-}
decodeInherited : Decoder Inherited
decodeInherited =
    Json.Decode.succeed Inherited
        |> Proto.Json.field "constructor" "" Json.Decode.string
        |> Proto.Json.fieldEither "toString" "to_string" "" Json.Decode.string
        |> Proto.Json.field "__proto__" 0 Json.Decode.int
        |> Proto.Json.field "hasOwnProperty" 0 Json.Decode.int


type alias Sized =
    { length : Int, name : String }


{-| A message with a field an array has too.
-}
decodeSized : Decoder Sized
decodeSized =
    Json.Decode.succeed Sized
        |> Proto.Json.field "length" 0 Json.Decode.int
        |> Proto.Json.field "name" "" Json.Decode.string


notObjects : List String
notObjects =
    [ "5", "\"text\"", "true", "null", "[]", "[1,2]" ]


failsOnEach : Decoder a -> List String -> Expect.Expectation
failsOnEach decoder inputs =
    inputs
        |> List.filter (\json -> Result.toMaybe (Json.Decode.decodeString decoder json) /= Nothing)
        |> Expect.equal []


lookupTests : Test
lookupTests =
    describe "field lookup"
        [ test "fields named after Object.prototype's properties read as absent when absent" <|
            \_ -> decodes decodeInherited "{}" (Inherited "" "" 0 0)
        , test "fields named after Object.prototype's properties read when present" <|
            \_ ->
                decodes decodeInherited
                    """{"constructor":"c","to_string":"t","__proto__":1,"hasOwnProperty":2}"""
                    (Inherited "c" "t" 1 2)
        , test "fields named after Object.prototype's properties read null as absent" <|
            \_ -> decodes decodeInherited """{"constructor":null,"toString":null,"__proto__":null}""" (Inherited "" "" 0 0)
        , test "a field named after an Object.prototype property under both its names fails" <|
            \_ -> failsWith decodeInherited """{"toString":"a","to_string":"b"}""" "Expecting \"toString\" or \"to_string\", but got both"
        , test "an unknown hasOwnProperty key is ignored" <|
            \_ -> decodes decodePair """{"hasOwnProperty":1,"name":"a"}""" (Pair "a" 0)
        , test "an unknown hasOwnProperty key is ignored when no field is present" <|
            \_ -> decodes decodePair """{"hasOwnProperty":"x"}""" (Pair "" 0)
        , test "an unknown hasOwnProperty key is ignored by a oneof" <|
            \_ -> decodes decodeEvent """{"hasOwnProperty":1,"text":"t"}""" (Event "" (EventKindText "t"))
        , test "an unknown hasOwnProperty key is ignored by Empty" <|
            \_ -> decodes Proto.Json.empty """{"hasOwnProperty":1}""" ()
        , test "unknown keys named after Object.prototype's properties are ignored" <|
            \_ -> decodes decodePair """{"constructor":"c","toString":1,"__proto__":{},"valueOf":null}""" (Pair "" 0)
        , test "a field an array has reads from an object" <|
            \_ -> decodes decodeSized """{"length":3}""" (Sized 3 "")
        , test "a message fails on every JSON value that is not an object" <|
            \_ -> failsOnEach decodePair notObjects
        , test "a message whose field an array has fails on an array" <|
            \_ -> failsOnEach decodeSized notObjects
        , test "a message with fields named after Object.prototype's properties fails on a non-object" <|
            \_ -> failsOnEach decodeInherited notObjects
        , test "a oneof fails on every JSON value that is not an object" <|
            \_ -> failsOnEach decodeEvent notObjects
        , test "Empty fails on every JSON value that is not an object" <|
            \_ -> failsOnEach Proto.Json.empty notObjects
        , test "a non-object fails as elm/json words it" <|
            \_ -> failsWith decodePair "42" "Expecting an OBJECT"
        , test "an empty object gives every default" <|
            \_ -> decodes decodeSized "{}" (Sized 0 "")
        , test "a field present as null reads as absent, absent and null alike" <|
            \_ ->
                ( Json.Decode.decodeString decodePair """{"name":null}"""
                , Json.Decode.decodeString decodePair "{}"
                )
                    |> Expect.equal ( Ok (Pair "" 0), Ok (Pair "" 0) )
        , test "every field of a wide message decodes" <|
            \_ ->
                let
                    names =
                        List.map (\k -> "field" ++ String.fromInt k) (List.range 0 255)

                    wide =
                        List.foldl
                            (\name acc -> Proto.Json.field name "" Json.Decode.string (Json.Decode.map (\xs x -> x :: xs) acc))
                            (Json.Decode.succeed [])
                            names
                in
                Json.Encode.object (List.map (\name -> ( name, Json.Encode.string name )) names)
                    |> Json.Decode.decodeValue wide
                    |> Result.map List.reverse
                    |> Expect.equal (Ok names)
        ]


type alias Shapes =
    { count : Maybe Int, tags : List String }


decodeShapes : Decoder Shapes
decodeShapes =
    Json.Decode.succeed Shapes
        |> Proto.Json.field "count" Nothing (Json.Decode.map Just Proto.Json.int32)
        |> Proto.Json.field "tags" [] (Json.Decode.list Json.Decode.string)


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
        ]


encodingTests : Test
encodingTests =
    let
        object fields =
            Proto.Json.object [ ( "f", fields ) ]
    in
    describe "encoding fields"
        [ test "object leaves out the fields given Nothing, in order otherwise" <|
            \_ ->
                encodesTo
                    (Proto.Json.object
                        [ ( "a", Just (Json.Encode.int 1) )
                        , ( "b", Nothing )
                        , ( "c", Just Json.Encode.null )
                        ]
                    )
                    """{"a":1,"c":null}"""
        , test "implicit leaves out the default" <|
            \_ ->
                Expect.all
                    [ \_ -> encodesTo (object (Proto.Json.implicit "" Json.Encode.string "")) "{}"
                    , \_ -> encodesTo (object (Proto.Json.implicit 0 Json.Encode.int 0)) "{}"
                    , \_ -> encodesTo (object (Proto.Json.implicit "0" Proto.Json.encodeInt64 "0")) "{}"
                    , \_ -> encodesTo (object (Proto.Json.implicit False Json.Encode.bool False)) "{}"
                    ]
                    ()
        , test "implicit writes any other value" <|
            \_ ->
                Expect.all
                    [ \_ -> encodesTo (object (Proto.Json.implicit "" Json.Encode.string " ")) """{"f":" "}"""
                    , \_ -> encodesTo (object (Proto.Json.implicit 0 Json.Encode.int -1)) """{"f":-1}"""
                    , \_ -> encodesTo (object (Proto.Json.implicit "0" Proto.Json.encodeInt64 "9007199254740993")) """{"f":"9007199254740993"}"""
                    , \_ -> encodesTo (object (Proto.Json.implicit False Json.Encode.bool True)) """{"f":true}"""
                    ]
                    ()
        , test "implicitFloat leaves out only 0" <|
            \_ ->
                Expect.all
                    [ \_ -> encodesTo (object (Proto.Json.implicitFloat 0)) "{}"
                    , \_ -> encodesTo (object (Proto.Json.implicitFloat 1.5)) """{"f":1.5}"""
                    , \_ -> Expect.notEqual Nothing (Proto.Json.implicitFloat (0 * -1))
                    , \_ -> encodesTo (object (Proto.Json.implicitFloat (0 / 0))) """{"f":"NaN"}"""
                    , \_ -> encodesTo (object (Proto.Json.implicitFloat (-1 / 0))) """{"f":"-Infinity"}"""
                    ]
                    ()
        , test "repeated, dict and boolDict leave out the empty" <|
            \_ ->
                Expect.all
                    [ \_ -> encodesTo (object (Proto.Json.repeated Json.Encode.int [])) "{}"
                    , \_ -> encodesTo (object (Proto.Json.repeated Json.Encode.int [ 0 ])) """{"f":[0]}"""
                    , \_ -> encodesTo (object (Proto.Json.dict String.fromInt Json.Encode.int Dict.empty)) "{}"
                    , \_ -> encodesTo (object (Proto.Json.dict String.fromInt Json.Encode.int (Dict.singleton 1 0))) """{"f":{"1":0}}"""
                    , \_ -> encodesTo (object (Proto.Json.boolDict Json.Encode.int [])) "{}"
                    , \_ -> encodesTo (object (Proto.Json.boolDict Json.Encode.int [ ( True, 0 ) ])) """{"f":{"true":0}}"""
                    ]
                    ()
        ]


type alias Event =
    { id : String, kind : EventKind }


type EventKind
    = EventKindUnset
    | EventKindText String
    | EventKindTitleChanged String
    | EventKindCleared
    | EventKindPayload Json.Encode.Value


decodeEvent : Decoder Event
decodeEvent =
    Json.Decode.succeed Event
        |> Proto.Json.field "id" "" Json.Decode.string
        |> Proto.Json.oneof decodeEventKind


decodeEventKind : Decoder EventKind
decodeEventKind =
    Proto.Json.members "kind"
        EventKindUnset
        [ Proto.Json.member "text" (Json.Decode.map EventKindText Json.Decode.string)
        , Proto.Json.memberEither "titleChanged" "title_changed" (Json.Decode.map EventKindTitleChanged Json.Decode.string)
        , Proto.Json.emptyMemberEither "clearedAll" "cleared_all" EventKindCleared
        , Proto.Json.valueMember "payload" EventKindPayload
        ]


failsWith : Decoder a -> String -> String -> Expect.Expectation
failsWith decoder json problem =
    case Json.Decode.decodeString decoder json of
        Ok value ->
            Expect.fail ("expected a failure, decoded " ++ Debug.toString value)

        Err error ->
            Json.Decode.errorToString error
                |> String.contains problem
                |> Expect.equal True
                |> Expect.onFail (Json.Decode.errorToString error ++ "\ndoes not contain\n" ++ problem)


oneofTests : Test
oneofTests =
    describe "oneof and members"
        [ test "a member" <|
            \_ -> decodes decodeEvent """{"id":"a","text":"t"}""" (Event "a" (EventKindText "t"))
        , test "a member under its proto name" <|
            \_ -> decodes decodeEvent """{"title_changed":"x"}""" (Event "" (EventKindTitleChanged "x"))
        , test "no member is unset" <|
            \_ -> decodes decodeEvent """{"id":"a"}""" (Event "a" EventKindUnset)
        , test "a member present as null is unset" <|
            \_ -> decodes decodeEvent """{"text":null}""" (Event "" EventKindUnset)
        , test "a null member does not count against another" <|
            \_ -> decodes decodeEvent """{"text":null,"titleChanged":"x"}""" (Event "" (EventKindTitleChanged "x"))
        , test "a malformed member fails the message" <|
            \_ -> fails decodeEvent """{"text":1}"""
        , test "a malformed member under its proto name fails the message" <|
            \_ -> fails decodeEvent """{"title_changed":false}"""
        , test "two members fail, naming the keys" <|
            \_ ->
                failsWith decodeEvent
                    """{"titleChanged":"x","text":"t"}"""
                    "Expecting at most one member of oneof \"kind\", but got \"text\" and \"titleChanged\""
        , test "three members fail, naming every key" <|
            \_ ->
                failsWith decodeEvent
                    """{"title_changed":"x","text":"t","cleared_all":{}}"""
                    "Expecting at most one member of oneof \"kind\", but got \"text\", \"title_changed\" and \"cleared_all\""
        , test "a member under both its names fails, naming them" <|
            \_ ->
                failsWith decodeEvent
                    """{"titleChanged":"x","title_changed":"x"}"""
                    "Expecting \"titleChanged\" or \"title_changed\", but got both"
        , test "a member under both its names fails even when one is null" <|
            \_ -> fails decodeEvent """{"titleChanged":"x","title_changed":null}"""
        , test "emptyMember reads {}" <|
            \_ -> decodes decodeEvent """{"cleared_all":{}}""" (Event "" EventKindCleared)
        , test "emptyMember reads null as unset" <|
            \_ -> decodes decodeEvent """{"clearedAll":null}""" (Event "" EventKindUnset)
        , test "emptyMember fails on a value that is not an object" <|
            \_ -> fails decodeEvent """{"clearedAll":1}"""
        , test "valueMember holds any JSON" <|
            \_ -> decodes decodeEvent """{"payload":[1]}""" (Event "" (EventKindPayload (Json.Encode.list Json.Encode.int [ 1 ])))
        , test "valueMember reads null as set, holding null" <|
            \_ -> decodes decodeEvent """{"payload":null}""" (Event "" (EventKindPayload Json.Encode.null))
        , test "a null valueMember counts against another member" <|
            \_ ->
                failsWith decodeEvent
                    """{"payload":null,"text":"t"}"""
                    "Expecting at most one member of oneof \"kind\", but got \"text\" and \"payload\""
        , test "a oneof that is not an object fails" <|
            \_ -> fails decodeEventKind "[]"
        ]


type Status
    = StatusUnspecified
    | StatusActive


decodeStatus : Decoder Status
decodeStatus =
    Proto.Json.enum "Status"
        StatusUnspecified
        [ ( "STATUS_UNSPECIFIED", 0, StatusUnspecified )
        , ( "STATUS_ACTIVE", 1, StatusActive )
        , ( "STATUS_STARTED", 1, StatusActive )
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
        , test "an alias by name is its number's constructor" <|
            \_ -> decodes decodeStatus "\"STATUS_STARTED\"" StatusActive
        , test "an unknown name fails" <|
            \_ ->
                failsWith decodeStatus
                    "\"STATUS_ARCHIVED\""
                    "Expecting a value of enum \"Status\", but got \"STATUS_ARCHIVED\""
        , test "an unknown number is the zero value" <|
            \_ -> decodes decodeStatus "7" StatusUnspecified
        , test "a name is matched exactly" <|
            \_ -> fails decodeStatus "\"status_active\""
        , test "a fractional number fails" <|
            \_ -> fails decodeStatus "1.5"
        , test "a boolean fails" <|
            \_ -> fails decodeStatus "true"
        , test "a field holding an enum reads absence as the zero value" <|
            \_ ->
                decodes
                    (Json.Decode.succeed identity
                        |> Proto.Json.field "status" StatusUnspecified decodeStatus
                    )
                    """{"status":null}"""
                    StatusUnspecified
        ]


decodeStatusOrZero : Decoder Status
decodeStatusOrZero =
    Proto.Json.enumOrZero "Status"
        StatusUnspecified
        [ ( "STATUS_UNSPECIFIED", 0, StatusUnspecified )
        , ( "STATUS_ACTIVE", 1, StatusActive )
        , ( "STATUS_STARTED", 1, StatusActive )
        ]


enumOrZeroTests : Test
enumOrZeroTests =
    describe "enumOrZero"
        [ test "a name" <|
            \_ -> decodes decodeStatusOrZero "\"STATUS_ACTIVE\"" StatusActive
        , test "an alias by name is its number's constructor" <|
            \_ -> decodes decodeStatusOrZero "\"STATUS_STARTED\"" StatusActive
        , test "a number" <|
            \_ -> decodes decodeStatusOrZero "1" StatusActive
        , test "zero by name" <|
            \_ -> decodes decodeStatusOrZero "\"STATUS_UNSPECIFIED\"" StatusUnspecified
        , test "an unknown name is the zero value" <|
            \_ -> decodes decodeStatusOrZero "\"STATUS_ARCHIVED\"" StatusUnspecified
        , test "a name not matched exactly is the zero value" <|
            \_ -> decodes decodeStatusOrZero "\"status_active\"" StatusUnspecified
        , test "an unknown number is the zero value" <|
            \_ -> decodes decodeStatusOrZero "7" StatusUnspecified
        , test "a fractional number fails" <|
            \_ -> fails decodeStatusOrZero "1.5"
        , test "a boolean fails" <|
            \_ -> fails decodeStatusOrZero "true"
        , test "an object fails" <|
            \_ -> fails decodeStatusOrZero "{}"
        , test "a field holding an enum reads an unknown name as the zero value" <|
            \_ ->
                decodes
                    (Json.Decode.succeed identity
                        |> Proto.Json.field "status" StatusActive decodeStatusOrZero
                    )
                    """{"status":"STATUS_ARCHIVED"}"""
                    StatusUnspecified
        ]


intDictTests : Test
intDictTests =
    describe "intDict"
        [ test "decimal keys" <|
            \_ ->
                decodes (Proto.Json.intDict Json.Decode.string)
                    """{"1":"a","-2":"b","0":"c"}"""
                    (Dict.fromList [ ( 1, "a" ), ( -2, "b" ), ( 0, "c" ) ])
        , test "an empty object" <|
            \_ -> decodes (Proto.Json.intDict Json.Decode.string) "{}" Dict.empty
        , test "a key that is not an integer fails" <|
            \_ -> fails (Proto.Json.intDict Json.Decode.string) """{"a":"x"}"""
        , test "a fractional key fails" <|
            \_ -> fails (Proto.Json.intDict Json.Decode.string) """{"1.5":"x"}"""
        , test "a value of the wrong type fails" <|
            \_ -> fails (Proto.Json.intDict Json.Decode.string) """{"1":2}"""
        , test "round-trips through Json.Encode.dict String.fromInt" <|
            \_ ->
                let
                    dict =
                        Dict.fromList [ ( 3, "c" ), ( -1, "a" ) ]
                in
                Json.Encode.dict String.fromInt Json.Encode.string dict
                    |> Json.Decode.decodeValue (Proto.Json.intDict Json.Decode.string)
                    |> Expect.equal (Ok dict)
        ]


boolMapTests : Test
boolMapTests =
    describe "boolMap"
        [ test "both keys, in the object's order" <|
            \_ ->
                decodes (Proto.Json.boolMap Json.Decode.string)
                    """{"true":"on","false":"off"}"""
                    [ ( True, "on" ), ( False, "off" ) ]
        , test "the other order" <|
            \_ ->
                decodes (Proto.Json.boolMap Json.Decode.string)
                    """{"false":"off","true":"on"}"""
                    [ ( False, "off" ), ( True, "on" ) ]
        , test "an empty object" <|
            \_ -> decodes (Proto.Json.boolMap Json.Decode.string) "{}" []
        , test "a key other than true or false fails, naming it" <|
            \_ ->
                failsWith (Proto.Json.boolMap Json.Decode.string)
                    """{"True":"x"}"""
                    "Expecting a bool map key (\"true\" or \"false\"), but got \"True\""
        , test "a numeric key fails" <|
            \_ -> fails (Proto.Json.boolMap Json.Decode.string) """{"1":"x"}"""
        , test "a value of the wrong type fails" <|
            \_ -> fails (Proto.Json.boolMap Json.Decode.string) """{"true":2}"""
        , test "encodes keys as true and false" <|
            \_ ->
                encodesTo (Proto.Json.encodeBoolMap Json.Encode.int [ ( True, 1 ), ( False, 0 ) ])
                    """{"true":1,"false":0}"""
        , test "round-trips" <|
            \_ ->
                Proto.Json.encodeBoolMap Json.Encode.string [ ( False, "b" ), ( True, "a" ) ]
                    |> Json.Decode.decodeValue (Proto.Json.boolMap Json.Decode.string)
                    |> Expect.equal (Ok [ ( False, "b" ), ( True, "a" ) ])
        ]


int32Tests : Test
int32Tests =
    describe "int32"
        [ test "a number" <|
            \_ -> decodes Proto.Json.int32 "42" 42
        , test "a negative number" <|
            \_ -> decodes Proto.Json.int32 "-7" -7
        , test "an integral number written with a fraction" <|
            \_ -> decodes Proto.Json.int32 "4.0" 4
        , test "a number in exponent notation" <|
            \_ -> decodes Proto.Json.int32 "1e2" 100
        , test "a string" <|
            \_ -> decodes Proto.Json.int32 "\"42\"" 42
        , test "a negative string" <|
            \_ -> decodes Proto.Json.int32 "\"-42\"" -42
        , test "a string in exponent notation" <|
            \_ -> decodes Proto.Json.int32 "\"1e2\"" 100
        , test "a fractional number fails" <|
            \_ -> fails Proto.Json.int32 "4.5"
        , test "a fractional string fails" <|
            \_ -> fails Proto.Json.int32 "\"4.5\""
        , test "an empty string fails" <|
            \_ -> fails Proto.Json.int32 "\"\""
        , test "\"Infinity\" fails" <|
            \_ -> fails Proto.Json.int32 "\"Infinity\""
        , test "a boolean fails" <|
            \_ -> fails Proto.Json.int32 "true"
        , test "the bounds decode" <|
            \_ ->
                Expect.all
                    [ \_ -> decodes Proto.Json.int32 "2147483647" 2147483647
                    , \_ -> decodes Proto.Json.int32 "-2147483648" -2147483648
                    , \_ -> decodes Proto.Json.int32 "\"-2147483648\"" -2147483648
                    ]
                    ()
        , test "past the upper bound fails" <|
            \_ -> fails Proto.Json.int32 "2147483648"
        , test "past the lower bound fails" <|
            \_ -> fails Proto.Json.int32 "\"-2147483649\""
        , test "a huge number fails" <|
            \_ -> fails Proto.Json.int32 "1e30"
        , test "says why it fails" <|
            \_ ->
                Json.Decode.decodeString Proto.Json.int32 "2147483648"
                    |> Result.mapError Json.Decode.errorToString
                    |> Result.mapError (String.contains "Expecting an int32 (-2147483648 to 2147483647), but got 2147483648")
                    |> Expect.equal (Err True)
        ]


uint32Tests : Test
uint32Tests =
    describe "uint32"
        [ test "a number" <|
            \_ -> decodes Proto.Json.uint32 "42" 42
        , test "a string" <|
            \_ -> decodes Proto.Json.uint32 "\"42\"" 42
        , test "the bounds decode" <|
            \_ ->
                Expect.all
                    [ \_ -> decodes Proto.Json.uint32 "0" 0
                    , \_ -> decodes Proto.Json.uint32 "4294967295" 4294967295
                    , \_ -> decodes Proto.Json.uint32 "\"4294967295\"" 4294967295
                    ]
                    ()
        , test "a negative number fails" <|
            \_ -> fails Proto.Json.uint32 "-1"
        , test "past the upper bound fails" <|
            \_ -> fails Proto.Json.uint32 "4294967296"
        , test "a fractional number fails" <|
            \_ -> fails Proto.Json.uint32 "1.5"
        ]


int64Tests : Test
int64Tests =
    describe "int64"
        [ test "a string" <|
            \_ -> decodes Proto.Json.int64 "\"9007199254740993\"" "9007199254740993"
        , test "a negative string" <|
            \_ -> decodes Proto.Json.int64 "\"-42\"" "-42"
        , test "a number" <|
            \_ -> decodes Proto.Json.int64 "42" "42"
        , test "a negative number" <|
            \_ -> decodes Proto.Json.int64 "-7" "-7"
        , test "a string that is not an integer fails" <|
            \_ -> fails Proto.Json.int64 "\"4.2\""
        , test "a string in exponent notation" <|
            \_ -> decodes Proto.Json.int64 "\"1e3\"" "1000"
        , test "a string with a fraction and an exponent" <|
            \_ -> decodes Proto.Json.int64 "\"1.5e3\"" "1500"
        , test "a number in exponent notation" <|
            \_ -> decodes Proto.Json.int64 "1E2" "100"
        , test "a negative string with a zero exponent" <|
            \_ -> decodes Proto.Json.int64 "\"-2e0\"" "-2"
        , test "a signed exponent" <|
            \_ ->
                Expect.all
                    [ \_ -> decodes Proto.Json.int64 "\"15E+1\"" "150"
                    , \_ -> decodes Proto.Json.int64 "\"1500e-2\"" "15"
                    , \_ -> decodes Proto.Json.int64 "\"0.0025e4\"" "25"
                    ]
                    ()
        , test "exponent notation keeps every digit past 2^53" <|
            \_ -> decodes Proto.Json.int64 "\"9.223372036854775807e18\"" "9223372036854775807"
        , test "an integral decimal fraction" <|
            \_ -> decodes Proto.Json.int64 "\"4.0\"" "4"
        , test "leading zeros and negative zero are made canonical" <|
            \_ ->
                Expect.all
                    [ \_ -> decodes Proto.Json.int64 "\"007\"" "7"
                    , \_ -> decodes Proto.Json.int64 "\"-0\"" "0"
                    , \_ -> decodes Proto.Json.int64 "\"0e999\"" "0"
                    ]
                    ()
        , test "exponent notation that leaves a fraction fails" <|
            \_ ->
                failsWith Proto.Json.int64 "\"1.5e0\"" "Expecting an integer, but got \"1.5e0\""
        , test "a negative exponent that leaves a fraction fails" <|
            \_ -> fails Proto.Json.int64 "\"15e-2\""
        , test "more than 20 digits fails" <|
            \_ ->
                Expect.all
                    [ \_ -> failsWith Proto.Json.int64 "\"1e21\"" "Expecting a 64-bit integer, but got \"1e21\""
                    , \_ -> fails Proto.Json.int64 "\"1e999999999999\""
                    , \_ -> fails Proto.Json.int64 "1e21"
                    ]
                    ()
        , test "malformed exponent notation fails" <|
            \_ ->
                Expect.all
                    [ \_ -> fails Proto.Json.int64 "\"1e\""
                    , \_ -> fails Proto.Json.int64 "\"e3\""
                    , \_ -> fails Proto.Json.int64 "\"1.e3\""
                    , \_ -> fails Proto.Json.int64 "\".5e1\""
                    , \_ -> fails Proto.Json.int64 "\"1e+\""
                    , \_ -> fails Proto.Json.int64 "\"1e3e1\""
                    , \_ -> fails Proto.Json.int64 "\"--1\""
                    ]
                    ()
        , test "an empty string fails" <|
            \_ -> fails Proto.Json.int64 "\"\""
        , test "a fractional number fails" <|
            \_ -> fails Proto.Json.int64 "4.2"
        , test "a boolean fails" <|
            \_ -> fails Proto.Json.int64 "true"
        , test "encodes as a string" <|
            \_ ->
                Proto.Json.encodeInt64 "9007199254740993"
                    |> Json.Encode.encode 0
                    |> Expect.equal "\"9007199254740993\""
        ]


int64AsIntTests : Test
int64AsIntTests =
    describe "int64AsInt"
        [ test "a number" <|
            \_ -> decodes Proto.Json.int64AsInt "42" 42
        , test "a string" <|
            \_ -> decodes Proto.Json.int64AsInt "\"-42\"" -42
        , test "the largest exact Int, as a string and a number" <|
            \_ ->
                Expect.all
                    [ \_ -> decodes Proto.Json.int64AsInt "\"9007199254740991\"" 9007199254740991
                    , \_ -> decodes Proto.Json.int64AsInt "9007199254740991" 9007199254740991
                    , \_ -> decodes Proto.Json.int64AsInt "\"-9007199254740991\"" -9007199254740991
                    , \_ -> decodes Proto.Json.int64AsInt "-9007199254740991" -9007199254740991
                    ]
                    ()
        , test "2^53 as a string fails" <|
            \_ -> fails Proto.Json.int64AsInt "\"9007199254740992\""
        , test "2^53 as a number fails" <|
            \_ -> fails Proto.Json.int64AsInt "9007199254740992"
        , test "-2^53 fails" <|
            \_ -> fails Proto.Json.int64AsInt "\"-9007199254740992\""
        , test "a fractional number fails" <|
            \_ -> fails Proto.Json.int64AsInt "4.5"
        , test "a string in exponent notation" <|
            \_ ->
                Expect.all
                    [ \_ -> decodes Proto.Json.int64AsInt "\"1e3\"" 1000
                    , \_ -> decodes Proto.Json.int64AsInt "\"-4.2e1\"" -42
                    , \_ -> decodes Proto.Json.int64AsInt "1.5E3" 1500
                    , \_ -> decodes Proto.Json.int64AsInt "\"9.007199254740991e15\"" 9007199254740991
                    ]
                    ()
        , test "exponent notation out of range fails" <|
            \_ -> fails Proto.Json.int64AsInt "\"9.007199254740992e15\""
        , test "exponent notation that leaves a fraction fails" <|
            \_ -> fails Proto.Json.int64AsInt "\"1.5e0\""
        , test "an empty string fails" <|
            \_ -> fails Proto.Json.int64AsInt "\"\""
        , test "a boolean fails" <|
            \_ -> fails Proto.Json.int64AsInt "true"
        , test "says why it fails" <|
            \_ ->
                Json.Decode.decodeString Proto.Json.int64AsInt "\"9007199254740992\""
                    |> Result.mapError Json.Decode.errorToString
                    |> Result.mapError (String.contains "Expecting an integer from -9007199254740991 to 9007199254740991, the 64-bit integers an Elm Int holds exactly, but got \"9007199254740992\"")
                    |> Expect.equal (Err True)
        , test "encodes as a decimal string" <|
            \_ ->
                Proto.Json.encodeInt64AsInt -9007199254740991
                    |> Json.Encode.encode 0
                    |> Expect.equal "\"-9007199254740991\""
        ]


floatTests : Test
floatTests =
    describe "float"
        [ test "a number" <|
            \_ -> decodes Proto.Json.float "1.5" 1.5
        , test "an integral number" <|
            \_ -> decodes Proto.Json.float "2" 2
        , test "a numeric string" <|
            \_ -> decodes Proto.Json.float "\"1.5\"" 1.5
        , test "\"NaN\"" <|
            \_ ->
                Json.Decode.decodeString Proto.Json.float "\"NaN\""
                    |> Result.map isNaN
                    |> Expect.equal (Ok True)
        , test "\"Infinity\"" <|
            \_ -> decodes Proto.Json.float "\"Infinity\"" (1 / 0)
        , test "\"-Infinity\"" <|
            \_ -> decodes Proto.Json.float "\"-Infinity\"" -(1 / 0)
        , test "another string fails" <|
            \_ -> fails Proto.Json.float "\"infinity\""
        , test "a boolean fails" <|
            \_ -> fails Proto.Json.float "false"
        , test "encodes a finite value as a number" <|
            \_ -> encodesTo (Proto.Json.encodeFloat 1.5) "1.5"
        , test "encodes NaN as a string" <|
            \_ -> encodesTo (Proto.Json.encodeFloat (0 / 0)) "\"NaN\""
        , test "encodes infinity as a string" <|
            \_ -> encodesTo (Proto.Json.encodeFloat (1 / 0)) "\"Infinity\""
        , test "encodes negative infinity as a string" <|
            \_ -> encodesTo (Proto.Json.encodeFloat -(1 / 0)) "\"-Infinity\""
        ]


bytesTests : Test
bytesTests =
    let
        accepts text =
            test ("accepts \"" ++ text ++ "\"") <|
                \_ -> decodes Proto.Json.bytes ("\"" ++ text ++ "\"") text

        rejects text =
            test ("rejects \"" ++ text ++ "\"") <|
                \_ -> fails Proto.Json.bytes ("\"" ++ text ++ "\"")
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
            \_ -> decodes Proto.Json.bytes "\"-_8\"" "-_8"
        , test "a number fails" <|
            \_ -> fails Proto.Json.bytes "1"
        , test "says why it fails" <|
            \_ ->
                Json.Decode.decodeString Proto.Json.bytes "\"a\""
                    |> Result.mapError (Json.Decode.errorToString >> String.contains "Expecting base64 (standard or URL-safe, padding optional), but got \"a\"")
                    |> Expect.equal (Err True)
        , test "encodes as a string" <|
            \_ -> encodesTo (Proto.Json.encodeBytes "aGk=") "\"aGk=\""
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
                Json.Decode.decodeString Proto.Json.struct """{"a":1,"b":null}"""
                    |> Result.map (Dict.map (\_ value -> Json.Encode.encode 0 value) >> Dict.toList)
                    |> Expect.equal (Ok [ ( "a", "1" ), ( "b", "null" ) ])
        , test "struct fails on an array" <|
            \_ -> fails Proto.Json.struct "[1]"
        , test "struct fails on null" <|
            \_ -> fails Proto.Json.struct "null"
        , test "encodeStruct writes an object" <|
            \_ ->
                encodesTo
                    (Proto.Json.encodeStruct (Dict.fromList [ ( "a", Json.Encode.int 1 ) ]))
                    """{"a":1}"""
        , test "listValue reads an array" <|
            \_ ->
                Json.Decode.decodeString Proto.Json.listValue """[1,"x",null]"""
                    |> Result.map (List.map (Json.Encode.encode 0))
                    |> Expect.equal (Ok [ "1", "\"x\"", "null" ])
        , test "listValue fails on an object" <|
            \_ -> fails Proto.Json.listValue """{"a":1}"""
        , test "encodeListValue writes an array" <|
            \_ ->
                encodesTo
                    (Proto.Json.encodeListValue [ Json.Encode.int 1, Json.Encode.null ])
                    "[1,null]"
        , test "a timestamp" <|
            \_ -> decodes Proto.Json.timestamp "\"1970-01-01T00:00:01.5Z\"" (Time.millisToPosix 1500)
        , test "a malformed timestamp fails" <|
            \_ -> fails Proto.Json.timestamp "\"yesterday\""
        , test "a timestamp as a number fails" <|
            \_ -> fails Proto.Json.timestamp "1500"
        , test "encodes a timestamp" <|
            \_ -> encodesTo (Proto.Json.encodeTimestamp (Time.millisToPosix 1500)) "\"1970-01-01T00:00:01.500Z\""
        , test "a duration" <|
            \_ -> decodes Proto.Json.duration "\"-1.5s\"" (Proto.Duration.fromSeconds -1.5)
        , test "a malformed duration fails" <|
            \_ -> fails Proto.Json.duration "\"1.5\""
        , test "encodes a duration" <|
            \_ -> encodesTo (Proto.Json.encodeDuration (Proto.Duration.fromSeconds 1.5)) "\"1.500s\""
        , test "a field mask comes back with proto field names" <|
            \_ ->
                decodes Proto.Json.fieldMask
                    "\"displayName,author.emailAddress,id\""
                    [ "display_name", "author.email_address", "id" ]
        , test "the empty field mask" <|
            \_ -> decodes Proto.Json.fieldMask "\"\"" []
        , test "encodes a field mask in lowerCamelCase" <|
            \_ ->
                encodesTo (Proto.Json.encodeFieldMask [ "display_name", "author.email_address" ])
                    "\"displayName,author.emailAddress\""
        , test "encodes the empty field mask" <|
            \_ -> encodesTo (Proto.Json.encodeFieldMask []) "\"\""
        , test "Empty is any object" <|
            \_ -> decodes Proto.Json.empty """{"ignored":1}""" ()
        , test "Empty is not an array" <|
            \_ -> fails Proto.Json.empty "[]"
        , test "encodes Empty as {}" <|
            \_ -> encodesTo (Proto.Json.encodeEmpty ()) "{}"
        ]


uint64Tests : Test
uint64Tests =
    describe "uint64"
        [ test "the forms int64 takes, zero or more" <|
            \_ ->
                Expect.all
                    [ \_ -> decodes Proto.Json.uint64 "\"18446744073709551615\"" "18446744073709551615"
                    , \_ -> decodes Proto.Json.uint64 "42" "42"
                    , \_ -> decodes Proto.Json.uint64 "\"1e3\"" "1000"
                    , \_ -> decodes Proto.Json.uint64 "\"-0\"" "0"
                    ]
                    ()
        , test "a negative value fails" <|
            \_ -> fails Proto.Json.uint64 "\"-1\""
        , test "a negative number fails" <|
            \_ -> fails Proto.Json.uint64 "-42"
        ]


uint64AsIntTests : Test
uint64AsIntTests =
    describe "uint64AsInt"
        [ test "the forms int64AsInt takes, zero or more" <|
            \_ ->
                Expect.all
                    [ \_ -> decodes Proto.Json.uint64AsInt "\"9007199254740991\"" 9007199254740991
                    , \_ -> decodes Proto.Json.uint64AsInt "0" 0
                    , \_ -> decodes Proto.Json.uint64AsInt "\"4.2e1\"" 42
                    ]
                    ()
        , test "a negative value fails" <|
            \_ -> fails Proto.Json.uint64AsInt "\"-1\""
        , test "a negative number fails" <|
            \_ -> fails Proto.Json.uint64AsInt "-42"
        , test "2^53 fails" <|
            \_ -> fails Proto.Json.uint64AsInt "\"9007199254740992\""
        ]


protoKeyTests : Test
protoKeyTests =
    let
        written : Maybe Json.Encode.Value -> Maybe String
        written =
            Maybe.map (Json.Encode.encode 0)

        pairs : Dict.Dict String String
        pairs =
            Dict.fromList [ ( "__proto__", "x" ), ( "a", "b" ) ]
    in
    describe "a __proto__ key"
        [ test "is written by dict" <|
            \_ ->
                Proto.Json.dict identity Json.Encode.string pairs
                    |> written
                    |> Expect.equal (Just "{\"__proto__\":\"x\",\"a\":\"b\"}")
        , test "is written by encodeStruct" <|
            \_ ->
                Dict.map (\_ -> Json.Encode.string) pairs
                    |> Proto.Json.encodeStruct
                    |> Json.Encode.encode 0
                    |> Expect.equal "{\"__proto__\":\"x\",\"a\":\"b\"}"
        , test "is written by object" <|
            \_ ->
                Proto.Json.object [ ( "__proto__", Just (Json.Encode.string "x") ), ( "a", Nothing ) ]
                    |> Json.Encode.encode 0
                    |> Expect.equal "{\"__proto__\":\"x\"}"
        , test "round-trips through dict" <|
            \_ ->
                Proto.Json.dict identity Json.Encode.string pairs
                    |> Maybe.andThen (Json.Decode.decodeValue (Json.Decode.dict Json.Decode.string) >> Result.toMaybe)
                    |> Expect.equal (Just pairs)
        ]
