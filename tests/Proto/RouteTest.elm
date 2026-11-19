module Proto.RouteTest exposing (suite)

import Bytes exposing (Bytes)
import Bytes.Encode
import Expect
import Proto.Query
import Proto.Route
import Test exposing (Test, describe, test)


bytesOf : List Int -> Bytes
bytesOf ints =
    Bytes.Encode.encode (Bytes.Encode.sequence (List.map Bytes.Encode.unsignedInt8 ints))


suite : Test
suite =
    describe "the route helpers typed routes call"
        [ describe "Proto.Route.bytesText"
            [ test "writes the URL-safe alphabet: - and _ for + and /" <|
                \_ ->
                    -- FB FF is +/8= in the standard alphabet.
                    Proto.Route.bytesText (bytesOf [ 0xFB, 0xFF ])
                        |> Expect.equal "-_8="
            , test "keeps the letters, digits and padding of standard base64" <|
                \_ ->
                    List.map (Proto.Route.bytesText << bytesOf)
                        [ [ 104 ], [ 104, 105 ], [ 104, 105, 33 ], [ 0xFB, 0xEF, 0xBE ] ]
                        |> Expect.equal [ "aA==", "aGk=", "aGkh", "----" ]
            , test "writes every value of a byte without + or /" <|
                \_ ->
                    Proto.Route.bytesText (bytesOf (List.range 0 255))
                        |> String.filter (\c -> c == '+' || c == '/')
                        |> Expect.equal ""
            , test "is empty for no bytes" <|
                \_ ->
                    Proto.Route.bytesText (bytesOf [])
                        |> Expect.equal ""
            ]
        , describe "Proto.Query.bytes"
            [ test "is no parameter when the field holds no bytes" <|
                \_ ->
                    Proto.Query.bytes "data" (bytesOf [])
                        |> Expect.equal []
            , test "is the bytes' route text otherwise, a zero byte included" <|
                \_ ->
                    [ Proto.Query.bytes "data" (bytesOf [ 0 ])
                    , Proto.Query.bytes "data" (bytesOf [ 0xFB, 0xFF ])
                    ]
                        |> Expect.equal [ [ ( "data", "AA==" ) ], [ ( "data", "-_8=" ) ] ]
            ]
        ]
