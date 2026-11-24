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
import Generated.Codec.Default.Codec.V1 as Codec
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
import Proto.Internal.Depth
import Proto.Json
import Proto.Message
import Proto.Method
import Proto.Registry
import Proto.Value
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
        , mapValues
        , anyOwnCount
        , offCycle
        , everyNestingMessage
        , mixedFarPast
        , scrubbed
        , valueRefusals
        , valueErrorsShort
        , theFailureStatesTheLimit
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


{-| The runtime writes the limit's failure text once, beside the limit; it
states the limit.
-}
theFailureStatesTheLimit : Test
theFailureStatesTheLimit =
    test "the failure past the limit states the limit" <|
        \_ ->
            Proto.Internal.Depth.tooDeepText
                |> Expect.equal ("Expecting messages nested at most " ++ String.fromInt Proto.Internal.Depth.limit ++ " deep")


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
        , test "a message on no cycle above one is the first level, in another package too" <|
            \_ ->
                let
                    tree depth =
                        "{\"tree\":" ++ jsonOf treeShape depth ++ "}"
                in
                Expect.all
                    [ \_ -> Json.Decode.decodeString Deep.decodeForest ("{\"trees\":[" ++ jsonOf treeShape 99 ++ "]}") |> ok |> Expect.equal (Ok ())
                    , \_ -> Json.Decode.decodeString Deep.decodeForest ("{\"trees\":[" ++ jsonOf treeShape 100 ++ "]}") |> ok |> failsTooDeep
                    , \_ -> Json.Decode.decodeString Outside.decodeHolder (tree 99) |> ok |> Expect.equal (Ok ())
                    , \_ -> Json.Decode.decodeString Outside.decodeHolder (tree 100) |> ok |> failsTooDeep
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
            Proto.Method.init "cycles.v1.Trees" "Get" (\_ -> Ok << Deep.encodeTree) (\_ -> Deep.decodeTree) Deep.encodeTreeBytes Deep.decodeTreeBytes

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
memberA =
    mapEntry 0x0A


{-| The entry of key `"a"` in the map field whose tag byte is `tag`.
-}
mapEntry : Int -> Int -> List Int
mapEntry tag size =
    let
        entry =
            [ 0x0A, 1, 0x61, 0x12 ] ++ varint size
    in
    tag :: varint (List.length entry + size) ++ entry


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


{-| Holds an `Any` only at depth `depth`, as `mixedJson`'s `anyAt`: with
`depth + 1` levels, the innermost message is held in an `Any` by the one
around it.
-}
lastAt : Int -> Int -> Bool
lastAt depth =
    \at -> at == depth


{-| Envelopes read from binary, which holds each `Any`'s bytes unread, and
written as JSON, which converts them through the registry.
-}
writtenFromBinary : Bytes.Bytes -> Result Proto.Error.Error ()
writtenFromBinary bytes =
    case readEnvelopeBytesValue bytes of
        Ok envelope ->
            Deep.encodeEnvelopeWith Deep.registry envelope |> ok

        Err _ ->
            Err (Proto.Error.BadJson (Json.Decode.Failure "did not read" Json.Encode.null))


{-| The error of a write converting an `Any` past the limit.
-}
anyTooDeep : Proto.Error.Error
anyTooDeep =
    Proto.Error.BadBinary { typeName = "google.protobuf.Any", reason = Proto.Error.TooDeep, path = [], offset = 0 }


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
                    , \_ -> readEnvelope (mixedJson (lastAt 99) 100 0) |> Expect.equal (Ok ())
                    , \_ -> readEnvelope (mixedJson (lastAt 100) 101 0) |> failsTooDeep
                    ]
                    ()
        , test "an Any read from binary and written as JSON counts where a JSON read does" <|
            \_ ->
                Expect.all
                    [ \_ -> writtenFromBinary (wrapped (List.repeat 99 payload) []) |> Expect.equal (Ok ())
                    , \_ -> writtenFromBinary (wrapped (List.repeat 100 payload) []) |> Expect.equal (Err anyTooDeep)
                    , \_ -> writtenFromBinary (wrapped (List.repeat 98 reply ++ [ payload ]) []) |> Expect.equal (Ok ())
                    , \_ -> writtenFromBinary (wrapped (List.repeat 99 reply ++ [ payload ]) []) |> Expect.equal (Err anyTooDeep)
                    , \_ -> writtenFromBinary (wrapped (payload :: List.repeat 97 reply ++ [ payload ]) []) |> Expect.equal (Ok ())
                    , \_ -> writtenFromBinary (wrapped (payload :: List.repeat 98 reply ++ [ payload ]) []) |> Expect.equal (Err anyTooDeep)
                    ]
                    ()
        , describe "what is read at the limit writes in both codecs and reads back"
            (List.map
                (\( name, json ) ->
                    test name <|
                        \_ ->
                            case Json.Decode.decodeString (Deep.decodeEnvelopeWith Deep.registry) json of
                                Ok envelope ->
                                    Expect.all
                                        [ \_ ->
                                            Deep.encodeEnvelopeWith Deep.registry envelope
                                                |> Result.toMaybe
                                                |> Maybe.andThen (Json.Decode.decodeValue (Deep.decodeEnvelopeWith Deep.registry) >> Result.toMaybe)
                                                |> Expect.equal (Just envelope)
                                        , \_ ->
                                            Proto.Binary.decode Deep.decodeEnvelopeBytes (Proto.Binary.encode Deep.encodeEnvelopeBytes envelope)
                                                |> Expect.equal (Ok envelope)
                                        , \_ ->
                                            Proto.Binary.decode Deep.decodeEnvelopeBytes (Proto.Binary.encode Deep.encodeEnvelopeBytes envelope)
                                                |> Result.toMaybe
                                                |> Maybe.andThen (Deep.encodeEnvelopeWith Deep.registry >> Result.toMaybe)
                                                |> Maybe.andThen (Json.Decode.decodeValue (Deep.decodeEnvelopeWith Deep.registry) >> Result.toMaybe)
                                                |> Expect.equal (Just envelope)
                                        ]
                                        ()

                                Err _ ->
                                    Expect.fail "did not read at the limit"
                )
                [ ( "Anys, messages and a ListValue", mixedJson (\depth -> modBy 2 depth == 0) 60 40 )
                , ( "100 Anys", mixedJson (\_ -> True) 100 0 )
                , ( "an Any held at 99, its message at 100", mixedJson (lastAt 99) 100 0 )
                , ( "an Any, then 98 messages and an Any", mixedJson (\depth -> depth == 1 || depth == 99) 100 0 )
                ]
            )
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



-- MAP VALUES


{-| `messages` envelopes, the innermost holding under key `"a"` of `field`
the JSON `inner`.
-}
inMapJson : String -> Int -> String -> String
inMapJson field messages inner =
    String.repeat (messages - 1) "{\"replies\":["
        ++ ("{\"" ++ field ++ "\":{\"a\":" ++ inner ++ "}}")
        ++ String.repeat (messages - 1) "]}"


{-| `messages` envelopes, the innermost holding a map entry of key `"a"`
in the field whose tag byte is `tag`, its value `levels` deep: each level
past the first wraps the one inside in the two layers `step` gives, and
`core` is the innermost level's own bytes.
-}
inMapBinary : Int -> List (Int -> List Int) -> List Int -> Int -> Int -> Bytes.Bytes
inMapBinary tag step core messages levels =
    wrapped
        (List.repeat (messages - 1) reply
            ++ mapEntry tag
            :: List.concat (List.repeat (levels - 1) step)
        )
        core


mapValues : Test
mapValues =
    let
        values =
            inMapBinary 0x32 [ listInValue, valueInList ] [ 0x32, 0x00 ]

        structs =
            inMapBinary 0x3A [ memberA, structInValue ] []

        lists =
            inMapBinary 0x42 [ valueInList, listInValue ] []

        refused =
            tooDeepBinary >> Expect.equal (Err Proto.Error.TooDeep)
    in
    describe "a map's Value, Struct and ListValue values count on from the message holding them"
        [ test "in JSON" <|
            \_ ->
                Expect.all
                    [ \_ -> readEnvelope (inMapJson "values" 1 (nestedArrays 99)) |> Expect.equal (Ok ())
                    , \_ -> readEnvelope (inMapJson "values" 1 (nestedArrays 100)) |> failsTooDeep
                    , \_ -> readEnvelope (inMapJson "values" 60 (nestedArrays 40)) |> Expect.equal (Ok ())
                    , \_ -> readEnvelope (inMapJson "values" 60 (nestedArrays 41)) |> failsTooDeep
                    , \_ -> readEnvelope (inMapJson "values" 100 "1") |> Expect.equal (Ok ())
                    , \_ -> readEnvelope (inMapJson "values" 100 "[]") |> failsTooDeep
                    , \_ -> readEnvelope (inMapJson "structs" 60 (nestedObjects 40)) |> Expect.equal (Ok ())
                    , \_ -> readEnvelope (inMapJson "structs" 60 (nestedObjects 41)) |> failsTooDeep
                    , \_ -> readEnvelope (inMapJson "lists" 60 (nestedArrays 40)) |> Expect.equal (Ok ())
                    , \_ -> readEnvelope (inMapJson "lists" 60 (nestedArrays 41)) |> failsTooDeep
                    ]
                    ()
        , test "in binary" <|
            \_ ->
                Expect.all
                    [ \_ -> readEnvelopeBytes (values 1 99) |> Expect.equal (Ok ())
                    , \_ -> readEnvelopeBytes (values 1 100) |> refused
                    , \_ -> readEnvelopeBytes (values 60 40) |> Expect.equal (Ok ())
                    , \_ -> readEnvelopeBytes (values 60 41) |> refused
                    , \_ -> readEnvelopeBytes (structs 60 40) |> Expect.equal (Ok ())
                    , \_ -> readEnvelopeBytes (structs 60 41) |> refused
                    , \_ -> readEnvelopeBytes (lists 60 40) |> Expect.equal (Ok ())
                    , \_ -> readEnvelopeBytes (lists 60 41) |> refused
                    ]
                    ()
        ]



-- AN ANY OFF THE CYCLE


{-| Envelopes in segments of the given lengths, each segment past the first
the message of an `Any` held by a `Sealed` the last envelope of the segment
before holds, under `field`: `"sealed"`, a field, or `"note"`, a oneof's
member. The innermost envelope holds one more such `Any`, of an empty
envelope. The last `Any` is at the total of the lengths, plus 1 for each
`Sealed`, a level of its own, plus 1, since the message an `Any` holds
counts at the `Any`'s level.
-}
offCycleJson : String -> List Int -> String
offCycleJson field lengths =
    let
        segment length =
            String.repeat (length - 1) "\"replies\":[{"

        any =
            "\"" ++ field ++ "\":{\"payload\":{\"@type\":\"type.googleapis.com/cycles.v1.Envelope\""

        closeSegment length =
            String.repeat (length - 1) "}]"
    in
    "{"
        ++ String.concat (List.map (\length -> segment length ++ any ++ ",") lengths)
        ++ "\"replies\":[]"
        ++ String.concat (List.map (\length -> "}}" ++ closeSegment length) (List.reverse lengths))
        ++ "}"


{-| The same in binary, the `Sealed` in the field whose tag byte is `tag`.
-}
offCycleBinary : Int -> List Int -> Bytes.Bytes
offCycleBinary tag lengths =
    wrapped
        (List.concatMap (\length -> List.repeat (length - 1) reply ++ [ \size -> tag :: varint size, payload ]) lengths)
        []


offCycle : Test
offCycle =
    let
        ways =
            [ ( "a field", "sealed", 0x4A ), ( "a oneof's member", "note", 0x52 ) ]

        method =
            Proto.Method.init "cycles.v1.Envelopes" "Get" Deep.encodeEnvelopeWith Deep.decodeEnvelopeWith Deep.encodeEnvelopeBytes Deep.decodeEnvelopeBytes

        answer text =
            Http.GoodStatus_ { url = "https://api.example.com/cycles.v1.Envelopes/Get", statusCode = 200, statusText = "OK", headers = Dict.fromList [ ( "content-type", "application/json" ) ] } text

        boundaries ( name, field, tag ) =
            test name <|
                \_ ->
                    Expect.all
                        (List.concatMap
                            (\( accepted, refused ) ->
                                [ \_ -> readEnvelope (offCycleJson field accepted) |> Expect.equal (Ok ())
                                , \_ -> readEnvelope (offCycleJson field refused) |> failsTooDeep
                                , \_ -> writtenFromBinary (offCycleBinary tag accepted) |> Expect.equal (Ok ())
                                , \_ -> writtenFromBinary (offCycleBinary tag refused) |> Expect.equal (Err anyTooDeep)
                                ]
                            )
                            [ ( [ 98 ], [ 99 ] )
                            , ( [ 1, 96 ], [ 1, 97 ] )
                            , ( [ 50, 47 ], [ 50, 48 ] )
                            , ( List.repeat 33 2, List.repeat 32 2 ++ [ 3 ] )
                            ]
                        )
                        ()

        deep ( name, field, tag ) =
            let
                text =
                    offCycleJson field (List.repeat 2000 50)
            in
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
                                    case Rpc.response (Rpc.client Rpc.Protocol.connect "https://api.example.com" |> Rpc.Client.withRegistry Deep.registry) (Rpc.call method Deep.defaultEnvelope) (answer text) of
                                        Err error ->
                                            case Rpc.Error.protoError error of
                                                Just (Proto.Error.BadJson problem) ->
                                                    failsTooDeep (Err problem)

                                                _ ->
                                                    Expect.fail "not a BadJson body"

                                        Ok _ ->
                                            Expect.fail "read past the limit"
                                , \_ -> writtenFromBinary (offCycleBinary tag (List.repeat 2000 50)) |> Expect.equal (Err anyTooDeep)
                                ]
                                ()

                        Err _ ->
                            Expect.fail "JSON.parse refused it"
    in
    describe "a message off the cycle holding an Any is a level, and the Any counts on from it"
        [ describe "read from JSON, and read from binary and written as JSON, refuse it at the same place"
            (List.map boundaries ways)
        , describe "100,000 levels fail with the error and throw nothing"
            (List.map deep ways)
        ]



-- ANOTHER CYCLE, AND MESSAGES ON NO CYCLE THAT NEST


{-| One message entered along a path: its JSON around what it holds, and its
binary prefix given the size of what it holds.
-}
type alias Step =
    { open : String, close : String, prefix : Int -> List Int }


pathJson : List Step -> String
pathJson steps =
    "{" ++ String.concat (List.map .open steps) ++ String.concat (List.reverse (List.map .close steps)) ++ "}"


pathBinary : List Step -> Bytes.Bytes
pathBinary steps =
    wrapped (List.map .prefix steps) []


{-| `Chain`'s `next` and `tree`, `Tree`'s `children`, `Dir`'s entry `"a"` and
`forest`, and `Forest`'s `chain` and `trees`.
-}
chainNext : Step
chainNext =
    Step "\"next\":{" "}" (\size -> 0x12 :: varint size)


chainTree : Step
chainTree =
    Step "\"tree\":{" "}" (\size -> 0x1A :: varint size)


treeChild : Step
treeChild =
    Step "\"children\":[{" "}]" (\size -> 0x12 :: varint size)


dirEntry : Step
dirEntry =
    Step "\"entries\":{\"a\":{" "}}" (mapEntry 0x0A)


dirForest : Step
dirForest =
    Step "\"forest\":{" "}" (\size -> 0x12 :: varint size)


forestChain : Step
forestChain =
    Step "\"chain\":{" "}" (\size -> 0x12 :: varint size)


forestTree : Step
forestTree =
    Step "\"trees\":[{" "}]" (\size -> 0x0A :: varint size)


{-| `Library`'s `doc`, `Doc`'s `root`, `Card`'s `meta`, `Meta`'s `data` (a
`Struct`), and one object of a `Struct` inside another: the member `"a"` and
the `Value` holding the inner object.
-}
libraryDoc : Step
libraryDoc =
    Step "\"doc\":{" "}" (\size -> 0x0A :: varint size)


docRoot : Step
docRoot =
    Step "\"root\":{" "}" (\size -> 0x0A :: varint size)


cardMeta : Step
cardMeta =
    Step "\"meta\":{" "}" (\size -> 0x0A :: varint size)


metaData : Step
metaData =
    Step "\"data\":{" "}" (\size -> 0x0A :: varint size)


structObject : Step
structObject =
    Step "\"a\":{"
        "}"
        (\size ->
            let
                inner =
                    structInValue size
            in
            memberA (List.length inner + size) ++ inner
        )


{-| `count` messages of one type, each holding the next through `step`: the
steps below the first.
-}
run : Int -> Step -> List Step
run count step =
    List.repeat (count - 1) step


{-| From a `Chain`: `chains` chains, the last holding a run of `trees` trees,
another cycle. `chains + trees` levels.
-}
chainThenTrees : Int -> Int -> List Step
chainThenTrees chains trees =
    run chains chainNext ++ chainTree :: run trees treeChild


{-| From a `Dir`: `dirs` dirs, the last holding a `Forest`, on no cycle, which
holds `chains` chains, the last holding `trees` trees: three cycles and a
message on none between them, `dirs + 1 + chains + trees` levels.
-}
threeCycles : Int -> Int -> Int -> List Step
threeCycles dirs chains trees =
    run dirs dirEntry ++ dirForest :: forestChain :: chainThenTrees chains trees


{-| From a `Dir`: `dirs` dirs, then the `Forest`, holding `trees` trees in its
list: `dirs + 1 + trees` levels.
-}
forestTrees : Int -> Int -> List Step
forestTrees dirs trees =
    run dirs dirEntry ++ dirForest :: forestTree :: run trees treeChild


everyNestingMessage : Test
everyNestingMessage =
    let
        boundaries name jsonRead binaryRead path pairs =
            test name <|
                \_ ->
                    Expect.all
                        (List.concatMap
                            (\( accepted, refused ) ->
                                [ \_ -> Json.Decode.decodeString jsonRead (pathJson (path accepted)) |> ok |> Expect.equal (Ok ())
                                , \_ -> Json.Decode.decodeString jsonRead (pathJson (path refused)) |> ok |> failsTooDeep
                                , \_ -> Proto.Binary.decode binaryRead (pathBinary (path accepted)) |> ok |> Expect.equal (Ok ())
                                , \_ -> Proto.Binary.decode binaryRead (pathBinary (path refused)) |> ok |> tooDeepBinary |> Expect.equal (Err Proto.Error.TooDeep)
                                ]
                            )
                            pairs
                        )
                        ()

        far name jsonRead binaryRead steps =
            let
                text =
                    pathJson steps
            in
            test name <|
                \_ ->
                    case Json.Decode.decodeString Json.Decode.value text of
                        Ok json ->
                            Expect.all
                                [ \_ -> Json.Decode.decodeString jsonRead text |> ok |> failsTooDeep
                                , \_ -> Json.Decode.decodeValue jsonRead json |> ok |> failsTooDeep
                                , \_ -> Proto.Binary.decode binaryRead (pathBinary steps) |> ok |> tooDeepBinary |> Expect.equal (Err Proto.Error.TooDeep)
                                ]
                                ()

                        Err _ ->
                            Expect.fail "JSON.parse refused it"
    in
    describe "every message that nests counts, from the outermost"
        [ boundaries "a message of another cycle, held directly"
            Deep.decodeChain
            Deep.decodeChainBytes
            (\( chains, trees ) -> chainThenTrees chains trees)
            [ ( ( 99, 1 ), ( 99, 2 ) ), ( ( 1, 99 ), ( 1, 100 ) ), ( ( 50, 50 ), ( 50, 51 ) ) ]
        , boundaries "a message on no cycle, held in a field, holding another cycle in a list"
            Deep.decodeDir
            Deep.decodeDirBytes
            (\( dirs, trees ) -> forestTrees dirs trees)
            [ ( ( 98, 1 ), ( 99, 1 ) ), ( ( 1, 98 ), ( 1, 99 ) ), ( ( 50, 49 ), ( 50, 50 ) ) ]
        , boundaries "three cycles, a message on none between the first two"
            Deep.decodeDir
            Deep.decodeDirBytes
            (\( dirs, ( chains, trees ) ) -> threeCycles dirs chains trees)
            [ ( ( 33, ( 33, 33 ) ), ( 33, ( 33, 34 ) ) ), ( ( 1, ( 1, 97 ) ), ( 1, ( 1, 98 ) ) ), ( ( 97, ( 1, 1 ) ), ( 98, ( 1, 1 ) ) ) ]
        , boundaries "the same message on no cycle read at the top is the first level"
            Deep.decodeForest
            Deep.decodeForestBytes
            (\( chains, trees ) -> forestChain :: chainThenTrees chains trees)
            [ ( ( 98, 1 ), ( 98, 2 ) ), ( ( 1, 98 ), ( 1, 99 ) ) ]
        , boundaries "a message on no cycle above one"
            Deep.decodeDoc
            Deep.decodeDocBytes
            (\chains -> docRoot :: run chains chainNext)
            [ ( 99, 100 ) ]
        , boundaries "two messages on no cycle above one"
            Deep.decodeLibrary
            Deep.decodeLibraryBytes
            (\chains -> libraryDoc :: docRoot :: run chains chainNext)
            [ ( 98, 99 ) ]
        , boundaries "a message on no cycle above one holding a Struct"
            Deep.decodeCard
            Deep.decodeCardBytes
            (\objects -> cardMeta :: metaData :: run objects structObject)
            [ ( 98, 99 ) ]
        , describe "100,000 levels fail with the error and throw nothing"
            [ far "another cycle" Deep.decodeChain Deep.decodeChainBytes (chainThenTrees 50000 50000)
            , far "three cycles and a message on none" Deep.decodeDir Deep.decodeDirBytes (threeCycles 30000 30000 40000)
            , far "two messages on no cycle above one" Deep.decodeLibrary Deep.decodeLibraryBytes (libraryDoc :: docRoot :: run 100000 chainNext)
            , far "a Struct below two messages on no cycle" Deep.decodeCard Deep.decodeCardBytes (cardMeta :: metaData :: run 100000 structObject)
            ]
        , letter
        ]


{-| From a `Letter`: its `Sealed`, whose `Any` holds `envelopes` envelopes,
each the next's reply, the innermost holding an empty envelope in an `Any`.
The `Letter`, the `Sealed` and each `Any` are a level each, the envelope in
an `Any` sharing its level: `3 + envelopes` levels.
-}
letterJson : Int -> String
letterJson envelopes =
    let
        any =
            "\"payload\":{\"@type\":\"type.googleapis.com/cycles.v1.Envelope\""
    in
    "{\"sealed\":{"
        ++ any
        ++ ","
        ++ String.repeat (envelopes - 1) "\"replies\":[{"
        ++ any
        ++ "}"
        ++ String.repeat (envelopes - 1) "}]"
        ++ "}}}"


letterBinary : Int -> Bytes.Bytes
letterBinary envelopes =
    wrapped ((\size -> 0x0A :: varint size) :: payload :: List.repeat (envelopes - 1) reply ++ [ payload ]) []


letter : Test
letter =
    let
        read =
            Json.Decode.decodeString (Deep.decodeLetterWith Deep.registry) >> ok

        written bytes =
            case Proto.Binary.decode Deep.decodeLetterBytes bytes of
                Ok value ->
                    Deep.encodeLetterWith Deep.registry value |> ok

                Err _ ->
                    Err (Proto.Error.BadJson (Json.Decode.Failure "did not read" Json.Encode.null))
    in
    describe "two messages on no cycle above an Any are a level each"
        [ test "read from JSON, and read from binary and written as JSON, refuse it at the same place" <|
            \_ ->
                Expect.all
                    [ \_ -> read (letterJson 97) |> Expect.equal (Ok ())
                    , \_ -> read (letterJson 98) |> failsTooDeep
                    , \_ -> written (letterBinary 97) |> Expect.equal (Ok ())
                    , \_ -> written (letterBinary 98) |> Expect.equal (Err anyTooDeep)
                    ]
                    ()
        ]



-- AN ANY OF A TYPE WITHOUT THE REGISTRY


{-| An `Any` holding a type whose codecs take no registry: a recursive
message that reaches no `Any` (`Chain`), and the well-known `Value`, `Struct`
and `ListValue`, registered through `Proto.WellKnown`. The type is read with
its own codecs, whose count starts at 1, so the levels inside the `Any` are
limited apart from those around it: 100 levels outside, the `Any` among
them, and 100 inside.
-}
anyOwnCount : Test
anyOwnCount =
    let
        types =
            Proto.Registry.union Deep.registry Proto.WellKnown.registry

        url name =
            "\"@type\":\"type.googleapis.com/" ++ name ++ "\""

        -- The `Any`'s JSON holding `levels` levels of each type.
        kinds =
            [ ( "a Chain", \levels -> "{" ++ url "cycles.v1.Chain" ++ String.repeat (levels - 1) ",\"next\":{\"label\":\"\"" ++ String.repeat levels "}" )
            , ( "a Value", \levels -> "{" ++ url "google.protobuf.Value" ++ ",\"value\":" ++ nestedArrays levels ++ "}" )
            , ( "a Struct", \levels -> "{" ++ url "google.protobuf.Struct" ++ ",\"value\":" ++ nestedObjects levels ++ "}" )
            , ( "a ListValue", \levels -> "{" ++ url "google.protobuf.ListValue" ++ ",\"value\":" ++ nestedArrays levels ++ "}" )
            ]

        holding messages any =
            String.repeat (messages - 1) "{\"replies\":["
                ++ ("{\"payload\":" ++ any ++ "}")
                ++ String.repeat (messages - 1) "]}"

        read =
            Json.Decode.decodeString (Deep.decodeEnvelopeWith types) >> ok

        -- The same in binary: each level past the first as the layers
        -- around the one inside, and the innermost level's own bytes. A
        -- Chain's `next` has the tag of an Envelope's `replies`.
        chainBytes levels =
            List.repeat (levels - 1) reply

        binaryKinds =
            [ ( "a Chain", "cycles.v1.Chain", \levels -> ( chainBytes levels, [] ) )
            , ( "a Value", "google.protobuf.Value", \levels -> ( List.concat (List.repeat (levels - 1) [ listInValue, valueInList ]), [ 0x32, 0x00 ] ) )
            , ( "a Struct", "google.protobuf.Struct", \levels -> ( List.concat (List.repeat (levels - 1) [ memberA, structInValue ]), [] ) )
            , ( "a ListValue", "google.protobuf.ListValue", \levels -> ( List.concat (List.repeat (levels - 1) [ valueInList, listInValue ]), [] ) )
            ]

        anyOf name size =
            let
                typeUrl =
                    List.map Char.toCode (String.toList ("type.googleapis.com/" ++ name))

                any =
                    0x0A :: varint (List.length typeUrl) ++ typeUrl ++ (0x12 :: varint size)
            in
            0x0A :: varint (List.length any + size) ++ any

        binaryOfAny name ( inside, core ) messages =
            wrapped (List.repeat (messages - 1) reply ++ anyOf name :: inside) core

        written bytes =
            case readEnvelopeBytesValue bytes of
                Ok envelope ->
                    Deep.encodeEnvelopeWith types envelope |> ok

                Err _ ->
                    Err (Proto.Error.BadJson (Json.Decode.Failure "did not read" Json.Encode.null))

        refusedWriting name =
            Expect.equal (Err name)
                << Result.mapError
                    (\error ->
                        case error of
                            Proto.Error.BadBinary problem ->
                                if problem.reason == Proto.Error.TooDeep then
                                    problem.typeName

                                else
                                    "another reason"

                            _ ->
                                "another error"
                    )
    in
    describe "an Any of a type whose codecs take no registry counts its message from 1"
        [ describe "read from JSON"
            (List.map
                (\( name, any ) ->
                    test name <|
                        \_ ->
                            Expect.all
                                [ \_ -> read (holding 1 (any 100)) |> Expect.equal (Ok ())
                                , \_ -> read (holding 1 (any 101)) |> failsTooDeep
                                , \_ -> read (holding 99 (any 100)) |> Expect.equal (Ok ())
                                , \_ -> read (holding 99 (any 101)) |> failsTooDeep
                                , \_ -> read (holding 100 (any 1)) |> failsTooDeep
                                ]
                                ()
                )
                kinds
            )
        , describe "read from binary, which holds the message's bytes unread"
            (List.map
                (\( name, typeName, levels ) ->
                    test name <|
                        \_ ->
                            Expect.all
                                [ \_ -> readEnvelopeBytes (binaryOfAny typeName (levels 101) 100) |> Expect.equal (Ok ())
                                , \_ -> readEnvelopeBytes (binaryOfAny typeName (levels 1) 101) |> tooDeepBinary |> Expect.equal (Err Proto.Error.TooDeep)
                                ]
                                ()
                )
                binaryKinds
            )
        , describe "read from binary and written as JSON"
            (List.map
                (\( name, typeName, levels ) ->
                    test name <|
                        \_ ->
                            Expect.all
                                [ \_ -> written (binaryOfAny typeName (levels 100) 1) |> Expect.equal (Ok ())
                                , \_ -> written (binaryOfAny typeName (levels 101) 1) |> refusedWriting typeName
                                , \_ -> written (binaryOfAny typeName (levels 100) 99) |> Expect.equal (Ok ())
                                , \_ -> written (binaryOfAny typeName (levels 101) 99) |> refusedWriting typeName
                                , \_ -> written (binaryOfAny typeName (levels 1) 100) |> refusedWriting "google.protobuf.Any"
                                ]
                                ()
                )
                binaryKinds
            )
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
            Proto.Method.init "cycles.v1.Envelopes" "Get" Deep.encodeEnvelopeWith Deep.decodeEnvelopeWith Deep.encodeEnvelopeBytes Deep.decodeEnvelopeBytes

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
                        case Deep.encodeEnvelopeWith Deep.registry envelope of
                            Err (Proto.Error.BadBinary problem) ->
                                problem.reason |> Expect.equal Proto.Error.TooDeep

                            _ ->
                                Expect.fail "converted past the limit"

                    Err _ ->
                        Expect.fail "did not read"
        , test "an Any chain read from binary converts to JSON with the error" <|
            \_ ->
                case readEnvelopeBytesValue (wrapped (List.repeat 10000 payload) []) of
                    Ok envelope ->
                        case Deep.encodeEnvelopeWith Deep.registry envelope of
                            Err (Proto.Error.BadBinary problem) ->
                                problem.reason |> Expect.equal Proto.Error.TooDeep

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
                        Proto.Method.init "cycles.v1.Trees" "Get" (\_ -> Ok << Deep.encodeTree) (\_ -> Deep.decodeTree) Deep.encodeTreeBytes Deep.decodeTreeBytes

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



-- VALUE REFUSALS


{-| A `Value`, `Struct` or `ListValue` refused for its depth fails with the
limit's text alone, at the field holding it, and one given JSON of the wrong
kind fails as elm/json does for that kind, however deep the JSON is.
-}
valueRefusals : Test
valueRefusals =
    let
        replies messages =
            List.concat (List.repeat (messages - 1) [ "replies", "0" ])

        listJson messages levels =
            mixedJson (\_ -> False) messages levels

        readsAt decoder text =
            Json.Decode.decodeString decoder text |> ok |> Expect.equal (Ok ())

        refusedAt path text result =
            result |> Result.mapError failureAt |> Expect.equal (Err (Just ( path, text )))

        readWellKnown =
            Json.Decode.decodeString (Codec.decodeWellKnownWith Proto.WellKnown.registry)
    in
    describe "a Value, Struct or ListValue refused"
        [ describe "past the limit says the limit, at the field"
            [ test "a Value, read alone" <|
                \_ ->
                    Expect.all
                        [ \_ -> readsAt Proto.Json.value (nestedArrays 100)
                        , \_ -> readsAt Proto.Value.decoder (nestedArrays 100)
                        , \_ -> Json.Decode.decodeString Proto.Json.value (nestedArrays 101) |> refusedAt [] tooDeepText
                        , \_ -> Json.Decode.decodeString Proto.Value.decoder (nestedObjects 101) |> refusedAt [] tooDeepText
                        ]
                        ()
            , test "a Struct, read alone" <|
                \_ ->
                    Expect.all
                        [ \_ -> readsAt Proto.Json.struct (nestedObjects 100)
                        , \_ -> Json.Decode.decodeString Proto.Json.struct (nestedObjects 101) |> refusedAt [] tooDeepText
                        ]
                        ()
            , test "a ListValue, read alone" <|
                \_ ->
                    Expect.all
                        [ \_ -> readsAt Proto.Json.listValue (nestedArrays 100)
                        , \_ -> Json.Decode.decodeString Proto.Json.listValue (nestedArrays 101) |> refusedAt [] tooDeepText
                        ]
                        ()
            , test "a Value in a message on a cycle" <|
                \_ ->
                    Expect.all
                        [ \_ -> readEnvelope (valueArraysJson 40 60) |> Expect.equal (Ok ())
                        , \_ -> readEnvelope (valueArraysJson 40 61) |> refusedAt (replies 40 ++ [ "value" ]) tooDeepText
                        ]
                        ()
            , test "a Struct in a message on a cycle" <|
                \_ ->
                    Expect.all
                        [ \_ -> readEnvelope (structJson 40 60) |> Expect.equal (Ok ())
                        , \_ -> readEnvelope (structJson 40 61) |> refusedAt (replies 40 ++ [ "data" ]) tooDeepText
                        , \_ -> readEnvelope (structJson 100 1) |> refusedAt (replies 100 ++ [ "data" ]) tooDeepText
                        ]
                        ()
            , test "a ListValue in a message on a cycle" <|
                \_ ->
                    Expect.all
                        [ \_ -> readEnvelope (listJson 40 60) |> Expect.equal (Ok ())
                        , \_ -> readEnvelope (listJson 40 61) |> refusedAt (replies 40 ++ [ "list" ]) tooDeepText
                        ]
                        ()
            ]
        , describe "for its kind says the kind, however deep"
            [ test "a Struct, read alone" <|
                \_ ->
                    Expect.all
                        [ \_ -> Json.Decode.decodeString Proto.Json.struct "[1]" |> refusedAt [] "Expecting an OBJECT"
                        , \_ -> Json.Decode.decodeString Proto.Json.struct "\"x\"" |> refusedAt [] "Expecting an OBJECT"
                        , \_ -> Json.Decode.decodeString Proto.Json.struct "null" |> refusedAt [] "Expecting an OBJECT"
                        , \_ -> Json.Decode.decodeString Proto.Json.struct (nestedArrays 200) |> refusedAt [] "Expecting an OBJECT"
                        ]
                        ()
            , test "a ListValue, read alone" <|
                \_ ->
                    Expect.all
                        [ \_ -> Json.Decode.decodeString Proto.Json.listValue "{\"a\":1}" |> refusedAt [] "Expecting a LIST"
                        , \_ -> Json.Decode.decodeString Proto.Json.listValue "null" |> refusedAt [] "Expecting a LIST"
                        , \_ -> Json.Decode.decodeString Proto.Json.listValue (nestedObjects 200) |> refusedAt [] "Expecting a LIST"
                        ]
                        ()
            , test "a Struct or ListValue field, a map value and null" <|
                \_ ->
                    Expect.all
                        [ \_ -> readWellKnown "{\"struct\":[1]}" |> refusedAt [ "struct" ] "Expecting an OBJECT"
                        , \_ -> readWellKnown "{\"struct\":\"x\"}" |> refusedAt [ "struct" ] "Expecting an OBJECT"
                        , \_ -> readWellKnown "{\"list\":{\"a\":1}}" |> refusedAt [ "list" ] "Expecting a LIST"
                        , \_ -> readWellKnown "{\"structs\":{\"1\":[]}}" |> refusedAt [ "structs", "1" ] "Expecting an OBJECT"
                        , \_ -> readWellKnown "{\"struct\":null,\"list\":null}" |> Result.map (\read -> ( read.struct, read.list )) |> Expect.equal (Ok ( Nothing, Nothing ))
                        ]
                        ()
            , test "a Struct or ListValue field on a cycle, given deep JSON" <|
                \_ ->
                    Expect.all
                        [ \_ -> readEnvelope ("{\"data\":" ++ nestedArrays 200 ++ "}") |> refusedAt [ "data" ] "Expecting an OBJECT"
                        , \_ -> readEnvelope "{\"data\":\"x\"}" |> refusedAt [ "data" ] "Expecting an OBJECT"
                        , \_ -> readEnvelope ("{\"list\":" ++ nestedObjects 200 ++ "}") |> refusedAt [ "list" ] "Expecting a LIST"
                        , \_ -> readEnvelope (String.repeat 99 "{\"replies\":[" ++ "{\"data\":[]}" ++ String.repeat 99 "]}") |> refusedAt (replies 100 ++ [ "data" ]) "Expecting an OBJECT"
                        ]
                        ()
            ]
        ]


{-| The path to the failure, as field names and indexes, and its text;
`Nothing` for an error that failed in more than one way.
-}
failureAt : Json.Decode.Error -> Maybe ( List String, String )
failureAt error =
    case error of
        Json.Decode.Field name inner ->
            Maybe.map (Tuple.mapFirst ((::) name)) (failureAt inner)

        Json.Decode.Index index inner ->
            Maybe.map (Tuple.mapFirst ((::) (String.fromInt index))) (failureAt inner)

        Json.Decode.Failure text _ ->
            Just ( [], text )

        Json.Decode.OneOf _ ->
            Nothing


{-| `levels` arrays nested.
-}
nestedArrays : Int -> String
nestedArrays levels =
    String.repeat levels "[" ++ String.repeat levels "]"


{-| `levels` objects nested, each the member `"a"` of the one around it.
-}
nestedObjects : Int -> String
nestedObjects levels =
    String.repeat (levels - 1) "{\"a\":" ++ "{}" ++ String.repeat (levels - 1) "}"


{-| A `Value`, `Struct` or `ListValue` refused for its depth gives an error of
a few hundred characters through the library, however wide or deep the
value: the levels' own failure, which holds every way each level failed, is
never returned.
-}
valueErrorsShort : Test
valueErrorsShort =
    let
        wide levels =
            String.repeat levels "{\"k1\":[1,\"s\",true],\"k2\":[2,\"s\",true],\"k3\":[3,\"s\",true],\"z\":" ++ "1" ++ String.repeat levels "}"

        printsWithin limit result =
            case result of
                Err (Proto.Error.BadJson error) ->
                    Expect.all
                        [ \_ -> Json.Decode.errorToString error |> String.length |> Expect.atMost limit
                        , \_ -> Proto.Error.toString (Proto.Error.BadJson error) |> String.length |> Expect.atMost limit
                        ]
                        ()

                _ ->
                    Expect.fail "not BadJson"

        parsed text =
            Json.Decode.decodeString Json.Decode.value text |> Result.withDefault Json.Encode.null

        method =
            Proto.Method.init "cycles.v1.Envelopes" "Get" Deep.encodeEnvelopeWith Deep.decodeEnvelopeWith Deep.encodeEnvelopeBytes Deep.decodeEnvelopeBytes

        answered text =
            Http.GoodStatus_ { url = "https://api.example.com/cycles.v1.Envelopes/Get", statusCode = 200, statusText = "OK", headers = Dict.fromList [ ( "content-type", "application/json" ) ] } text
                |> Rpc.response (Rpc.client Rpc.Protocol.connect "https://api.example.com" |> Rpc.Client.withRegistry Deep.registry) (Rpc.call method Deep.defaultEnvelope)
                |> Result.mapError (Rpc.Error.protoError >> Maybe.withDefault (Proto.Error.BadJson (Json.Decode.Failure "not a protobuf error" Json.Encode.null)))

        decodeValueMessage =
            Proto.Message.decodeJson Proto.WellKnown.registry Proto.WellKnown.value
    in
    describe "a Value, Struct or ListValue refused prints short through the library"
        [ test "refused at 101 levels" <|
            \_ ->
                Expect.all
                    [ \_ -> Proto.Message.decodeJson Deep.registry Deep.messageEnvelope (parsed (valueArraysJson 1 100)) |> printsWithin 300
                    , \_ -> answered (valueArraysJson 1 100) |> printsWithin 300
                    , \_ -> answered (structJson 1 101) |> printsWithin 300
                    , \_ -> decodeValueMessage (parsed (nestedArrays 101)) |> printsWithin 300
                    ]
                    ()
        , test "wide and too deep" <|
            \_ ->
                Expect.all
                    [ \_ -> Proto.Message.decodeJson Deep.registry Deep.messageEnvelope (parsed ("{\"value\":" ++ wide 101 ++ "}")) |> printsWithin 300
                    , \_ -> answered ("{\"value\":" ++ wide 101 ++ "}") |> printsWithin 300
                    , \_ -> answered ("{\"data\":" ++ wide 101 ++ "}") |> printsWithin 300
                    , \_ -> decodeValueMessage (parsed (wide 101)) |> printsWithin 300
                    ]
                    ()
        , test "100,000 levels" <|
            \_ -> decodeValueMessage (parsed (nestedArrays 100000)) |> printsWithin 300
        ]
