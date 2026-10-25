port module Testee exposing (main)

{-| The protobuf conformance suite's testee, for `conformance_test_runner`
(protocolbuffers/protobuf `conformance/`), driven by `testee.mjs`: each
request on `requests` is a `protobuf_test_messages.proto3.TestAllTypesProto3`
in proto3 JSON, read with the generated decoder and written back with the
generated encoder, answered on `responses`.

The runtime has proto3 JSON codecs only, so a request whose input or output
is protobuf binary is answered `skipped` without being read, as are the
other formats (JSPB, text) and the other message types (proto2, editions).
The answer dispatches on the output format and `read` on the input format,
so that binary branches can sit beside the JSON ones.

-}

import Json.Decode
import Json.Encode
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

    else
        case request.outputFormat of
            "json" ->
                case read request of
                    Err ( kind, problem ) ->
                        reply kind problem

                    Ok message ->
                        reply "json" (Json.Encode.encode 0 (Proto3.encodeTestAllTypesProto3 message))

            other ->
                reply "skipped" ("output format " ++ other)


read : Request -> Result ( String, String ) Proto3.TestAllTypesProto3
read request =
    case request.inputFormat of
        "json" ->
            Json.Decode.decodeString Proto3.decodeTestAllTypesProto3 request.payload
                |> Result.mapError (\problem -> ( "parseError", Json.Decode.errorToString problem ))

        other ->
            Err ( "skipped", "input format " ++ other )
