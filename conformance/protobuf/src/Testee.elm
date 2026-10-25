port module Testee exposing (main)

{-| The protobuf conformance suite's testee, for `conformance_test_runner`
(protocolbuffers/protobuf `conformance/`), driven by `testee.mjs`: each
request on `requests` is a `protobuf_test_messages.proto3.TestAllTypesProto3`,
a `protobuf_test_messages.editions.TestAllTypesEdition2023` or the proto3
message written in edition 2023
(`protobuf_test_messages.editions.proto3.TestAllTypesProto3`) in protobuf
binary (base64) or JSON, read with the generated decoders and written back in
the format asked for, answered on `responses`. Other message types (proto2,
and proto2 written as editions) and other formats (JSPB, text) are answered
`skipped`.
-}

import Bytes.Encode
import Json.Decode
import Json.Encode
import Proto.Binary
import Proto.Bytes
import ProtobufTestMessages.Editions as Editions
import ProtobufTestMessages.Editions.Proto3 as EditionsProto3
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
    case request.messageType of
        "protobuf_test_messages.proto3.TestAllTypesProto3" ->
            roundTrip proto3 request

        "protobuf_test_messages.editions.TestAllTypesEdition2023" ->
            roundTrip edition2023 request

        "protobuf_test_messages.editions.proto3.TestAllTypesProto3" ->
            roundTrip proto3Editions request

        other ->
            { id = request.id, kind = "skipped", payload = "message type " ++ other }


{-| A message's generated codecs, JSON and binary.
-}
type alias Codecs a =
    { decodeJson : Json.Decode.Decoder a
    , encodeJson : a -> Json.Encode.Value
    , decodeBytes : Proto.Binary.Decoder a
    , encodeBytes : a -> Bytes.Encode.Encoder
    }


proto3 : Codecs Proto3.TestAllTypesProto3
proto3 =
    { decodeJson = Proto3.decodeTestAllTypesProto3
    , encodeJson = Proto3.encodeTestAllTypesProto3
    , decodeBytes = Proto3.decodeTestAllTypesProto3Bytes
    , encodeBytes = Proto3.encodeTestAllTypesProto3Bytes
    }


{-| The edition 2023 message, generated from the subset
`spike/protobuf-conformance/strip-editions.sh` leaves.
-}
edition2023 : Codecs Editions.TestAllTypesEdition2023
edition2023 =
    { decodeJson = Editions.decodeTestAllTypesEdition2023
    , encodeJson = Editions.encodeTestAllTypesEdition2023
    , decodeBytes = Editions.decodeTestAllTypesEdition2023Bytes
    , encodeBytes = Editions.encodeTestAllTypesEdition2023Bytes
    }


{-| proto3's test message written in edition 2023, generated from the subset
`spike/protobuf-conformance/strip-editions.sh` leaves.
-}
proto3Editions : Codecs EditionsProto3.TestAllTypesProto3
proto3Editions =
    { decodeJson = EditionsProto3.decodeTestAllTypesProto3
    , encodeJson = EditionsProto3.encodeTestAllTypesProto3
    , decodeBytes = EditionsProto3.decodeTestAllTypesProto3Bytes
    , encodeBytes = EditionsProto3.encodeTestAllTypesProto3Bytes
    }


roundTrip : Codecs a -> Request -> { id : Int, kind : String, payload : String }
roundTrip codecs request =
    let
        reply kind payload =
            { id = request.id, kind = kind, payload = payload }
    in
    if request.outputFormat /= "protobuf" && request.outputFormat /= "json" then
        reply "skipped" ("output format " ++ request.outputFormat)

    else
        case read codecs request of
            Err ( kind, problem ) ->
                reply kind problem

            Ok message ->
                if request.outputFormat == "protobuf" then
                    reply "protobuf" (Proto.Bytes.toBase64 (Proto.Binary.encode codecs.encodeBytes message))

                else
                    reply "json" (Json.Encode.encode 0 (codecs.encodeJson message))


read : Codecs a -> Request -> Result ( String, String ) a
read codecs request =
    case request.inputFormat of
        "protobuf" ->
            Proto.Bytes.fromBase64 request.payload
                |> Maybe.andThen (Proto.Binary.decode codecs.decodeBytes)
                |> Result.fromMaybe ( "parseError", "not a " ++ request.messageType ++ " in protobuf binary" )

        "json" ->
            Json.Decode.decodeString codecs.decodeJson request.payload
                |> Result.mapError (\problem -> ( "parseError", Json.Decode.errorToString problem ))

        other ->
            Err ( "skipped", "input format " ++ other )
