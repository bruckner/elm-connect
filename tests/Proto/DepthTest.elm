module Proto.DepthTest exposing (suite)

{-| Messages on a cycle of references are read at most 100 levels deep, a
level being each message entered along a field or oneof member of the
cycle: every shape of cycle in `conformance/cases/depth_cycles`, and two
under `unknown_fields=keep` in `conformance/cases/depth_cycles_keep`
(generated under `tests/Generated/` by `crates/elm-connect-gen/tests/depth.rs`,
`just tests-gen`), at 100 levels, at 101, and far past any engine's stack,
built here without recursion.
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
import Proto.Binary
import Proto.Bytes
import Proto.Error
import Proto.Message
import Proto.Method
import Proto.WellKnown
import Rpc
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
