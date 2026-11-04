"""Write M4d's Details.elm: the two google.rpc.Status bodies the live
suite's six transcoded cases read (an ErrorInfo detail, a BadRequest
detail; reconstructed from the cases' expectations), each read as a
transcoded call's failed answer by `Rpc.response`, then unpacked through
the generated typed values with `Rpc.Error.details`. CLIENTS names the
clients: `plain` (no client table, as the live runner had) and, on a
runtime with `Proto.Registry.lenient`, `lenient` (lenient empty table) and
`lenientNotes` (the notes package's table, lenient).

    python3 spike/m4/details.py OUT.elm plain[,lenient,lenientNotes]

The program prints one line per client and body on the port `done`.
"""
import sys

out, clients = sys.argv[1], sys.argv[2].split(',')
table = {
    'plain': 'base',
    'lenient': 'base |> Rpc.withRegistry (Proto.Registry.lenient Proto.Registry.empty)',
    'lenientNotes': 'base |> Rpc.withRegistry (Proto.Registry.lenient Notes.V1.registry)',
}
client_list = ',\n      '.join(f'( "{c}", {table[c]} )' for c in clients)
src = f'''port module Details exposing (main)

import Dict
import Google.Rpc
import Http
import Json.Decode
import Json.Encode
import Notes.V1
import Proto.Any
import Proto.Json
import Proto.Method
import Proto.Registry
import Rpc
import Rpc.Error
import Rpc.Protocol


port done : String -> Cmd msg


base : Rpc.Client Rpc.Json
base =
    Rpc.client Rpc.Protocol.transcode "https://api.example.com"


call : Rpc.Call Rpc.Json () ()
call =
    Rpc.call (Proto.Method.initJson "notes.v1.NotesService" "GetNote" Proto.Registry.empty (\\_ -> Ok << Proto.Json.encodeEmpty) (\\_ -> Json.Decode.succeed ())) ()


bodies : List ( String, String )
bodies =
    [ ( "ErrorInfo", """{{"code":5,"message":"notes/from-transcode does not exist","details":[{{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"NOTE_NOT_FOUND","domain":"notes.example.com","metadata":{{"name":"notes/from-transcode"}}}}]}}""" )
    , ( "BadRequest", """{{"code":3,"message":"a note needs a title","details":[{{"@type":"type.googleapis.com/google.rpc.BadRequest","fieldViolations":[{{"field":"title","description":"a note needs a title"}}]}}]}}""" )
    ]


answer : String -> Http.Response String
answer body =
    Http.BadStatus_ {{ url = "https://api.example.com/v1/notes/x", statusCode = 404, statusText = "", headers = Dict.fromList [ ( "content-type", "application/json" ) ] }} body


report : ( String, Rpc.Client Rpc.Json ) -> ( String, String ) -> String
report ( clientName, client ) ( bodyName, body ) =
    case Rpc.response client call (answer body) of
        Err error ->
            let
                held =
                    case error of
                        Rpc.Error.RpcStatus status _ ->
                            List.map (\\d -> Proto.Any.typeName d) status.details |> String.join ","

                        _ ->
                            "not a status"

                errorInfo =
                    Rpc.Error.details Google.Rpc.messageErrorInfo error
                        |> List.map (\\e -> e.reason ++ "/" ++ e.domain ++ "/" ++ String.join "," (Dict.values e.metadata))

                badRequest =
                    Rpc.Error.details Google.Rpc.messageBadRequest error
                        |> List.map (\\b -> String.join "," (List.map (\\v -> v.field ++ ":" ++ v.description) b.fieldViolations))
            in
            clientName ++ " " ++ bodyName ++ ": code=" ++ Rpc.Error.message error ++ " details=[" ++ held ++ "] errorInfo=" ++ Json.Encode.encode 0 (Json.Encode.list Json.Encode.string errorInfo) ++ " badRequest=" ++ Json.Encode.encode 0 (Json.Encode.list Json.Encode.string badRequest)

        Ok _ ->
            clientName ++ " " ++ bodyName ++ ": read as a success"


main : Program () () ()
main =
    Platform.worker
        {{ init =
            \\_ ->
                ( ()
                , done
                    (String.join "\\n"
                        (List.concatMap (\\c -> List.map (report c) bodies)
                            [ {client_list}
                            ]
                        )
                    )
                )
        , update = \\_ m -> ( m, Cmd.none )
        , subscriptions = \\_ -> Sub.none
        }}
'''
open(out, 'w').write(src)
