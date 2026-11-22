module Proto.ValueTest exposing (suite)

{-| `google.protobuf.Value`, `Struct` and `ListValue` held as `Proto.Value.Value`:
`==` compares what they hold, what is read writes back in both codecs, and
`toJson`/`fromJson` hand values to and from elm/json.
-}

import Bytes
import Bytes.Encode
import Dict
import Expect
import Generated.Deep.Cycles.V1 as Deep
import Json.Decode
import Json.Encode
import Proto.Binary
import Proto.Error
import Proto.Json
import Proto.Value exposing (Value(..))
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "Proto.Value"
        [ equality
        , roundTrips
        , conversions
        ]


fromText : String -> Result Json.Decode.Error Value
fromText =
    Json.Decode.decodeString Proto.Json.jsonValue


struct : List ( String, Value ) -> Value
struct =
    ValueStruct << Dict.fromList


equality : Test
equality =
    describe "=="
        [ test "an object is not equal to one with a member more, either way round" <|
            \_ ->
                Expect.all
                    [ \_ -> fromText """{"a":1}""" |> Expect.notEqual (fromText """{"a":1,"b":2}""")
                    , \_ -> fromText """{"a":1,"b":2}""" |> Expect.notEqual (fromText """{"a":1}""")
                    , \_ -> struct [ ( "a", ValueNumber 1 ) ] |> Expect.notEqual (struct [ ( "a", ValueNumber 1 ), ( "b", ValueNumber 2 ) ])
                    ]
                    ()
        , test "an array is not equal to a longer one" <|
            \_ -> fromText "[1]" |> Expect.notEqual (fromText "[1,2]")
        , test "a member null is not an absent member" <|
            \_ -> fromText """{"a":null}""" |> Expect.notEqual (fromText "{}")
        , test "an empty object is not an empty array" <|
            \_ -> fromText "{}" |> Expect.notEqual (fromText "[]")
        , test "key order does not matter" <|
            \_ -> fromText """{"a":1,"b":[true,null]}""" |> Expect.equal (fromText """{"b":[true,null],"a":1}""")
        , test "1 and 1.0 are equal, and so are -0 and 0" <|
            \_ ->
                Expect.all
                    [ \_ -> fromText "1" |> Expect.equal (fromText "1.0")
                    , \_ -> fromText "-0" |> Expect.equal (fromText "0")
                    ]
                    ()
        , test "NaN read from binary equals nothing, itself included" <|
            \_ ->
                case ( readNan (), readNan () ) of
                    ( Ok ((ValueNumber n) as one), Ok other ) ->
                        Expect.all
                            [ \_ -> isNaN n |> Expect.equal True
                            , \_ -> (one == other) |> Expect.equal False
                            ]
                            ()

                    _ ->
                        Expect.fail "did not read a number"
        , test "a generated message holding a Struct compares what it holds" <|
            \_ ->
                let
                    holding text =
                        Json.Decode.decodeString (Deep.decodeEnvelopeWith Deep.registry) ("{\"data\":" ++ text ++ "}")
                in
                Expect.all
                    [ \_ -> holding """{"a":1}""" |> Expect.notEqual (holding """{"a":1,"b":2}""")
                    , \_ -> holding """{"a":1,"b":2}""" |> Expect.equal (holding """{"b":2,"a":1}""")
                    ]
                    ()
        ]


{-| A binary `Value` holding the double NaN, read; each read is a new value,
since `==` finds a value equal to itself before comparing what it holds.
-}
readNan : () -> Result Proto.Error.Binary Value
readNan () =
    Proto.Binary.decode (Proto.Binary.messageDecoder Proto.Binary.value) (nanBytes ())


nanBytes : () -> Bytes.Bytes
nanBytes () =
    Bytes.Encode.encode
        (Bytes.Encode.sequence
            [ Bytes.Encode.unsignedInt8 0x11
            , Bytes.Encode.float64 Bytes.LE (0 / 0)
            ]
        )


{-| Values read from JSON, every kind, nested.
-}
samples : List String
samples =
    [ "null"
    , "true"
    , "-2.5e-3"
    , "\"text\""
    , "[]"
    , "{}"
    , """{"a":[1,{"b":null},"c",false],"d":{}}"""
    , """[[[]],{"__proto__":1}]"""
    ]


roundTrips : Test
roundTrips =
    describe "what is read writes back"
        (List.map
            (\text ->
                test text <|
                    \_ ->
                        case fromText text of
                            Ok value ->
                                Expect.all
                                    [ \_ -> Json.Decode.decodeValue Proto.Json.jsonValue (Proto.Json.encodeValue value) |> Expect.equal (Ok value)
                                    , \_ -> Proto.Binary.decode (Proto.Binary.messageDecoder Proto.Binary.value) (Proto.Binary.encode (Proto.Binary.messageEncoder Proto.Binary.value) value) |> Expect.equal (Ok value)
                                    ]
                                    ()

                            Err _ ->
                                Expect.fail "did not read"
            )
            samples
        )


conversions : Test
conversions =
    describe "toJson and fromJson"
        [ test "fromJson reads what toJson writes" <|
            \_ ->
                List.filterMap (fromText >> Result.toMaybe) samples
                    |> List.map (\value -> Proto.Value.fromJson (Proto.Value.toJson value) == Just value)
                    |> Expect.equal (List.map (\_ -> True) samples)
        , test "an object comes out in key order and keeps a __proto__ key" <|
            \_ ->
                Proto.Value.toJson (struct [ ( "z", ValueNull ), ( "__proto__", ValueBool True ), ( "a", ValueList [] ) ])
                    |> Json.Encode.encode 0
                    |> Expect.equal """{"__proto__":true,"a":[],"z":null}"""
        , test "a number that is not finite writes JSON null and binary keeps it" <|
            \_ ->
                Expect.all
                    [ \_ -> Proto.Value.toJson (ValueNumber (1 / 0)) |> Json.Encode.encode 0 |> Expect.equal "null"
                    , \_ ->
                        Proto.Binary.decode (Proto.Binary.messageDecoder Proto.Binary.value) (Proto.Binary.encode (Proto.Binary.messageEncoder Proto.Binary.value) (ValueNumber (-1 / 0)))
                            |> Expect.equal (Ok (ValueNumber (-1 / 0)))
                    ]
                    ()
        , test "fromJson reads 100 nested arrays and refuses 101" <|
            \_ ->
                let
                    lists depth =
                        Json.Decode.decodeString Json.Decode.value (String.repeat depth "[" ++ String.repeat depth "]")
                            |> Result.toMaybe
                            |> Maybe.andThen Proto.Value.fromJson
                            |> Maybe.map (\_ -> ())
                in
                ( lists 100, lists 101 ) |> Expect.equal ( Just (), Nothing )
        ]
