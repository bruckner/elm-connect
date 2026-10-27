module Replay exposing (Expected, Fixture, fixture, normalize, replay)

{-| Replaying the route fixtures (`conformance/routes`) and the route
properties through `Shim.request` with the Transcode transport: `RouteFixtures`
and `RouteProperties` are generated from them, and `RouteFixturesTest` and
`RoutePropertiesTest` check each.
-}

import Expect
import Json.Decode exposing (Decoder)
import Json.Encode exposing (Value)
import Rpc
import Rpc.Body
import Rpc.Call
import Rpc.Protocol
import Shim
import Test exposing (Test, test)


type alias Fixture =
    { name : String
    , actual : Result String Rpc.Request
    , expected : Expected
    }


{-| The request a fixture expects, its URL relative to an empty base URL.
-}
type alias Expected =
    { method : String
    , url : String
    , headers : List ( String, String )
    , body : Maybe String
    }


{-| A fixture: its name, the decoder of its request, the generated function of
its method, the number of its binding (`Nothing` for a method without a rule,
whose call is left as it is), its request as proto3 JSON, and the request
expected. A binding the method does not have is a failure, not the implicit
route.
-}
fixture : String -> Decoder req -> (req -> Rpc.Call Rpc.Json req res) -> Maybe Int -> String -> Expected -> Fixture
fixture name decoder method binding json expected =
    { name = name
    , actual =
        Json.Decode.decodeString decoder json
            |> Result.mapError (\problem -> "the request does not decode: " ++ Json.Decode.errorToString problem)
            |> Result.andThen
                (\message ->
                    case binding of
                        Nothing ->
                            Ok (method message)

                        Just index ->
                            Rpc.Call.viaBinding index (method message)
                                |> Result.fromMaybe ("the method has no binding " ++ String.fromInt index)
                )
            |> Result.map (Shim.request transcode)
    , expected = expected
    }


{-| A fixture's test: the request `Shim.request` builds is the one expected,
bodies compared once normalized.
-}
replay : Fixture -> Test
replay case_ =
    test case_.name <|
        \_ ->
            case case_.actual of
                Err problem ->
                    Expect.fail problem

                Ok request ->
                    { method = request.method
                    , url = request.url
                    , headers = request.headers
                    , body = Maybe.map normalize (Rpc.Body.toText request.body)
                    }
                        |> Expect.equal
                            { method = case_.expected.method
                            , url = case_.expected.url
                            , headers = case_.expected.headers
                            , body = Maybe.map normalize case_.expected.body
                            }


transcode : Shim.Config Rpc.Json
transcode =
    let
        base =
            Shim.config ""
    in
    { base | transport = Rpc.Protocol.transcode }


{-| A JSON body, normalized as the Rust half of the fixtures normalizes it:
`null`s and default values (`""`, `0`, `false`, `"0"`, `[]`, `{}`) dropped
from objects, keys sorted, numbers written as floats.
-}
normalize : String -> Result String String
normalize json =
    Json.Decode.decodeString tree json
        |> Result.mapError Json.Decode.errorToString
        |> Result.map (encode >> Json.Encode.encode 0)


type Tree
    = Object (List ( String, Tree ))
    | Array (List Tree)
    | Text String
    | Number Float
    | Boolean Bool
    | Null


tree : Decoder Tree
tree =
    Json.Decode.oneOf
        [ Json.Decode.map Text Json.Decode.string
        , Json.Decode.map Number Json.Decode.float
        , Json.Decode.map Boolean Json.Decode.bool
        , Json.Decode.null Null
        , Json.Decode.map Array (Json.Decode.list (Json.Decode.lazy (\_ -> tree)))
        , Json.Decode.map Object (Json.Decode.keyValuePairs (Json.Decode.lazy (\_ -> tree)))
        ]


isDefault : Tree -> Bool
isDefault value =
    case value of
        Null ->
            True

        Boolean b ->
            not b

        Number n ->
            n == 0

        Text s ->
            s == "" || s == "0"

        Array items ->
            List.isEmpty items

        Object pairs ->
            List.isEmpty pairs


clean : Tree -> Tree
clean value =
    case value of
        Object pairs ->
            pairs
                |> List.map (Tuple.mapSecond clean)
                |> List.filter (Tuple.second >> isDefault >> not)
                |> List.sortBy Tuple.first
                |> Object

        Array items ->
            Array (List.map clean items)

        other ->
            other


encode : Tree -> Value
encode value =
    case clean value of
        Object pairs ->
            Json.Encode.object (List.map (Tuple.mapSecond encode) pairs)

        Array items ->
            Json.Encode.list encode items

        Text s ->
            Json.Encode.string s

        Number n ->
            Json.Encode.float n

        Boolean b ->
            Json.Encode.bool b

        Null ->
            Json.Encode.null
