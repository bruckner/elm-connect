module Proto.WriteTest exposing (suite)

import Dict
import Expect
import Json.Encode
import Proto.Any
import Proto.Duration
import Proto.Error exposing (Error(..))
import Proto.Json
import Proto.Value exposing (Value(..))
import Proto.WellKnown
import Test exposing (Test, describe, test)
import Time


refusal : Proto.Json.Encoder Error -> Maybe ( String, List String )
refusal encoder =
    case Proto.Json.encode encoder of
        Err (BadValue { typeName, path }) ->
            Just ( typeName, path )

        _ ->
            Nothing


written : Proto.Json.Encoder Error -> Result Error String
written =
    Proto.Json.encode >> Result.map (Json.Encode.encode 0)


writtenWith : Proto.Json.Encoder Error -> Result Error String
writtenWith =
    Proto.Json.encodeWith Proto.WellKnown.registry >> Result.map (Json.Encode.encode 0)


{-| A timestamp proto3 JSON has no form for: past year 9999.
-}
farFuture : Time.Posix
farFuture =
    Time.millisToPosix 300000000000000


{-| An encoder of an `Int` that refuses negative numbers, as a timestamp too
far out.
-}
positive : Int -> Proto.Json.Encoder Error
positive n =
    if n < 0 then
        Proto.Json.writeTimestamp farFuture

    else
        Proto.Json.succeed (Json.Encode.int n)


{-| An `Any` holding a registered message, which only a registry writes.
-}
packed : Proto.Any.Any
packed =
    Proto.Any.pack Proto.WellKnown.stringValue "hi"


{-| An object of fields that can be refused.
-}
checked : List ( String, Proto.Json.Field Error ) -> Proto.Json.Encoder Error
checked fields =
    Proto.Json.writeObject [ Proto.Json.checkedFields fields ]


{-| A field holding the value an encoder writes.
-}
holding : Proto.Json.Encoder Error -> Proto.Json.Field Error
holding =
    Proto.Json.writeMember


{-| An `Any` inside `levels` levels of messages that nest, the outermost read
at 1.
-}
deeperAny : Int -> Proto.Json.Encoder Error
deeperAny levels =
    if levels <= 0 then
        checked [ ( "any", holding (Proto.Json.writeAny packed) ) ]

    else
        checked [ ( "next", Proto.Json.writeDeeper (holding (deeperAny (levels - 1))) ) ]


suite : Test
suite =
    describe "Proto.Json encoders"
        [ test "a value with a JSON form is written, its fields in the order given, whichever can be refused" <|
            \_ ->
                Proto.Json.writeObject
                    [ Proto.Json.plainFields [ ( "a", Just (Json.Encode.int 1) ), ( "b", Nothing ) ]
                    , Proto.Json.checkedFields
                        [ ( "t", Proto.Json.writeOptional Proto.Json.writeTimestamp (Just (Time.millisToPosix 0)) )
                        , ( "u", Proto.Json.writeOptional Proto.Json.writeTimestamp Nothing )
                        ]
                    , Proto.Json.plainFields [ ( "c", Just (Json.Encode.int 3) ) ]
                    , Proto.Json.checkedFields [ ( "d", holding (positive 4) ) ]
                    ]
                    |> written
                    |> Expect.equal (Ok """{"a":1,"t":"1970-01-01T00:00:00Z","c":3,"d":4}""")
        , test "a deferred object keeps the order of its runs" <|
            \_ ->
                Proto.Json.writeObject
                    [ Proto.Json.plainFields [ ( "a", Just (Json.Encode.int 1) ) ]
                    , Proto.Json.checkedFields [ ( "b", holding (Proto.Json.writeAny packed) ) ]
                    , Proto.Json.plainFields [ ( "c", Just (Json.Encode.int 3) ), ( "d", Nothing ) ]
                    , Proto.Json.checkedFields [ ( "e", holding (positive 5) ) ]
                    ]
                    |> writtenWith
                    |> Expect.equal (Ok """{"a":1,"b":{"@type":"type.googleapis.com/google.protobuf.StringValue","value":"hi"},"c":3,"e":5}""")
        , test "each kind of value with no JSON form is refused, named, at its path" <|
            \_ ->
                [ checked [ ( "when", holding (Proto.Json.writeTimestamp farFuture) ) ]
                , checked [ ( "mask", holding (Proto.Json.writeFieldMask [ "fooBar" ]) ) ]
                , checked [ ( "items", Proto.Json.writeRepeated Proto.Json.writeValue [ ValueNumber 1, ValueNumber (0 / 0) ] ) ]
                , checked [ ( "data", holding (Proto.Json.writeStruct (Dict.singleton "x" (ValueNumber (1 / 0)))) ) ]
                , checked [ ( "list", holding (Proto.Json.writeListValue [ ValueList [ ValueNumber (-1 / 0) ] ]) ) ]
                ]
                    |> List.map refusal
                    |> Expect.equal
                        [ Just ( "google.protobuf.Timestamp", [ "when" ] )
                        , Just ( "google.protobuf.FieldMask", [ "mask" ] )
                        , Just ( "google.protobuf.Value", [ "items", "1" ] )
                        , Just ( "google.protobuf.Struct", [ "data" ] )
                        , Just ( "google.protobuf.ListValue", [ "list" ] )
                        ]
        , test "a refusal says what and where" <|
            \_ ->
                checked [ ( "events", Proto.Json.writeRepeated Proto.Json.writeTimestamp [ Time.millisToPosix 0, farFuture ] ) ]
                    |> Proto.Json.encode
                    |> Result.mapError Proto.Error.toString
                    |> Expect.equal (Err "A google.protobuf.Timestamp holds a value proto3 JSON has no form for, at events.1.")
        , test "the limits themselves are written" <|
            \_ ->
                [ Proto.Json.writeTimestamp (Time.millisToPosix -62135596800000)
                , Proto.Json.writeTimestamp (Time.millisToPosix 253402300799999)
                , Proto.Json.writeDuration (Proto.Duration.fromParts 315576000000 999999999)
                , Proto.Json.writeDuration (Proto.Duration.fromParts -315576000000 -999999999)
                , Proto.Json.writeFieldMask [ "foo_bar.baz" ]
                ]
                    |> List.map written
                    |> Expect.equal
                        [ Ok "\"0001-01-01T00:00:00Z\""
                        , Ok "\"9999-12-31T23:59:59.999Z\""
                        , Ok "\"315576000000.999999999s\""
                        , Ok "\"-315576000000.999999999s\""
                        , Ok "\"fooBar.baz\""
                        ]
        , test "the path goes through nested objects, list indexes and map keys, outermost first" <|
            \_ ->
                Proto.Json.writeObject
                    [ Proto.Json.plainFields [ ( "id", Just (Json.Encode.int 1) ) ]
                    , Proto.Json.checkedFields
                        [ ( "inner"
                          , holding
                                (checked
                                    [ ( "byName", Proto.Json.writeDict identity (\items -> checked [ ( "items", Proto.Json.writeRepeated positive items ) ]) (Dict.fromList [ ( "a", [ 1 ] ), ( "b", [ 2, -3 ] ) ]) ) ]
                                )
                          )
                        ]
                    ]
                    |> refusal
                    |> Expect.equal (Just ( "google.protobuf.Timestamp", [ "inner", "byName", "b", "items", "1" ] ))
        , test "an object is refused at its first refused field, in order" <|
            \_ ->
                Proto.Json.writeObject
                    [ Proto.Json.checkedFields [ ( "a", Proto.Json.writeOptional positive Nothing ) ]
                    , Proto.Json.plainFields [ ( "b", Just (Json.Encode.int 2) ) ]
                    , Proto.Json.checkedFields [ ( "c", holding (positive -1) ), ( "d", holding (Proto.Json.writeFieldMask [ "fooBar" ]) ) ]
                    ]
                    |> refusal
                    |> Expect.equal (Just ( "google.protobuf.Timestamp", [ "c" ] ))
        , test "fields left out: an absent optional, an empty repeated field and map" <|
            \_ ->
                checked
                    [ ( "a", Proto.Json.writeOptional positive Nothing )
                    , ( "b", Proto.Json.writeRepeated positive [] )
                    , ( "c", Proto.Json.writeDict String.fromInt positive Dict.empty )
                    , ( "d", Proto.Json.writeBoolMap positive [] )
                    , ( "f", holding (positive 6) )
                    ]
                    |> written
                    |> Expect.equal (Ok """{"f":6}""")
        , test "a map field is keyed as given, a bool-keyed one false and true, and keeps a __proto__ key" <|
            \_ ->
                [ checked [ ( "m", Proto.Json.writeDict String.fromInt positive (Dict.fromList [ ( 2, 20 ), ( 1, 10 ) ]) ) ]
                , checked [ ( "m", Proto.Json.writeBoolMap positive [ ( False, 0 ), ( True, 1 ) ] ) ]
                , checked [ ( "m", Proto.Json.writeDict identity positive (Dict.fromList [ ( "__proto__", 1 ) ]) ) ]
                , checked [ ( "__proto__", holding (positive 2) ) ]
                ]
                    |> List.map written
                    |> Expect.equal [ Ok """{"m":{"1":10,"2":20}}""", Ok """{"m":{"false":0,"true":1}}""", Ok """{"m":{"__proto__":1}}""", Ok """{"__proto__":2}""" ]
        , test "an Any holding a message needs the registry" <|
            \_ ->
                [ written (checked [ ( "a", holding (Proto.Json.writeAny packed) ) ])
                , writtenWith (checked [ ( "a", holding (Proto.Json.writeAny packed) ) ])
                ]
                    |> Expect.equal
                        [ Err (UnregisteredType "type.googleapis.com/google.protobuf.StringValue")
                        , Ok """{"a":{"@type":"type.googleapis.com/google.protobuf.StringValue","value":"hi"}}"""
                        ]
        , test "a deferred object runs its fields in order, and a deferred list keeps its order and indexes" <|
            \_ ->
                [ written (checked [ ( "a", holding (Proto.Json.writeAny packed) ), ( "b", holding (positive -1) ) ])
                , writtenWith (checked [ ( "l", Proto.Json.writeRepeated identity [ positive 1, Proto.Json.writeAny packed, positive 3 ] ) ])
                , writtenWith (checked [ ( "l", Proto.Json.writeRepeated identity [ positive 1, Proto.Json.writeAny packed, positive -3 ] ) ])
                ]
                    |> Expect.equal
                        [ Err (UnregisteredType "type.googleapis.com/google.protobuf.StringValue")
                        , Ok """{"l":[1,{"@type":"type.googleapis.com/google.protobuf.StringValue","value":"hi"},3]}"""
                        , Err (BadValue { typeName = "google.protobuf.Timestamp", path = [ "l", "2" ] })
                        ]
        , test "levels written deeper count toward an Any's limit of 100" <|
            \_ ->
                [ writtenWith (deeperAny 98) |> Result.map (always ())
                , writtenWith (deeperAny 99) |> Result.map (always ())
                ]
                    |> Expect.equal
                        [ Ok ()
                        , Err (BadBinary { typeName = "google.protobuf.Any", reason = Proto.Error.TooDeep, path = [], offset = 0 })
                        ]
        , test "levels written deeper that hold no Any are not counted" <|
            \_ ->
                List.foldl (\_ inner -> checked [ ( "next", Proto.Json.writeDeeper (holding inner) ) ]) (positive 1) (List.range 1 150)
                    |> written
                    |> Result.map String.length
                    |> Expect.equal (Ok (150 * String.length """{"next":}""" + 1))
        , test "a total encoder is written without a Result" <|
            \_ ->
                Proto.Json.writeObject [ Proto.Json.plainFields [ ( "a", Just (Json.Encode.int 1) ) ] ]
                    |> Proto.Json.encodeTotal
                    |> Json.Encode.encode 0
                    |> Expect.equal """{"a":1}"""
        ]
