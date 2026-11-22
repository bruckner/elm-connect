module Proto.DepthTest exposing (suite)

{-| Reads nest at most 100 levels deep, a level being each message entered
along a field or oneof member of a cycle, each `Any`, and each array or
object of a `Value`, `Struct` or `ListValue`, all counted against one
budget: every shape of cycle in `conformance/cases/depth_cycles`, two under
`unknown_fields=keep` in `conformance/cases/depth_cycles_keep` (generated
under `tests/Generated/` by `crates/elm-connect-gen/tests/depth.rs`,
`just tests-gen`), and the three kinds mixed, at 100 levels, at 101, and
far past any engine's stack, built here without recursion.
-}

import Bytes exposing (Bytes)
import Bytes.Encode
import Dict
import Expect exposing (Expectation)
import Generated.Deep.Cycles.V1 as Deep
import Generated.Deep.Outside.V1 as Outside
import Generated.DeepKeep.Cycles.V1 as Keep
import Http
import Json.Decode
import Json.Encode
import Proto.Any
import Proto.Binary
import Proto.Bytes
import Proto.Error
import Proto.Json
import Proto.Message
import Proto.Method
import Proto.WellKnown
import Rpc
import Rpc.Client
import Rpc.Error
import Rpc.Protocol
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "nesting depth"
        [ describe "binary" (List.map binaryShape shapes)
        , describe "JSON" (List.map jsonShape shapes)
        , binaryFailure
        , mergedInto
        , keep
        , farPast
        , oneBudget
        , mixedFarPast
        , scrubbed
        ]



-- SHAPES


{-| One shape of cycle: its name, how to read it from binary and from JSON
(each giving whether it read), the binary prefix of the message at a depth
holding the next level, given the next level's size, and the JSON around
the next level.
-}
type alias Shape =
    { name : String
    , binary : Bytes -> Result Proto.Error.Binary ()
    , json : String -> Result Json.Decode.Error ()
    , prefix : Int -> Int -> List Int
    , open : Int -> String
    , close : Int -> String
    }


ok : Result e a -> Result e ()
ok =
    Result.map (\_ -> ())


shapes : List Shape
shapes =
    [ { name = "a message that holds itself"
      , binary = Proto.Binary.decode Deep.decodeChainBytes >> ok
      , json = Json.Decode.decodeString Deep.decodeChain >> ok
      , prefix = \_ size -> 0x12 :: varint size
      , open = \_ -> "{\"next\":"
      , close = \_ -> "}"
      }
    , { name = "through a list"
      , binary = Proto.Binary.decode Deep.decodeTreeBytes >> ok
      , json = Json.Decode.decodeString Deep.decodeTree >> ok
      , prefix = \_ size -> 0x12 :: varint size
      , open = \_ -> "{\"children\":["
      , close = \_ -> "]}"
      }
    , { name = "through a map's values"
      , binary = Proto.Binary.decode Deep.decodeDirBytes >> ok
      , json = Json.Decode.decodeString Deep.decodeDir >> ok
      , prefix =
            \_ size ->
                let
                    entry =
                        [ 0x0A, 1, 0x61, 0x12 ] ++ varint size
                in
                0x0A :: varint (List.length entry + size) ++ entry
      , open = \_ -> "{\"entries\":{\"a\":"
      , close = \_ -> "}}"
      }
    , { name = "through a oneof member"
      , binary = Proto.Binary.decode Deep.decodeExprBytes >> ok
      , json = Json.Decode.decodeString Deep.decodeExpr >> ok
      , prefix = \_ size -> 0x12 :: varint size
      , open = \_ -> "{\"negated\":"
      , close = \_ -> "}"
      }
    , { name = "two messages that hold each other"
      , binary = Proto.Binary.decode Deep.decodePersonBytes >> ok
      , json = Json.Decode.decodeString Deep.decodePerson >> ok
      , prefix =
            \depth size ->
                if modBy 2 depth == 1 then
                    0x12 :: varint size

                else
                    0x0A :: varint size
      , open =
            \depth ->
                if modBy 2 depth == 1 then
                    "{\"team\":"

                else
                    "{\"members\":["
      , close =
            \depth ->
                if modBy 2 depth == 1 then
                    "}"

                else
                    "]}"
      }
    , { name = "three messages"
      , binary = Proto.Binary.decode Deep.decodeFirstBytes >> ok
      , json = Json.Decode.decodeString Deep.decodeFirst >> ok
      , prefix = \_ size -> 0x0A :: varint size
      , open =
            \depth ->
                case modBy 3 depth of
                    1 ->
                        "{\"second\":"

                    2 ->
                        "{\"third\":"

                    _ ->
                        "{\"firsts\":["
      , close =
            \depth ->
                if modBy 3 depth == 0 then
                    "]}"

                else
                    "}"
      }
    , { name = "wider than a record literal"
      , binary = Proto.Binary.decode Deep.decodeWideBytes >> ok
      , json = Json.Decode.decodeString Deep.decodeWide >> ok
      , prefix = \_ size -> 0x8A :: 0x04 :: varint size
      , open = \_ -> "{\"children\":["
      , close = \_ -> "]}"
      }
    , { name = "holding an Any"
      , binary = Proto.Binary.decode Deep.decodeEnvelopeBytes >> ok
      , json = Json.Decode.decodeString (Deep.decodeEnvelopeWith Proto.WellKnown.registry) >> ok
      , prefix = \_ size -> 0x12 :: varint size
      , open = \_ -> "{\"replies\":["
      , close = \_ -> "]}"
      }
    ]


{-| The binary of `levels` messages of `shape`, the innermost empty, and
the prefixes from the outermost in.
-}
nested : Shape -> Int -> ( Bytes, List (List Int) )
nested shape levels =
    let
        ( _, prefixes ) =
            List.foldl
                (\depth ( size, acc ) ->
                    let
                        p =
                            shape.prefix depth size
                    in
                    ( size + List.length p, p :: acc )
                )
                ( 0, [] )
                (List.reverse (List.range 1 (levels - 1)))
    in
    ( Bytes.Encode.encode (Bytes.Encode.sequence (List.map Bytes.Encode.unsignedInt8 (List.concat prefixes)))
    , prefixes
    )


binaryOf : Shape -> Int -> Bytes
binaryOf shape levels =
    Tuple.first (nested shape levels)


jsonOf : Shape -> Int -> String
jsonOf shape levels =
    let
        depths =
            List.range 1 (levels - 1)
    in
    String.concat (List.map shape.open depths)
        ++ "{}"
        ++ String.concat (List.map shape.close (List.reverse depths))


varint : Int -> List Int
varint n =
    if n < 128 then
        [ n ]

    else
        (128 + modBy 128 n) :: varint (n // 128)


tooDeepText : String
tooDeepText =
    "Expecting messages nested at most 100 deep"


{-| The failure's text, found by following its path rather than through
`Json.Decode.errorToString`, which prints the JSON where it failed: a value
thousands of levels deep pretty-printed is longer than a string can be.
-}
failsTooDeep : Result Json.Decode.Error () -> Expectation
failsTooDeep result =
    case result of
        Ok () ->
            Expect.fail "read past the limit"

        Err error ->
            failureTexts [ error ] []
                |> List.member tooDeepText
                |> Expect.equal True


failureTexts : List Json.Decode.Error -> List String -> List String
failureTexts errors found =
    case errors of
        [] ->
            found

        (Json.Decode.Field _ inner) :: rest ->
            failureTexts (inner :: rest) found

        (Json.Decode.Index _ inner) :: rest ->
            failureTexts (inner :: rest) found

        (Json.Decode.OneOf ways) :: rest ->
            failureTexts (ways ++ rest) found

        (Json.Decode.Failure text _) :: rest ->
            failureTexts rest (text :: found)



-- TESTS


binaryShape : Shape -> Test
binaryShape shape =
    test shape.name <|
        \_ ->
            Expect.all
                [ \_ -> shape.binary (binaryOf shape 100) |> Expect.equal (Ok ())
                , \_ -> shape.binary (binaryOf shape 101) |> Result.mapError .reason |> Expect.equal (Err Proto.Error.TooDeep)
                ]
                ()


jsonShape : Shape -> Test
jsonShape shape =
    test shape.name <|
        \_ ->
            Expect.all
                [ \_ -> shape.json (jsonOf shape 100) |> Expect.equal (Ok ())
                , \_ -> shape.json (jsonOf shape 101) |> failsTooDeep
                ]
                ()


binaryFailure : Test
binaryFailure =
    describe "the binary failure"
        [ test "names the field one level too deep and its length's offset" <|
            \_ ->
                let
                    chain =
                        { name = "", binary = \_ -> Ok (), json = \_ -> Ok (), prefix = \_ size -> 0x12 :: varint size, open = \_ -> "", close = \_ -> "" }

                    ( input, prefixes ) =
                        nested chain 101

                    offset =
                        List.sum (List.map List.length (List.take 99 prefixes)) + 1
                in
                Proto.Binary.decode Deep.decodeChainBytes input
                    |> Result.map (\_ -> ())
                    |> Expect.equal
                        (Err
                            { typeName = "cycles.v1.Chain"
                            , reason = Proto.Error.TooDeep
                            , path = List.repeat 100 ( "cycles.v1.Chain", 2 )
                            , offset = offset
                            }
                        )
        , test "counts each message of a cycle of two" <|
            \_ ->
                case List.filter (\shape -> shape.name == "two messages that hold each other") shapes of
                    people :: _ ->
                        case Proto.Binary.decode Deep.decodePersonBytes (binaryOf people 101) of
                            Err e ->
                                ( List.length e.path, List.take 2 e.path )
                                    |> Expect.equal ( 100, [ ( "cycles.v1.Person", 2 ), ( "cycles.v1.Team", 1 ) ] )

                            Ok _ ->
                                Expect.fail "read past the limit"

                    [] ->
                        Expect.fail "no shape"
        , test "a message off the cycle starts it at 1, in another package too" <|
            \_ ->
                let
                    tree depth =
                        "{\"tree\":" ++ jsonOf treeShape depth ++ "}"
                in
                Expect.all
                    [ \_ -> Json.Decode.decodeString Deep.decodeForest ("{\"trees\":[" ++ jsonOf treeShape 100 ++ "]}") |> ok |> Expect.equal (Ok ())
                    , \_ -> Json.Decode.decodeString Deep.decodeForest ("{\"trees\":[" ++ jsonOf treeShape 101 ++ "]}") |> ok |> failsTooDeep
                    , \_ -> Json.Decode.decodeString Outside.decodeHolder (tree 100) |> ok |> Expect.equal (Ok ())
                    , \_ -> Json.Decode.decodeString Outside.decodeHolder (tree 101) |> ok |> failsTooDeep
                    ]
                    ()
        ]


treeShape : Shape
treeShape =
    { name = "", binary = \_ -> Ok (), json = \_ -> Ok (), prefix = \_ size -> 0x12 :: varint size, open = \_ -> "{\"children\":[", close = \_ -> "]}" }


mergedInto : Test
mergedInto =
    test "reading into a value read before counts the input's levels" <|
        \_ ->
            case Proto.Binary.decode Deep.decodeChainBytes (binaryOf chainShape 100) of
                Ok existing ->
                    Expect.all
                        [ \_ -> Proto.Binary.decode (Deep.mergeChainBytes existing) (binaryOf chainShape 100) |> ok |> Expect.equal (Ok ())
                        , \_ -> Proto.Binary.decode (Deep.mergeChainBytes existing) (binaryOf chainShape 101) |> Result.mapError .reason |> ok |> Expect.equal (Err Proto.Error.TooDeep)
                        ]
                        ()

                Err _ ->
                    Expect.fail "100 levels did not read"


chainShape : Shape
chainShape =
    { name = "", binary = \_ -> Ok (), json = \_ -> Ok (), prefix = \_ size -> 0x12 :: varint size, open = \_ -> "{\"next\":", close = \_ -> "}" }


{-| Under `unknown_fields=keep`, a chain carrying an unknown field (number
99, a varint) at every level reads at 100 levels and writes back the same
bytes, and fails at 101, with the error the default options give, path and
offset included; a tree fails at 101 from binary and from JSON.
-}
keep : Test
keep =
    let
        withUnknown levels =
            let
                unknown =
                    [ 0x98, 0x06, 0x01 ]

                ( _, parts ) =
                    List.foldl
                        (\_ ( size, ( openAcc, closeAcc ) ) ->
                            let
                                p =
                                    0x12 :: varint size
                            in
                            ( size + List.length p + List.length unknown, ( p :: openAcc, unknown :: closeAcc ) )
                        )
                        ( List.length unknown, ( [], [] ) )
                        (List.range 1 (levels - 1))

                ( opens, closes ) =
                    parts
            in
            Bytes.Encode.encode
                (Bytes.Encode.sequence
                    (List.map Bytes.Encode.unsignedInt8 (List.concat opens ++ unknown ++ List.concat (List.reverse closes)))
                )
    in
    test "under unknown_fields=keep, with unknown fields at every level" <|
        \_ ->
            Expect.all
                [ \_ ->
                    Proto.Binary.decode Keep.decodeChainBytes (withUnknown 100)
                        |> Result.map (Proto.Binary.encode Keep.encodeChainBytes >> Proto.Bytes.toBase64)
                        |> Expect.equal (Ok (Proto.Bytes.toBase64 (withUnknown 100)))
                , \_ -> Proto.Binary.decode Keep.decodeChainBytes (withUnknown 101) |> Result.mapError .reason |> ok |> Expect.equal (Err Proto.Error.TooDeep)
                , \_ -> Proto.Binary.decode Keep.decodeChainBytes (binaryOf chainShape 101) |> ok |> Expect.equal (Proto.Binary.decode Deep.decodeChainBytes (binaryOf chainShape 101) |> ok)
                , \_ -> Proto.Binary.decode Keep.decodeTreeBytes (binaryOf treeShape 101) |> Result.mapError .reason |> ok |> Expect.equal (Err Proto.Error.TooDeep)
                , \_ -> Json.Decode.decodeString Keep.decodeTree (jsonOf treeShape 101) |> ok |> failsTooDeep
                ]
                ()


{-| 10,000 levels, far past any engine's stack, fail with the error and
throw nothing, through every way a program reads them.
-}
farPast : Test
farPast =
    let
        levels =
            10000

        text =
            jsonOf treeShape levels

        value =
            Json.Decode.decodeString Json.Decode.value text

        method =
            Proto.Method.init "cycles.v1.Trees" "Get" Deep.encodeTree (\_ -> Deep.decodeTree) Deep.encodeTreeBytes Deep.decodeTreeBytes

        answer =
            Http.GoodStatus_ { url = "https://api.example.com/cycles.v1.Trees/Get", statusCode = 200, statusText = "OK", headers = Dict.fromList [ ( "content-type", "application/json" ) ] } text
    in
    describe "10,000 levels"
        [ test "Proto.Binary.decode" <|
            \_ -> Proto.Binary.decode Deep.decodeTreeBytes (binaryOf treeShape levels) |> Result.mapError .reason |> ok |> Expect.equal (Err Proto.Error.TooDeep)
        , test "Json.Decode.decodeString" <|
            \_ -> Json.Decode.decodeString Deep.decodeTree text |> ok |> failsTooDeep
        , test "Json.Decode.decodeValue and Proto.Message.decodeJson" <|
            \_ ->
                case value of
                    Ok json ->
                        Expect.all
                            [ \_ -> Json.Decode.decodeValue Deep.decodeTree json |> ok |> failsTooDeep
                            , \_ ->
                                case Proto.Message.decodeJson Deep.registry Deep.messageTree json of
                                    Err (Proto.Error.BadJson error) ->
                                        failsTooDeep (Err error)

                                    _ ->
                                        Expect.fail "not BadJson"
                            ]
                            ()

                    Err _ ->
                        Expect.fail "JSON.parse refused 10,000 levels"
        , test "Rpc.response" <|
            \_ ->
                case Rpc.response (Rpc.client Rpc.Protocol.connect "https://api.example.com") (Rpc.call method Deep.defaultTree) answer of
                    Err error ->
                        case Rpc.Error.protoError error of
                            Just (Proto.Error.BadJson problem) ->
                                failsTooDeep (Err problem)

                            _ ->
                                Expect.fail "not a BadJson body"

                    Ok _ ->
                        Expect.fail "read past the limit"
        ]



-- ONE BUDGET


{-| The bytes of length-delimited layers, outermost first, around `core`:
each layer gives its prefix from the size of what it holds.
-}
wrapped : List (Int -> List Int) -> List Int -> Bytes.Bytes
wrapped layers core =
    let
        ( _, prefixes ) =
            List.foldl
                (\layer ( size, acc ) ->
                    let
                        p =
                            layer size
                    in
                    ( size + List.length p, p :: acc )
                )
                ( List.length core, [] )
                (List.reverse layers)
    in
    Bytes.Encode.encode (Bytes.Encode.sequence (List.map Bytes.Encode.unsignedInt8 (List.concat prefixes ++ core)))


{-| An `Envelope`'s reply, its `value`, `data` and `list` fields, a `Value`'s
list and a `ListValue`'s first element, a `Value`'s struct and a `Struct`'s
member `"a"`, and an `Envelope`'s `payload`, an `Any` holding an `Envelope`.
-}
reply : Int -> List Int
reply size =
    0x12 :: varint size


valueField : Int -> List Int
valueField size =
    0x22 :: varint size


dataField : Int -> List Int
dataField size =
    0x1A :: varint size


listInValue : Int -> List Int
listInValue size =
    0x32 :: varint size


valueInList : Int -> List Int
valueInList size =
    0x0A :: varint size


structInValue : Int -> List Int
structInValue size =
    0x2A :: varint size


memberA : Int -> List Int
memberA size =
    let
        entry =
            [ 0x0A, 1, 0x61, 0x12 ] ++ varint size
    in
    0x0A :: varint (List.length entry + size) ++ entry


envelopeUrl : List Int
envelopeUrl =
    List.map Char.toCode (String.toList "type.googleapis.com/cycles.v1.Envelope")


payload : Int -> List Int
payload size =
    let
        any =
            0x0A :: varint (List.length envelopeUrl) ++ envelopeUrl ++ (0x12 :: varint size)
    in
    0x0A :: varint (List.length any + size) ++ any


{-| `messages` envelopes, the innermost holding a `Value` of `arrays` nested
arrays, in binary and in JSON.
-}
valueArraysBinary : Int -> Int -> Bytes.Bytes
valueArraysBinary messages arrays =
    wrapped
        (List.repeat (messages - 1) reply
            ++ valueField
            :: List.concat (List.repeat (arrays - 1) [ listInValue, valueInList ])
        )
        [ 0x32, 0x00 ]


valueArraysJson : Int -> Int -> String
valueArraysJson messages arrays =
    String.repeat (messages - 1) "{\"replies\":["
        ++ "{\"value\":"
        ++ (if arrays == 0 then
                "1"

            else
                String.repeat arrays "[" ++ String.repeat arrays "]"
           )
        ++ "}"
        ++ String.repeat (messages - 1) "]}"


{-| `messages` envelopes, the innermost holding a `Struct` of `objects`
nested objects, each the member `"a"` of the one around it.
-}
structBinary : Int -> Int -> Bytes.Bytes
structBinary messages objects =
    wrapped
        (List.repeat (messages - 1) reply
            ++ dataField
            :: List.concat (List.repeat (objects - 1) [ memberA, structInValue ])
        )
        []


structJson : Int -> Int -> String
structJson messages objects =
    String.repeat (messages - 1) "{\"replies\":["
        ++ "{\"data\":"
        ++ String.repeat (objects - 1) "{\"a\":"
        ++ "{}"
        ++ String.repeat (objects - 1) "}"
        ++ "}"
        ++ String.repeat (messages - 1) "]}"


{-| Envelopes nested `levels` deep, each holding the next in an `Any` where
`anyAt` its depth says so and as a reply otherwise; the innermost holds a
`ListValue` of `arrays` nested arrays, or no field at 0.
-}
mixedJson : (Int -> Bool) -> Int -> Int -> String
mixedJson anyAt levels arrays =
    let
        depths =
            List.range 1 (levels - 1)

        open depth =
            if anyAt depth then
                "\"payload\":{\"@type\":\"type.googleapis.com/cycles.v1.Envelope\","

            else
                "\"replies\":[{"

        close depth =
            if anyAt depth then
                "}"

            else
                "}]"

        inner =
            if arrays == 0 then
                "\"replies\":[]"

            else
                "\"list\":" ++ String.repeat arrays "[" ++ String.repeat arrays "]"
    in
    "{"
        ++ String.concat (List.map open depths)
        ++ inner
        ++ String.concat (List.map close (List.reverse depths))
        ++ "}"


readEnvelope : String -> Result Json.Decode.Error ()
readEnvelope =
    Json.Decode.decodeString (Deep.decodeEnvelopeWith Deep.registry) >> ok


readEnvelopeBytes : Bytes.Bytes -> Result Proto.Error.Binary ()
readEnvelopeBytes =
    Proto.Binary.decode Deep.decodeEnvelopeBytes >> ok


tooDeepBinary : Result Proto.Error.Binary () -> Result Proto.Error.Reason ()
tooDeepBinary =
    Result.mapError .reason


oneBudget : Test
oneBudget =
    describe "one budget for messages, Any and Value"
        [ test "a Value's arrays count on from the message holding it, in JSON" <|
            \_ ->
                Expect.all
                    [ \_ -> readEnvelope (valueArraysJson 1 99) |> Expect.equal (Ok ())
                    , \_ -> readEnvelope (valueArraysJson 1 100) |> failsTooDeep
                    , \_ -> readEnvelope (valueArraysJson 50 50) |> Expect.equal (Ok ())
                    , \_ -> readEnvelope (valueArraysJson 50 51) |> failsTooDeep
                    , \_ -> readEnvelope (valueArraysJson 100 0) |> Expect.equal (Ok ())
                    , \_ -> readEnvelope (valueArraysJson 100 1) |> failsTooDeep
                    ]
                    ()
        , test "and in binary" <|
            \_ ->
                Expect.all
                    [ \_ -> readEnvelopeBytes (valueArraysBinary 1 99) |> Expect.equal (Ok ())
                    , \_ -> readEnvelopeBytes (valueArraysBinary 1 100) |> tooDeepBinary |> Expect.equal (Err Proto.Error.TooDeep)
                    , \_ -> readEnvelopeBytes (valueArraysBinary 50 50) |> Expect.equal (Ok ())
                    , \_ -> readEnvelopeBytes (valueArraysBinary 50 51) |> tooDeepBinary |> Expect.equal (Err Proto.Error.TooDeep)
                    ]
                    ()
        , test "a Struct's objects, in JSON and in binary" <|
            \_ ->
                Expect.all
                    [ \_ -> readEnvelope (structJson 60 40) |> Expect.equal (Ok ())
                    , \_ -> readEnvelope (structJson 60 41) |> failsTooDeep
                    , \_ -> readEnvelopeBytes (structBinary 60 40) |> Expect.equal (Ok ())
                    , \_ -> readEnvelopeBytes (structBinary 60 41) |> tooDeepBinary |> Expect.equal (Err Proto.Error.TooDeep)
                    ]
                    ()
        , test "an Any is a level, and the message it holds counts on from it" <|
            \_ ->
                let
                    allAny =
                        \_ -> True

                    everyThird =
                        \depth -> modBy 3 depth == 0
                in
                Expect.all
                    [ \_ -> readEnvelope (mixedJson allAny 100 0) |> Expect.equal (Ok ())
                    , \_ -> readEnvelope (mixedJson allAny 101 0) |> failsTooDeep
                    , \_ -> readEnvelope (mixedJson everyThird 70 30) |> Expect.equal (Ok ())
                    , \_ -> readEnvelope (mixedJson everyThird 70 31) |> failsTooDeep
                    ]
                    ()
        , test "what is read at the limit writes in both codecs and reads back" <|
            \_ ->
                case Json.Decode.decodeString (Deep.decodeEnvelopeWith Deep.registry) (mixedJson (\depth -> modBy 2 depth == 0) 60 40) of
                    Ok envelope ->
                        Expect.all
                            [ \_ ->
                                Proto.Json.encodeWith Deep.registry (Deep.encodeEnvelope envelope)
                                    |> Result.toMaybe
                                    |> Maybe.andThen (Json.Decode.decodeValue (Deep.decodeEnvelopeWith Deep.registry) >> Result.toMaybe)
                                    |> Expect.equal (Just envelope)
                            , \_ ->
                                Proto.Binary.decode Deep.decodeEnvelopeBytes (Proto.Binary.encode Deep.encodeEnvelopeBytes envelope)
                                    |> Expect.equal (Ok envelope)
                            ]
                            ()

                    Err _ ->
                        Expect.fail "did not read at the limit"
        , test "an Any converted to JSON counts the Any it holds" <|
            \_ ->
                let
                    packed depth =
                        List.foldl (\_ inner -> Proto.Any.pack Proto.WellKnown.any inner)
                            (Proto.Any.pack Proto.WellKnown.empty ())
                            (List.range 2 depth)
                in
                Expect.all
                    [ \_ -> Proto.Any.toJson Proto.WellKnown.registry (packed 100) |> ok |> Expect.equal (Ok ())
                    , \_ ->
                        Proto.Any.toJson Proto.WellKnown.registry (packed 101)
                            |> ok
                            |> Expect.equal (Err (Proto.Error.BadBinary { typeName = "google.protobuf.Any", reason = Proto.Error.TooDeep, path = [], offset = 0 }))
                    ]
                    ()
        ]


{-| 10,000 levels and more of the three kinds mixed fail with the error and
throw nothing, through every way a program reads them.
-}
mixedFarPast : Test
mixedFarPast =
    let
        jsonInputs =
            [ ( "messages then a Value", valueArraysJson 5000 5000 )
            , ( "a Struct", structJson 1 10000 )
            , ( "Any in Any", mixedJson (\_ -> True) 10000 0 )
            , ( "Any, messages and a ListValue", mixedJson (\depth -> modBy 3 depth == 0) 6000 6000 )
            ]

        binaryInputs =
            [ ( "messages then a Value", valueArraysBinary 5000 5000 )
            , ( "a Struct", structBinary 1 10000 )
            ]

        method =
            Proto.Method.init "cycles.v1.Envelopes" "Get" Deep.encodeEnvelope Deep.decodeEnvelopeWith Deep.encodeEnvelopeBytes Deep.decodeEnvelopeBytes

        answer contentType body =
            { url = "https://api.example.com/cycles.v1.Envelopes/Get", statusCode = 200, statusText = "OK", headers = Dict.fromList [ ( "content-type", contentType ) ] }
                |> (\metadata -> ( metadata, body ))
    in
    describe "10,000 levels of the three kinds"
        [ describe "JSON"
            (List.map
                (\( name, text ) ->
                    test name <|
                        \_ ->
                            case Json.Decode.decodeString Json.Decode.value text of
                                Ok json ->
                                    Expect.all
                                        [ \_ -> readEnvelope text |> failsTooDeep
                                        , \_ -> Json.Decode.decodeValue (Deep.decodeEnvelopeWith Deep.registry) json |> ok |> failsTooDeep
                                        , \_ ->
                                            case Proto.Message.decodeJson Deep.registry Deep.messageEnvelope json of
                                                Err (Proto.Error.BadJson error) ->
                                                    failsTooDeep (Err error)

                                                _ ->
                                                    Expect.fail "not BadJson"
                                        , \_ ->
                                            let
                                                ( metadata, body ) =
                                                    answer "application/json" text
                                            in
                                            case Rpc.response (Rpc.client Rpc.Protocol.connect "https://api.example.com" |> Rpc.Client.withRegistry Deep.registry) (Rpc.call method Deep.defaultEnvelope) (Http.GoodStatus_ metadata body) of
                                                Err error ->
                                                    case Rpc.Error.protoError error of
                                                        Just (Proto.Error.BadJson problem) ->
                                                            failsTooDeep (Err problem)

                                                        _ ->
                                                            Expect.fail "not a BadJson body"

                                                Ok _ ->
                                                    Expect.fail "read past the limit"
                                        ]
                                        ()

                                Err _ ->
                                    Expect.fail "JSON.parse refused it"
                )
                jsonInputs
            )
        , describe "binary"
            (List.map
                (\( name, bytes ) ->
                    test name <|
                        \_ ->
                            Expect.all
                                [ \_ -> readEnvelopeBytes bytes |> tooDeepBinary |> Expect.equal (Err Proto.Error.TooDeep)
                                , \_ ->
                                    let
                                        ( metadata, _ ) =
                                            answer "application/proto" ""
                                    in
                                    case Rpc.responseBytes (Rpc.client Rpc.Protocol.connectProto "https://api.example.com") (Rpc.call method Deep.defaultEnvelope) (Http.GoodStatus_ metadata bytes) of
                                        Err error ->
                                            case Rpc.Error.protoError error of
                                                Just (Proto.Error.BadBinary problem) ->
                                                    problem.reason |> Expect.equal Proto.Error.TooDeep

                                                _ ->
                                                    Expect.fail "not a BadBinary body"

                                        Ok _ ->
                                            Expect.fail "read past the limit"
                                ]
                                ()
                )
                binaryInputs
            )
        , test "Anys each holding a deep message, read from binary, convert to JSON with the error" <|
            \_ ->
                case readEnvelopeBytesValue (wrapped (List.concat (List.repeat 60 (payload :: List.repeat 90 reply))) []) of
                    Ok envelope ->
                        case Proto.Json.encodeWith Deep.registry (Deep.encodeEnvelope envelope) of
                            Err (Proto.Error.BadBinary problem) ->
                                problem.reason |> Expect.equal Proto.Error.TooDeep

                            Err (Proto.Error.NotWritable problem) ->
                                problem.reason |> Expect.equal Proto.Error.NestedTooDeep

                            _ ->
                                Expect.fail "converted past the limit"

                    Err _ ->
                        Expect.fail "did not read"
        , test "an Any chain read from binary converts to JSON with the error" <|
            \_ ->
                case readEnvelopeBytesValue (wrapped (List.repeat 10000 payload) []) of
                    Ok envelope ->
                        case Proto.Json.encodeWith Deep.registry (Deep.encodeEnvelope envelope) of
                            Err (Proto.Error.BadBinary problem) ->
                                problem.reason |> Expect.equal Proto.Error.TooDeep

                            Err (Proto.Error.NotWritable problem) ->
                                problem.reason |> Expect.equal Proto.Error.NestedTooDeep

                            _ ->
                                Expect.fail "converted past the limit"

                    Err _ ->
                        Expect.fail "an Any's binary is read unconverted"
        ]


readEnvelopeBytesValue : Bytes.Bytes -> Result Proto.Error.Binary Deep.Envelope
readEnvelopeBytesValue =
    Proto.Binary.decode Deep.decodeEnvelopeBytes


{-| An error we return holds no JSON nested past 50 levels, so it prints
short however deep the input: `Json.Decode.errorToString` of the `BadJson`
itself, not only `Proto.Error.toString`, which scrubs before printing.
-}
scrubbed : Test
scrubbed =
    let
        deep =
            String.repeat 100000 "[" ++ String.repeat 100000 "]"

        printsShort limit result =
            case result of
                Err (Proto.Error.BadJson error) ->
                    Expect.all
                        [ \_ -> Json.Decode.errorToString error |> String.length |> Expect.lessThan limit
                        , \_ -> Proto.Error.toString (Proto.Error.BadJson error) |> String.length |> Expect.lessThan limit
                        ]
                        ()

                _ ->
                    Expect.fail "not BadJson"

        parsed text =
            Json.Decode.decodeString Json.Decode.value text |> Result.withDefault Json.Encode.null
    in
    describe "the error a read returns"
        [ test "when it failed past the limit" <|
            \_ ->
                Proto.Message.decodeJson Deep.registry Deep.messageEnvelope (parsed (valueArraysJson 1 100000))
                    |> printsShort 1200
        , test "when a field was given a deep value of the wrong type" <|
            \_ ->
                Proto.Message.decodeJson Deep.registry Deep.messageChain (parsed ("{\"label\":" ++ deep ++ "}"))
                    |> printsShort 300
        , test "when an Any's message was given one" <|
            \_ ->
                Proto.Message.decodeJson Deep.registry Deep.messageEnvelope (parsed ("{\"payload\":{\"@type\":\"type.googleapis.com/cycles.v1.Chain\",\"label\":" ++ deep ++ "}}"))
                    |> printsShort 400
        , test "an error detail's" <|
            \_ ->
                let
                    body =
                        "{\"code\":\"internal\",\"message\":\"x\",\"details\":[{\"type\":" ++ deep ++ "}]}"

                    method =
                        Proto.Method.init "cycles.v1.Trees" "Get" Deep.encodeTree (\_ -> Deep.decodeTree) Deep.encodeTreeBytes Deep.decodeTreeBytes

                    answer =
                        Http.BadStatus_ { url = "https://api.example.com/cycles.v1.Trees/Get", statusCode = 500, statusText = "Internal Server Error", headers = Dict.fromList [ ( "content-type", "application/json" ) ] } body
                in
                case Rpc.response (Rpc.client Rpc.Protocol.connect "https://api.example.com") (Rpc.call method Deep.defaultTree) answer of
                    Err error ->
                        case Rpc.Error.details error of
                            [ detail ] ->
                                printsShort 300 detail

                            _ ->
                                Expect.fail "not one detail"

                    Ok _ ->
                        Expect.fail "an error read as an answer"
        ]
