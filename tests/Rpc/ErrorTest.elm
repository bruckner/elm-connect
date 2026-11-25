module Rpc.ErrorTest exposing (suite)

{-| `Rpc.Error`: its builders, the invariant they keep, and what each
accessor reads; the runtime's errors are held to the same invariant in
`all` below and compared with built ones throughout the other tests.
-}

import Dict
import Expect
import Http
import Json.Decode
import Json.Encode
import Proto.Any
import Proto.Error
import Proto.Json.Encode
import Proto.Method
import Proto.WellKnown
import Rpc
import Rpc.Body
import Rpc.Code exposing (Code(..))
import Rpc.Error exposing (Cause(..), Error, Source(..))
import Rpc.Protocol
import Test exposing (Test, describe, test)


answer : Int -> String -> Rpc.Response
answer status body =
    { url = "https://api.example.com/t.v1.S/Get", statusCode = status, statusText = "", headers = Dict.empty, body = Rpc.Body.text body }


{-| Whether an error keeps the invariant: a `BadResponse` holds a success
(2xx); a `BadStatus` holds a failure status, or a success whose answer stated
a status.
-}
keepsInvariant : Error -> Bool
keepsInvariant error =
    case Rpc.Error.cause error of
        BadResponse got ->
            success got

        BadStatus got ->
            not (success got) || Rpc.Error.source error /= Nothing

        BadCall ->
            True

        NetworkError ->
            True

        Timeout ->
            True


success : Rpc.Response -> Bool
success got =
    got.statusCode >= 200 && got.statusCode < 300


connect : Rpc.Client Rpc.Json
connect =
    Rpc.client Rpc.Protocol.connect "https://api.example.com"


call : Rpc.Call Rpc.Json () String
call =
    Rpc.call (Proto.Method.initJson "t.v1.S" "Get" (\_ -> Proto.Json.Encode.succeed Json.Encode.null) (\_ -> stringDecoder)) ()


stringDecoder : Json.Decode.Decoder String
stringDecoder =
    Json.Decode.field "title" Json.Decode.string


read : Int -> List ( String, String ) -> String -> Result Error String
read status headers body =
    Rpc.response connect
        call
        ((if status >= 200 && status < 300 then
            Http.GoodStatus_

          else
            Http.BadStatus_
         )
            { url = "https://api.example.com/t.v1.S/Get", statusCode = status, statusText = "", headers = Dict.fromList headers }
            body
        )


suite : Test
suite =
    describe "Rpc.Error"
        [ test "every builder keeps the invariant, whatever the answer's status" <|
            \_ ->
                List.concatMap
                    (\status ->
                        [ Rpc.Error.fromResponse (answer status "")
                        , Rpc.Error.badResponse Internal "bad response: x" (answer status "")
                        , Rpc.Error.badBody (Proto.Error.UnregisteredType "x/a.B") (answer status "")
                        , Rpc.Error.fromStatus { code = NotFound, message = "", details = [], source = GrpcTrailers } (answer status "")
                        ]
                    )
                    [ 0, 200, 204, 299, 300, 400, 404, 500, 503 ]
                    ++ [ Rpc.Error.fromCode NotFound, Rpc.Error.timeout, Rpc.Error.networkError, Rpc.Error.badCall Internal "x", Rpc.Error.badAny (Proto.Error.UnregisteredType "x/a.B") ]
                    |> List.all keepsInvariant
                    |> Expect.equal True
        , test "the runtime's errors keep the invariant" <|
            \_ ->
                [ read 200 [ ( "content-type", "text/html" ) ] "<html>"
                , read 200 [ ( "content-type", "text/html" ) ] """{"code":"unavailable","message":"down"}"""
                , read 200 [ ( "content-type", "application/proto" ) ] ""
                , read 200 [] "{}"
                , read 204 [] ""
                , read 404 [] "<html>"
                , read 503 [ ( "grpc-status", "14" ) ] ""
                , read 400 [] """{"code":"invalid_argument"}"""
                ]
                    |> List.map (Result.map (\_ -> True) >> Result.mapError keepsInvariant)
                    |> Expect.equal (List.repeat 8 (Err True))
        , test "a success that states no status is a BadResponse whose code is Unknown, as fromResponse builds it" <|
            \_ ->
                ( [ read 200 [ ( "content-type", "text/html" ) ] "<html>", read 204 [] "" ]
                    |> List.map (Result.mapError Rpc.Error.code)
                , read 200 [ ( "content-type", "text/html" ) ] "<html>"
                )
                    |> Expect.equal
                        ( [ Err Unknown, Err Unknown ]
                        , Err (Rpc.Error.fromResponse { url = "https://api.example.com/t.v1.S/Get", statusCode = 200, statusText = "", headers = Dict.fromList [ ( "content-type", "text/html" ) ], body = Rpc.Body.text "<html>" })
                        )
        , test "fromResponse: a failure status is a BadStatus, its code inferred; a success a BadResponse, Unknown" <|
            \_ ->
                [ Rpc.Error.fromResponse (answer 404 ""), Rpc.Error.fromResponse (answer 200 "") ]
                    |> List.map (\error -> ( Rpc.Error.code error, isBadStatus error, Rpc.Error.message error ))
                    |> Expect.equal [ ( Unimplemented, True, "HTTP 404" ), ( Unknown, False, "HTTP 200" ) ]
        , test "badResponse and badBody given a failure status give the error fromResponse builds, as the runtime would" <|
            \_ ->
                [ Rpc.Error.badResponse Internal "bad response: x" (answer 500 ""), Rpc.Error.badBody (Proto.Error.UnregisteredType "x/a.B") (answer 404 "") ]
                    |> Expect.equal [ Rpc.Error.fromResponse (answer 500 ""), Rpc.Error.fromResponse (answer 404 "") ]
        , test "fromCode is a stated status in a stand-in answer: the code's HTTP status, no headers, no body" <|
            \_ ->
                Rpc.Error.fromCode NotFound
                    |> Expect.equal
                        (Rpc.Error.fromStatus { code = NotFound, message = "", details = [], source = ConnectBody }
                            { url = "", statusCode = 404, statusText = "", headers = Dict.empty, body = Rpc.Body.none }
                        )
        , test "protoError is the problem of a bad body or a bad Any, and Nothing for every other error" <|
            \_ ->
                [ Rpc.Error.badBody (Proto.Error.UnregisteredType "x/a.B") (answer 200 "")
                , Rpc.Error.badAny (Proto.Error.UnregisteredType "x/c.D")
                , Rpc.Error.badResponse Internal "bad response: x" (answer 200 "")
                , Rpc.Error.badCall Internal "x"
                , Rpc.Error.fromCode Internal
                , Rpc.Error.fromResponse (answer 500 "")
                , Rpc.Error.timeout
                , Rpc.Error.networkError
                ]
                    |> List.map Rpc.Error.protoError
                    |> Expect.equal
                        [ Just (Proto.Error.UnregisteredType "x/a.B"), Just (Proto.Error.UnregisteredType "x/c.D"), Nothing, Nothing, Nothing, Nothing, Nothing, Nothing ]
        , test "a bad body and a bad Any have constant messages and codes" <|
            \_ ->
                [ Rpc.Error.badBody (Proto.Error.UnregisteredType "x/a.B") (answer 200 ""), Rpc.Error.badAny (Proto.Error.UnregisteredType "x/a.B") ]
                    |> List.map (\error -> ( Rpc.Error.code error, Rpc.Error.message error, isBadResponse error ))
                    |> Expect.equal [ ( Internal, "bad response body", True ), ( Internal, "bad Any", False ) ]
        , test "a bad value is an InvalidArgument BadCall naming its type and what is wrong, not its path, its BadValue in protoError" <|
            \_ ->
                let
                    error =
                        Rpc.Error.badValue { typeName = "google.protobuf.Timestamp", path = [ "byDay", "2026-01-01" ], message = "the time is outside years 1 to 9999" }
                in
                ( ( Rpc.Error.code error, Rpc.Error.message error, Rpc.Error.cause error == Rpc.Error.BadCall )
                , Rpc.Error.protoError error
                , keepsInvariant error
                )
                    |> Expect.equal
                        ( ( InvalidArgument, "bad value: a google.protobuf.Timestamp with no JSON form (the time is outside years 1 to 9999)", True )
                        , Just (Proto.Error.BadValue { typeName = "google.protobuf.Timestamp", path = [ "byDay", "2026-01-01" ], message = "the time is outside years 1 to 9999" })
                        , True
                        )
        , test "fromStatus carries details, ones that failed to read included" <|
            \_ ->
                let
                    details =
                        [ Ok (Proto.Any.pack Proto.WellKnown.stringValue "d"), Err (Proto.Error.UnregisteredType "x/a.B") ]
                in
                Rpc.Error.fromStatus { code = NotFound, message = "", details = details, source = StatusBody } (answer 404 "")
                    |> Rpc.Error.details
                    |> Expect.equal details
        , test "withMessage sets the message of any error" <|
            \_ ->
                [ Rpc.Error.fromCode NotFound, Rpc.Error.timeout, Rpc.Error.fromResponse (answer 500 ""), Rpc.Error.badBody (Proto.Error.UnregisteredType "x/a.B") (answer 200 "") ]
                    |> List.map (Rpc.Error.withMessage "m" >> Rpc.Error.message)
                    |> Expect.equal [ "m", "m", "m", "m" ]
        , test "httpStatus is the status of the answer a BadStatus or a BadResponse holds" <|
            \_ ->
                [ Rpc.Error.fromCode NotFound, Rpc.Error.fromResponse (answer 200 ""), Rpc.Error.timeout, Rpc.Error.networkError, Rpc.Error.badCall Internal "x" ]
                    |> List.map Rpc.Error.httpStatus
                    |> Expect.equal [ Just 404, Just 200, Nothing, Nothing, Nothing ]
        ]


isBadStatus : Error -> Bool
isBadStatus error =
    case Rpc.Error.cause error of
        BadStatus _ ->
            True

        _ ->
            False


isBadResponse : Error -> Bool
isBadResponse error =
    case Rpc.Error.cause error of
        BadResponse _ ->
            True

        _ ->
            False
