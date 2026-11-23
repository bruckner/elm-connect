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


refusal : Proto.Json.Encoder -> Maybe ( String, List String )
refusal encoder =
    case Proto.Json.encode encoder of
        Err (NotWritable { typeName, path }) ->
            Just ( typeName, path )

        _ ->
            Nothing


written : Proto.Json.Encoder -> Result Error String
written =
    Proto.Json.encode >> Result.map (Json.Encode.encode 0)


writtenWith : Proto.Json.Encoder -> Result Error String
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
positive : Int -> Proto.Json.Encoder
positive n =
    if n < 0 then
        Proto.Json.writeTimestamp farFuture

    else
        Proto.Json.ready (Json.Encode.int n)


{-| An `Any` holding a registered message, which only a registry writes.
-}
packed : Proto.Any.Any
packed =
    Proto.Any.pack Proto.WellKnown.stringValue "hi"


{-| An `Any` inside `levels` levels of a message on a cycle.
-}
deeperAny : Int -> Proto.Json.Encoder
deeperAny levels =
    if levels <= 0 then
        Proto.Json.writeAny packed

    else
        Proto.Json.writeObject [] [ ( "next", Proto.Json.writeDeeper (deeperAny (levels - 1)) ) ]


suite : Test
suite =
    describe "Proto.Json encoders"
        [ test "a value with a JSON form is written, fields that cannot fail first" <|
            \_ ->
                Proto.Json.writeObject [ ( "a", Just (Json.Encode.int 1) ), ( "b", Nothing ) ]
                    [ ( "t", Proto.Json.writeOptional Proto.Json.writeTimestamp (Just (Time.millisToPosix 0)) )
                    , ( "u", Proto.Json.writeOptional Proto.Json.writeTimestamp Nothing )
                    ]
                    |> written
                    |> Expect.equal (Ok """{"a":1,"t":"1970-01-01T00:00:00Z"}""")
        , test "each kind of value with no JSON form is refused, named, at its path" <|
            \_ ->
                [ Proto.Json.writeObject [] [ ( "when", Proto.Json.writeTimestamp farFuture ) ]
                , Proto.Json.writeObject [] [ ( "ttl", Proto.Json.writeDuration (Proto.Duration.fromParts 315576000001 0) ) ]
                , Proto.Json.writeObject [] [ ( "mask", Proto.Json.writeFieldMask [ "fooBar" ] ) ]
                , Proto.Json.writeObject [] [ ( "items", Proto.Json.writeRepeated Proto.Json.writeValue [ ValueNumber 1, ValueNumber (0 / 0) ] ) ]
                , Proto.Json.writeObject [] [ ( "data", Proto.Json.writeStruct (Dict.singleton "x" (ValueNumber (1 / 0))) ) ]
                , Proto.Json.writeObject [] [ ( "list", Proto.Json.writeListValue [ ValueList [ ValueNumber (-1 / 0) ] ] ) ]
                ]
                    |> List.map refusal
                    |> Expect.equal
                        [ Just ( "google.protobuf.Timestamp", [ "when" ] )
                        , Just ( "google.protobuf.Duration", [ "ttl" ] )
                        , Just ( "google.protobuf.FieldMask", [ "mask" ] )
                        , Just ( "google.protobuf.Value", [ "items", "1" ] )
                        , Just ( "google.protobuf.Struct", [ "data" ] )
                        , Just ( "google.protobuf.ListValue", [ "list" ] )
                        ]
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
                Proto.Json.writeObject [ ( "id", Just (Json.Encode.int 1) ) ]
                    [ ( "inner"
                      , Proto.Json.writeObject []
                            [ ( "byName", Proto.Json.writeDict identity (Proto.Json.writeRepeated positive) (Dict.fromList [ ( "a", [ 1 ] ), ( "b", [ 2, -3 ] ) ]) ) ]
                      )
                    ]
                    |> refusal
                    |> Expect.equal (Just ( "google.protobuf.Timestamp", [ "inner", "byName", "b", "1" ] ))
        , test "an object is refused at its first refused field, in order" <|
            \_ ->
                Proto.Json.writeObject [] [ ( "a", Proto.Json.writeField Nothing ), ( "b", positive -1 ), ( "c", Proto.Json.writeDuration (Proto.Duration.fromParts 315576000001 0) ) ]
                    |> refusal
                    |> Expect.equal (Just ( "google.protobuf.Timestamp", [ "b" ] ))
        , test "fields left out: an absent optional, an empty repeated field and map" <|
            \_ ->
                Proto.Json.writeObject []
                    [ ( "a", Proto.Json.writeOptional positive Nothing )
                    , ( "b", Proto.Json.writeRepeated positive [] )
                    , ( "c", Proto.Json.writeDict String.fromInt positive Dict.empty )
                    , ( "d", Proto.Json.writeBoolMap positive [] )
                    , ( "e", Proto.Json.writeField Nothing )
                    , ( "f", Proto.Json.writeField (Just (Json.Encode.int 6)) )
                    ]
                    |> written
                    |> Expect.equal (Ok """{"f":6}""")
        , test "a map field is keyed as given, a bool-keyed one false and true, and keeps a __proto__ key" <|
            \_ ->
                [ Proto.Json.writeDict String.fromInt positive (Dict.fromList [ ( 2, 20 ), ( 1, 10 ) ])
                , Proto.Json.writeBoolMap positive [ ( False, 0 ), ( True, 1 ) ]
                , Proto.Json.writeDict identity positive (Dict.fromList [ ( "__proto__", 1 ) ])
                , Proto.Json.writeObject [] [ ( "__proto__", positive 2 ) ]
                ]
                    |> List.map written
                    |> Expect.equal [ Ok """{"1":10,"2":20}""", Ok """{"false":0,"true":1}""", Ok """{"__proto__":1}""", Ok """{"__proto__":2}""" ]
        , test "an Any holding a message needs the registry" <|
            \_ ->
                [ written (Proto.Json.writeObject [] [ ( "a", Proto.Json.writeAny packed ) ])
                , writtenWith (Proto.Json.writeObject [] [ ( "a", Proto.Json.writeAny packed ) ])
                ]
                    |> Expect.equal
                        [ Err (UnregisteredType "type.googleapis.com/google.protobuf.StringValue")
                        , Ok """{"a":{"@type":"type.googleapis.com/google.protobuf.StringValue","value":"hi"}}"""
                        ]
        , test "a deferred object runs its fields in order, and a deferred list keeps its order and indexes" <|
            \_ ->
                [ written (Proto.Json.writeObject [] [ ( "a", Proto.Json.writeAny packed ), ( "b", positive -1 ) ])
                , writtenWith (Proto.Json.writeRepeated identity [ positive 1, Proto.Json.writeAny packed, positive 3 ])
                , writtenWith (Proto.Json.writeRepeated identity [ positive 1, Proto.Json.writeAny packed, positive -3 ])
                ]
                    |> Expect.equal
                        [ Err (UnregisteredType "type.googleapis.com/google.protobuf.StringValue")
                        , Ok """[1,{"@type":"type.googleapis.com/google.protobuf.StringValue","value":"hi"},3]"""
                        , Err (NotWritable { typeName = "google.protobuf.Timestamp", path = [ "2" ] })
                        ]
        , test "levels written deeper count toward an Any's limit of 100" <|
            \_ ->
                [ writtenWith (deeperAny 99) |> Result.map (always ())
                , writtenWith (deeperAny 100) |> Result.map (always ())
                ]
                    |> Expect.equal
                        [ Ok ()
                        , Err (BadBinary { typeName = "google.protobuf.Any", reason = Proto.Error.TooDeep, path = [], offset = 0 })
                        ]
        , test "levels written deeper that hold no Any are not counted" <|
            \_ ->
                List.foldl (\_ inner -> Proto.Json.writeObject [] [ ( "next", Proto.Json.writeDeeper inner ) ]) (positive 1) (List.range 1 150)
                    |> written
                    |> Result.map String.length
                    |> Expect.equal (Ok (150 * String.length """{"next":}""" + 1))
        ]
