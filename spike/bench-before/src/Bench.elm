port module Bench exposing (main)

{-| The Rpc tasks of the perf-size spike's timing harness, before the
interface reshape (the stack head's API). spike/bench-b holds the same tasks
over the reshaped API; bench-perf.js times the two interleaved and checks
their checksums agree.

Timing harness: `init` runs one task `n` times and reports a checksum, so
the time around `init` is the time of `n` runs of the task plus a fixed
setup, which a run with `n = 0` measures (spike/bench-perf.js subtracts it).
Fixtures are top-level values, built when the program loads, outside the
timed `init`.
-}

import Connectrpc.Eliza.V1.ElizaService as Eliza
import Dict exposing (Dict)
import Http
import Json.Decode as D
import Json.Encode as E
import Notes.V1
import Notes.V1.NotesService as Notes
import Rpc
import Rpc.Body
import Rpc.Call
import Rpc.Code
import Rpc.Error
import Rpc.Transport


port done : String -> Cmd msg


main : Program { task : String, n : Int } () ()
main =
    Platform.worker
        { init = \flags -> ( (), done (run flags.task flags.n) )
        , update = \_ model -> ( model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }


{-| Run `step` for i = n down to 1, summing what it gives.
-}
loop : Int -> (Int -> Int) -> Int -> Int
loop n step acc =
    if n <= 0 then
        acc

    else
        loop (n - 1) step (acc + step n)


run : String -> Int -> String
run task n =
    case Dict.get task tasks of
        Just step ->
            String.fromInt (loop n step 0)

        Nothing ->
            "unknown task " ++ task



-- CONFIGS AND CALLS


connectCfg : Rpc.Config
connectCfg =
    Rpc.config "https://api.example.com"


getCfg : Rpc.Config
getCfg =
    { connectCfg | transport = Rpc.Transport.connectGet }


transcodeCfg : Rpc.Config
transcodeCfg =
    { connectCfg | transport = Rpc.Transport.transcode }


headersCfg : Rpc.Config
headersCfg =
    { connectCfg
        | headers =
            [ ( "Authorization", "Bearer abcdefghijklmnopqrstuvwxyz0123456789" )
            , ( "X-Request-Id", "5f0c2d8e-3b7a-4a59-9d1e-0c6b2a8f7e41" )
            , ( "X-Client", "bench/1.0" )
            , ( "Accept-Language", "en-US" )
            ]
        , timeout = Just 5000
    }


say : Rpc.Call { sentence : String } { sentence : String }
say =
    Eliza.say { sentence = "Hello, how are you feeling today?" }


sayWithHeaders : Rpc.Call { sentence : String } { sentence : String }
sayWithHeaders =
    say
        |> Rpc.Call.withHeaders [ ( "X-Trace", "abc123" ), ( "X-Feature", "on" ) ]
        |> Rpc.Call.withTimeout 2000


note : Notes.V1.Note
note =
    D.decodeString Notes.V1.decodeNote noteJson |> Result.withDefault Notes.V1.defaultNote


createNote : Rpc.Call Notes.V1.CreateNoteRequest Notes.V1.Note
createNote =
    Notes.createNote { note = Just note }


{-| A note of 1,000 tags, about 12 KB of JSON: how the request path scales.
-}
bigNote : Rpc.Call Notes.V1.CreateNoteRequest Notes.V1.Note
bigNote =
    Notes.createNote { note = Just { note | tags = List.map (\i -> "tag-" ++ String.fromInt i) (List.range 1 1000) } }


getNote : Rpc.Call Notes.V1.GetNoteRequest Notes.V1.Note
getNote =
    Notes.getNote { name = "notes/42" }


listNotes : Rpc.Call Notes.V1.ListNotesRequest Notes.V1.ListNotesResponse
listNotes =
    Notes.listNotes { pageSize = 10, pageToken = "abc", filter = "tag:home", visibility = Notes.V1.VisibilityPrivate }


ignore : a -> b -> ()
ignore _ _ =
    ()


requestSize : Rpc.Request -> Int
requestSize request =
    String.length request.url + List.length request.headers + (Rpc.Body.toText request.body |> Maybe.map String.length |> Maybe.withDefault 0)


resultSize : Result Rpc.Error a -> Int
resultSize result =
    case result of
        Ok _ ->
            1

        Err error ->
            Rpc.Code.toInt (Rpc.Error.code error) + 2



-- ANSWERS


metadata : Int -> List ( String, String ) -> Http.Metadata
metadata status extra =
    { url = "https://api.example.com/notes.v1.NotesService/GetNote"
    , statusCode = status
    , statusText = ""
    , headers =
        Dict.fromList
            ([ ( "content-type", "application/json" )
             , ( "date", "Sun, 25 Oct 2026 12:00:00 GMT" )
             , ( "server", "bench" )
             , ( "vary", "Origin" )
             , ( "content-length", "123" )
             ]
                ++ extra
            )
    }


sayAnswer : Http.Response String
sayAnswer =
    Http.GoodStatus_ (metadata 200 []) "{\"sentence\":\"I see. And how does that make you feel?\"}"


noteAnswer : Http.Response String
noteAnswer =
    Http.GoodStatus_ (metadata 200 []) noteJson


connectError : Http.Response String
connectError =
    Http.BadStatus_ (metadata 404 []) "{\"code\":\"not_found\",\"message\":\"no such note: notes/42\"}"


connectErrorDetails : Http.Response String
connectErrorDetails =
    Http.BadStatus_ (metadata 400 [])
        "{\"code\":\"invalid_argument\",\"message\":\"title is required\",\"details\":[{\"type\":\"google.rpc.BadRequest\",\"value\":\"CgcKBXRpdGxl\",\"debug\":{\"fieldViolations\":[{\"field\":\"title\",\"description\":\"required\"}]}},{\"type\":\"google.rpc.ErrorInfo\",\"value\":\"CghSRVFVSVJFRA==\"}]}"


statusError : Http.Response String
statusError =
    Http.BadStatus_ (metadata 400 [])
        "{\"code\":3,\"message\":\"title is required\",\"details\":[{\"@type\":\"type.googleapis.com/google.rpc.BadRequest\",\"fieldViolations\":[{\"field\":\"title\",\"description\":\"required\"}]}]}"


grpcError : Http.Response String
grpcError =
    Http.BadStatus_ (metadata 503 [ ( "grpc-status", "14" ), ( "grpc-message", "upstream%20unavailable%2C%20try%20later" ) ]) ""


httpError : Http.Response String
httpError =
    Http.BadStatus_ (metadata 502 []) "<html><body><h1>502 Bad Gateway</h1></body></html>"


errors : List Rpc.Error
errors =
    [ connectError, connectErrorDetails, statusError, grpcError, httpError ]
        |> List.filterMap
            (\answer ->
                case Rpc.response connectCfg getNote answer of
                    Err error ->
                        Just error

                    Ok _ ->
                        Nothing
            )


responseHeaders : Dict String String
responseHeaders =
    Dict.fromList
        [ ( "Content-Type", "application/json" )
        , ( "Date", "Sun, 25 Oct 2026 12:00:00 GMT" )
        , ( "Server", "bench" )
        , ( "Vary", "Origin" )
        , ( "Content-Length", "123" )
        , ( "Trailer-X-Custom", "done" )
        , ( "Trailer-Grpc-Status", "0" )
        , ( "X-Request-Id", "5f0c2d8e" )
        ]



-- JSON PAYLOADS


noteJson : String
noteJson =
    """{"name":"notes/42","title":"Groceries","body":"Milk, eggs and bread for the week.","tags":["home","list","weekly"],"visibility":"VISIBILITY_PRIVATE","createTime":"2026-10-25T12:34:56.789Z","updateTime":"2026-10-25T13:00:00Z","ttl":"3600s","metadata":{"source":"web","lang":"en"},"revision":"12345678901234","text":"plain"}"""


encoded : E.Value -> Int
encoded value =
    String.length (E.encode 0 value)



-- TASKS


tasks : Dict String (Int -> Int)
tasks =
    Dict.fromList
        [ ( "check", \_ -> checks )

        -- the request path
        , ( "request.connect.say", \_ -> requestSize (Rpc.request connectCfg say) )
        , ( "request.connect.note", \_ -> requestSize (Rpc.request connectCfg createNote) )
        , ( "request.connect.headers", \_ -> requestSize (Rpc.request headersCfg sayWithHeaders) )
        , ( "request.connectGet.say", \_ -> requestSize (Rpc.request getCfg say) )
        , ( "request.transcode.get", \_ -> requestSize (Rpc.request transcodeCfg getNote) )
        , ( "request.transcode.list", \_ -> requestSize (Rpc.request transcodeCfg listNotes) )
        , ( "request.transcode.create", \_ -> requestSize (Rpc.request transcodeCfg createNote) )
        , ( "request.connect.tags1000", \_ -> requestSize (Rpc.request connectCfg bigNote) )
        , ( "call.build", \i -> Rpc.Call.methodName (Eliza.say { sentence = "Hello" }) |> String.length |> (+) i )
        , ( "send.connect.say", \_ -> always 1 (Rpc.send connectCfg (ignore ()) say) )
        , ( "send.connect.headers", \_ -> always 1 (Rpc.send headersCfg (ignore ()) sayWithHeaders) )
        , ( "send.connectGet.say", \_ -> always 1 (Rpc.send getCfg (ignore ()) say) )
        , ( "send.connect.tags1000", \_ -> always 1 (Rpc.send connectCfg (ignore ()) bigNote) )
        , ( "send.connect.note", \_ -> always 1 (Rpc.send connectCfg (ignore ()) createNote) )
        , ( "send.transcode.create", \_ -> always 1 (Rpc.send transcodeCfg (ignore ()) createNote) )
        , ( "encode.say", \_ -> encoded (Rpc.Call.requestJson say) )
        , ( "encode.createNote", \_ -> encoded (Rpc.Call.requestJson createNote) )
        , ( "encode.tags1000", \_ -> encoded (Rpc.Call.requestJson bigNote) )

        -- the answer path
        , ( "answer.ok.say", \_ -> resultSize (Rpc.response connectCfg say sayAnswer) )
        , ( "answer.ok.note", \_ -> resultSize (Rpc.response connectCfg getNote noteAnswer) )
        , ( "answer.ok.note.transcode", \_ -> resultSize (Rpc.response transcodeCfg getNote noteAnswer) )
        , ( "answer.connectError", \_ -> resultSize (Rpc.response connectCfg getNote connectError) )
        , ( "answer.connectErrorDetails", \_ -> resultSize (Rpc.response connectCfg getNote connectErrorDetails) )
        , ( "answer.statusError", \_ -> resultSize (Rpc.response connectCfg getNote statusError) )
        , ( "answer.grpcError", \_ -> resultSize (Rpc.response connectCfg getNote grpcError) )
        , ( "answer.httpError", \_ -> resultSize (Rpc.response connectCfg getNote httpError) )
        , ( "error.toString", \_ -> List.foldl (\e acc -> acc + String.length (Rpc.Error.toString e)) 0 errors )
        , ( "headers.splitTrailers", \_ -> Dict.size (Rpc.splitTrailers responseHeaders).trailers )

        ]


{-| 0 when every fixture decodes as intended, else a count of the ones that
did not: a guard that the timed tasks time success paths.
-}
checks : Int
checks =
    List.length
        (List.filter not
            [ note.title == "Groceries" && note.revision == Just "12345678901234"

            , List.length errors == 5
            ]
        )
