port module Testee exposing (main)

{-| The protobuf conformance suite's testee, for `conformance_test_runner`
(protocolbuffers/protobuf `conformance/`), driven by `testee.mjs`: each
request on `requests` is a `protobuf_test_messages.proto3.TestAllTypesProto3`
in protobuf binary (base64) or proto3 JSON, read with the generated decoders
and written back in the format asked for, answered on `responses`. Other
message types (proto2, editions) and other formats (JSPB, text) are
answered `skipped`.
-}

import Json.Decode
import Json.Encode
import Proto.Binary
import Proto.Bytes
import ProtobufTestMessages.Proto3 as Proto3


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

    else if request.outputFormat /= "protobuf" && request.outputFormat /= "json" then
        reply "skipped" ("output format " ++ request.outputFormat)

    else
        case read request of
            Err ( kind, problem ) ->
                reply kind problem

            Ok message ->
                if request.outputFormat == "protobuf" then
                    reply "protobuf" (Proto.Bytes.toBase64 (Proto.Binary.encode Proto3.encodeTestAllTypesProto3Bytes message))

                else
                    reply "json" (Json.Encode.encode 0 (Proto3.encodeTestAllTypesProto3 message))


read : Request -> Result ( String, String ) Proto3.TestAllTypesProto3
read request =
    case request.inputFormat of
        "protobuf" ->
            Proto.Bytes.fromBase64 request.payload
                |> Maybe.andThen (Proto.Binary.decode Proto3.decodeTestAllTypesProto3Bytes)
                |> Result.fromMaybe ( "parseError", "not a TestAllTypesProto3 in protobuf binary" )

        "json" ->
            Json.Decode.decodeString Proto3.decodeTestAllTypesProto3 request.payload
                |> Result.mapError (\problem -> ( "parseError", Json.Decode.errorToString problem ))

        other ->
            Err ( "skipped", "input format " ++ other )
