module Proto.ErrorDetailsTest exposing (suite)

import Dict
import Expect
import Json.Decode
import Json.Encode
import Proto.Any as Any
import Proto.Duration as Duration
import Proto.Error
import Proto.ErrorDetails as ErrorDetails
import Proto.Json
import Proto.Registry as Registry
import Proto.WellKnown
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "Proto.ErrorDetails"
        [ test "a detail packs and unpacks with its typed value, no registry needed" <|
            \_ ->
                let
                    info =
                        { reason = "GONE", domain = "example.com", metadata = Dict.fromList [ ( "name", "notes/1" ) ] }
                in
                ( Any.unpack ErrorDetails.errorInfo (Any.pack ErrorDetails.errorInfo info)
                , Any.typeUrl (Any.pack ErrorDetails.badRequest { fieldViolations = [] })
                )
                    |> Expect.equal ( Just info, "type.googleapis.com/google.rpc.BadRequest" )
        , test "the registry reads and writes every detail's proto3 JSON, nested names as protobuf's" <|
            \_ ->
                [ """{"@type":"type.googleapis.com/google.rpc.BadRequest","fieldViolations":[{"field":"title","description":"needed"}]}"""
                , """{"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"1.500s"}"""
                , """{"@type":"type.googleapis.com/google.rpc.Help.Link","description":"docs","url":"https://example.com"}"""
                ]
                    |> List.map
                        (Json.Decode.decodeString (Proto.Json.anyWith ErrorDetails.registry)
                            >> Result.mapError Json.Decode.errorToString
                            >> Result.andThen (Proto.Json.encodeAnyWith ErrorDetails.registry >> Result.mapError (\_ -> "unwritable"))
                            >> Result.map (Json.Encode.encode 0)
                        )
                    |> Expect.equal
                        [ Ok """{"@type":"type.googleapis.com/google.rpc.BadRequest","fieldViolations":[{"field":"title","description":"needed"}]}"""
                        , Ok """{"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"1.500s"}"""
                        , Ok """{"@type":"type.googleapis.com/google.rpc.Help.Link","description":"docs","url":"https://example.com"}"""
                        ]
        , test "the registry holds no well-known type" <|
            \_ ->
                Proto.Json.encodeAnyWith ErrorDetails.registry (Any.pack Proto.WellKnown.duration (Duration.fromMilliseconds 1))
                    |> Expect.equal (Err (Proto.Error.UnregisteredType "type.googleapis.com/google.protobuf.Duration"))
        , test "a RetryInfo's delay unpacks" <|
            \_ ->
                Json.Decode.decodeString (Proto.Json.anyWith (Registry.union ErrorDetails.registry Registry.empty)) """{"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"2s"}"""
                    |> Result.toMaybe
                    |> Maybe.andThen (Any.unpack ErrorDetails.retryInfo)
                    |> Maybe.andThen .retryDelay
                    |> Maybe.map Duration.toMilliseconds
                    |> Expect.equal (Just 2000)
        ]
