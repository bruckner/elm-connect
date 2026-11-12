port module Testee exposing (main)

{-| The protobuf conformance suite's testee, for `conformance_test_runner`
(protocolbuffers/protobuf `conformance/`), driven by `testee.mjs`: each
request on `requests` is a `protobuf_test_messages.proto3.TestAllTypesProto3`
in protobuf binary (base64) or proto3 JSON, read with the generated decoders
and written back in the format asked for with the generated encoders,
answered on `responses`. The test messages are generated under `codec=both`,
so an `Any` holds its message's binary, and is read from and written to
proto3 JSON through [`registry`](#registry), the test messages' and the
well-known types': one of a type it lacks fails to parse, and to serialize.

The other formats (JSPB, text) and the other message types (proto2,
editions) are answered `skipped`. The answer dispatches on the output format
and `read` on the input format.

-}

import Json.Decode
import Json.Encode
import Proto.Binary
import Proto.Bytes
import Proto.Error
import Proto.Registry exposing (Registry)
import Proto.WellKnown
import ProtobufTestMessages.Proto3 as Proto3


{-| The types an `Any` of the suite's may hold: the generated package's own
messages, and the well-known types, which a generated registry leaves out.
-}
registry : Registry
registry =
    Proto.Registry.unionAll [ Proto3.registry, Proto.WellKnown.registry ]


port requests : (Request -> msg) -> Sub msg


port responses : { id : Int, kind : String, payload : String } -> Cmd msg


{-| One request, as `testee.mjs` reads it: the input's format (`protobuf`,
`json` or another) and payload (base64 for `protobuf`), the output's format,
and the message's full name.
-}
type alias Request =
    { id : Int
    , messageType : String
    , inputFormat : String
    , payload : String
    , outputFormat : String
    }


main : Program () () Request
main =
    Platform.worker
        { init = \() -> ( (), Cmd.none )
        , update = \request () -> ( (), responses (answer request) )
        , subscriptions = \() -> requests identity
        }


answer : Request -> { id : Int, kind : String, payload : String }
answer request =
    let
        reply kind payload =
            { id = request.id, kind = kind, payload = payload }
    in
    if request.messageType /= "protobuf_test_messages.proto3.TestAllTypesProto3" then
        reply "skipped" ("message type " ++ request.messageType)

    else
        case request.outputFormat of
            "json" ->
                case read request of
                    Err ( kind, problem ) ->
                        reply kind problem

                    Ok message ->
                        case Proto3.encodeTestAllTypesProto3With registry message of
                            Ok json ->
                                reply "json" (Json.Encode.encode 0 json)

                            Err problem ->
                                reply "serializeError" (Proto.Error.toString problem)

            "protobuf" ->
                case read request of
                    Err ( kind, problem ) ->
                        reply kind problem

                    Ok message ->
                        reply "protobuf" (Proto.Bytes.toBase64 (Proto.Binary.encode Proto3.encodeTestAllTypesProto3Bytes message))

            other ->
                reply "skipped" ("output format " ++ other)


read : Request -> Result ( String, String ) Proto3.TestAllTypesProto3
read request =
    case request.inputFormat of
        "protobuf" ->
            case Proto.Bytes.fromBase64 request.payload of
                Just input ->
                    Proto.Binary.decode Proto3.decodeTestAllTypesProto3Bytes input
                        |> Result.mapError (\problem -> ( "parseError", Proto.Error.toString (Proto.Error.BadBinary problem) ))

                Nothing ->
                    Err ( "parseError", "the payload is not base64" )

        "json" ->
            Json.Decode.decodeString (Proto3.decodeTestAllTypesProto3With registry) request.payload
                |> Result.mapError (\problem -> ( "parseError", Json.Decode.errorToString problem ))

        other ->
            Err ( "skipped", "input format " ++ other )
