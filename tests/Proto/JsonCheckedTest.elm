module Proto.JsonCheckedTest exposing (suite)

import Bytes.Encode
import Dict
import Expect
import Json.Encode
import Proto.Binary
import Proto.Duration as Duration
import Proto.Error exposing (Error(..))
import Proto.Json.Checked as Checked
import Test exposing (Test, describe, test)
import Time


suite : Test
suite =
    describe "Proto.Json.Checked"
        [ describe "timestamps"
            [ test "years 1 and 9999 are written" <|
                \_ ->
                    [ -62135596800000, 253402300799999 ]
                        |> List.map (Time.millisToPosix >> Checked.encodeTimestamp >> Result.map (Json.Encode.encode 0))
                        |> Expect.equal [ Ok "\"0001-01-01T00:00:00Z\"", Ok "\"9999-12-31T23:59:59.999Z\"" ]
            , test "a millisecond past either end is refused" <|
                \_ ->
                    [ -62135596800001, 253402300800000 ]
                        |> List.map (Time.millisToPosix >> Checked.encodeTimestamp >> Result.map (Json.Encode.encode 0))
                        |> Expect.equal [ Err (NoJsonForm "google.protobuf.Timestamp"), Err (NoJsonForm "google.protobuf.Timestamp") ]
            ]
        , describe "durations"
            [ test "the limit is written" <|
                \_ ->
                    Duration.fromPartsUnclamped 315576000000 0
                        |> Checked.encodeDuration
                        |> Result.map (Json.Encode.encode 0)
                        |> Expect.equal (Ok "\"315576000000s\"")
            , test "a second past it is refused" <|
                \_ ->
                    [ Duration.fromPartsUnclamped 315576000001 0, Duration.fromPartsUnclamped -315576000001 0 ]
                        |> List.map (Checked.encodeDuration >> Result.map (Json.Encode.encode 0))
                        |> Expect.equal [ Err (NoJsonForm "google.protobuf.Duration"), Err (NoJsonForm "google.protobuf.Duration") ]
            , test "binary past the range is read unclamped" <|
                \_ ->
                    Bytes.Encode.encode (Proto.Binary.implicit Proto.Binary.int64AsInt 1 315576000001)
                        |> Proto.Binary.decode (Proto.Binary.messageDecoder Checked.binaryDuration)
                        |> Result.map Duration.toParts
                        |> Expect.equal (Ok { seconds = 315576000001, nanos = 0 })
            ]
        , describe "field masks"
            [ test "paths that survive the lowerCamelCase round trip are written" <|
                \_ ->
                    Checked.encodeFieldMask [ "display_name", "author.email_address", "a" ]
                        |> Result.map (Json.Encode.encode 0)
                        |> Expect.equal (Ok "\"displayName,author.emailAddress,a\"")
            , test "the suite's three paths are refused" <|
                \_ ->
                    [ "fooBar", "foo_3_bar", "foo__bar" ]
                        |> List.map (\path -> Checked.encodeFieldMask [ "ok", path ])
                        |> Expect.equal (List.repeat 3 (Err (NoJsonForm "google.protobuf.FieldMask")))
            ]
        , describe "values"
            [ test "finite JSON is written as it is" <|
                \_ ->
                    Json.Encode.object [ ( "a", Json.Encode.list Json.Encode.float [ 1.5, -2 ] ), ( "b", Json.Encode.null ) ]
                        |> Checked.encodeValue
                        |> Result.map (Json.Encode.encode 0)
                        |> Expect.equal (Ok "{\"a\":[1.5,-2],\"b\":null}")
            , test "NaN and the infinities are refused at any depth" <|
                \_ ->
                    [ Json.Encode.float (0 / 0)
                    , Json.Encode.list Json.Encode.float [ 1, 1 / 0 ]
                    , Json.Encode.object [ ( "x", Json.Encode.object [ ( "y", Json.Encode.float (-1 / 0) ) ] ) ]
                    ]
                        |> List.map Checked.encodeValue
                        |> Expect.equal (List.repeat 3 (Err (NoJsonForm "google.protobuf.Value")))
            , test "a Struct and a ListValue refuse a member or element" <|
                \_ ->
                    ( Checked.encodeStruct (Dict.fromList [ ( "n", Json.Encode.float (0 / 0) ) ])
                    , Checked.encodeListValue [ Json.Encode.string "s", Json.Encode.float (1 / 0) ]
                    )
                        |> Expect.equal ( Err (NoJsonForm "google.protobuf.Struct"), Err (NoJsonForm "google.protobuf.ListValue") )
            ]
        ]
