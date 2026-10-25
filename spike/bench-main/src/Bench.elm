port module Bench exposing (main)

{-| Timing harness: `init` runs one task `n` times and reports a checksum, so
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
import Maps.V1
import Nesting.V1
import Notes.V1
import Notes.V1.NotesService as Notes
import Oneofs.V1
import Proto.Json
import Proto.Timestamp
import Rpc
import Rpc.Body
import Rpc.Call
import Rpc.Code
import Rpc.Error
import Rpc.Transport
import Scalars.V1
import WellKnown.V1


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


notesJson : Int -> String
notesJson count =
    "{\"notes\":["
        ++ String.join ","
            (List.map
                (\i -> "{\"name\":\"notes/" ++ String.fromInt i ++ "\",\"title\":\"Note " ++ String.fromInt i ++ "\",\"createTime\":\"2026-10-25T12:34:56Z\"}")
                (List.range 1 count)
            )
        ++ "],\"nextPageToken\":\"next\"}"


notes1000Json : String
notes1000Json =
    notesJson 1000


scalarsJson : String
scalarsJson =
    """{"doubleValue":1.5,"floatValue":2.25,"int32Value":-42,"int64Value":"-9007199254740993","uint32Value":4000000000,"uint64Value":"18446744073709551615","sint32Value":-7,"sint64Value":"-123456789012","fixed32Value":7,"fixed64Value":"77","sfixed32Value":-8,"sfixed64Value":"-88","boolValue":true,"text":"hello","bytesValue":"aGVsbG8gd29ybGQ=","smallCount":"12345","exactTotal":"98765432109876"}"""


scalarsSnakeJson : String
scalarsSnakeJson =
    """{"double_value":1.5,"float_value":2.25,"int32_value":-42,"int64_value":"-9007199254740993","uint32_value":4000000000,"uint64_value":"18446744073709551615","sint32_value":-7,"sint64_value":"-123456789012","fixed32_value":7,"fixed64_value":"77","sfixed32_value":-8,"sfixed64_value":"-88","bool_value":true,"string_value":"hello","bytes_value":"aGVsbG8gd29ybGQ=","small_count":"12345","exact_total":"98765432109876"}"""


entries : Int -> (Int -> String) -> (Int -> String) -> String
entries count key value =
    "{" ++ String.join "," (List.map (\i -> "\"" ++ key i ++ "\":" ++ value i) (List.range 1 count)) ++ "}"


teamJson : String
teamJson =
    "{\"labels\":"
        ++ entries 20 (\i -> "label" ++ String.fromInt i) (\i -> "\"v" ++ String.fromInt i ++ "\"")
        ++ ",\"bySeat\":"
        ++ entries 20 String.fromInt (\i -> "\"seat" ++ String.fromInt i ++ "\"")
        ++ ",\"byId\":"
        ++ entries 20 (\i -> String.fromInt (i * 1000000007)) (\i -> "\"id" ++ String.fromInt i ++ "\"")
        ++ ",\"members\":"
        ++ entries 20 (\i -> "m" ++ String.fromInt i) (\i -> "{\"name\":\"member " ++ String.fromInt i ++ "\"}")
        ++ ",\"roles\":"
        ++ entries 20 String.fromInt (\_ -> "\"ROLE_OWNER\"")
        ++ ",\"byFlag\":{\"true\":\"yes\",\"false\":\"no\"}}"


labels1000Json : String
labels1000Json =
    "{\"labels\":" ++ entries 1000 (\i -> "label" ++ String.fromInt i) (\i -> "\"v" ++ String.fromInt i ++ "\"") ++ "}"


eventJson : String
eventJson =
    """{"createdAt":"2026-10-25T12:34:56.789Z","timeout":"1.500s","updateMask":"title,body,metadata.source","metadata":{"a":1,"b":"two","c":[true,null]},"payload":{"x":1},"ratio":0.5,"bigCount":"9007199254740993","count":7,"enabled":true,"nickname":"nick","history":["2026-01-01T00:00:00Z","2026-02-01T00:00:00Z","2026-03-01T00:00:00.5Z","2026-04-01T00:00:00Z","2026-05-01T00:00:00+02:00"],"limits":{"read":"1s","write":"2.5s"},"counts":[1,2,3],"at":"2026-10-25T12:00:00Z"}"""


noteEventJson : String
noteEventJson =
    """{"id":"evt-1","titleChanged":"New title","user":"ada","tags":["a","b"]}"""


nodeJson : Int -> Int -> String
nodeJson depth width =
    if depth <= 0 then
        "{\"label\":\"leaf\"}"

    else
        "{\"label\":\"n"
            ++ String.fromInt depth
            ++ "\",\"children\":["
            ++ String.join "," (List.repeat width (nodeJson (depth - 1) width))
            ++ "]}"


forestJson : String
forestJson =
    -- 3 trees of 1 + 3 + 9 + 27 = 40 nodes
    "{\"trees\":[" ++ String.join "," (List.repeat 3 (nodeJson 3 3)) ++ "]}"


timestampJson : String
timestampJson =
    "\"2026-10-25T12:34:56.789Z\""


int64Json : String
int64Json =
    "\"-9007199254740993\""


decodeOr : D.Decoder a -> a -> String -> a
decodeOr decoder default json =
    D.decodeString decoder json |> Result.withDefault default


decoded : String -> D.Decoder a -> String -> Int
decoded _ decoder json =
    case D.decodeString decoder json of
        Ok _ ->
            1

        Err _ ->
            1000000


{-| A plain elm/json decoder of a note's fields, the baseline the generated
decoder is compared with: no spelling, presence or array checks.
-}
plainNote : D.Decoder ( String, String, List String )
plainNote =
    D.map3 (\a b c -> ( a, b, c ))
        (D.oneOf [ D.field "name" D.string, D.succeed "" ])
        (D.oneOf [ D.field "title" D.string, D.succeed "" ])
        (D.oneOf [ D.field "tags" (D.list D.string), D.succeed [] ])


plainNotes : D.Decoder (List ( String, String, String ))
plainNotes =
    D.field "notes"
        (D.list
            (D.map3 (\a b c -> ( a, b, c ))
                (D.oneOf [ D.field "name" D.string, D.succeed "" ])
                (D.oneOf [ D.field "title" D.string, D.succeed "" ])
                (D.oneOf [ D.field "createTime" D.string, D.succeed "" ])
            )
        )


team : Maps.V1.Team
team =
    decodeOr Maps.V1.decodeTeam Maps.V1.defaultTeam teamJson


scalars : Scalars.V1.Scalars
scalars =
    decodeOr Scalars.V1.decodeScalars Scalars.V1.defaultScalars scalarsJson


event : WellKnown.V1.Event
event =
    decodeOr WellKnown.V1.decodeEvent WellKnown.V1.defaultEvent eventJson


noteEvent : Oneofs.V1.NoteEvent
noteEvent =
    decodeOr Oneofs.V1.decodeNoteEvent Oneofs.V1.defaultNoteEvent noteEventJson


forest : Nesting.V1.Forest
forest =
    decodeOr Nesting.V1.decodeForest Nesting.V1.defaultForest forestJson


notes1000 : Notes.V1.ListNotesResponse
notes1000 =
    decodeOr Notes.V1.decodeListNotesResponse Notes.V1.defaultListNotesResponse notes1000Json


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

        -- the JSON codecs
        , ( "json.note.decode", \_ -> decoded "note" Notes.V1.decodeNote noteJson )
        , ( "json.note.plain", \_ -> decoded "note" plainNote noteJson )
        , ( "json.note.encode", \_ -> encoded (Notes.V1.encodeNote note) )
        , ( "json.scalars.decode", \_ -> decoded "scalars" Scalars.V1.decodeScalars scalarsJson )
        , ( "json.scalars.decodeSnake", \_ -> decoded "scalars" Scalars.V1.decodeScalars scalarsSnakeJson )
        , ( "json.scalars.decodeEmpty", \_ -> decoded "scalars" Scalars.V1.decodeScalars "{}" )
        , ( "json.scalars.encode", \_ -> encoded (Scalars.V1.encodeScalars scalars) )
        , ( "json.team.decode", \_ -> decoded "team" Maps.V1.decodeTeam teamJson )
        , ( "json.team.encode", \_ -> encoded (Maps.V1.encodeTeam team) )
        , ( "json.labels1000.decode", \_ -> decoded "labels" Maps.V1.decodeTeam labels1000Json )
        , ( "json.labels1000.plain", \_ -> decoded "labels" (D.field "labels" (D.dict D.string)) labels1000Json )
        , ( "json.event.decode", \_ -> decoded "event" WellKnown.V1.decodeEvent eventJson )
        , ( "json.event.encode", \_ -> encoded (WellKnown.V1.encodeEvent event) )
        , ( "json.noteEvent.decode", \_ -> decoded "noteEvent" Oneofs.V1.decodeNoteEvent noteEventJson )
        , ( "json.noteEvent.encode", \_ -> encoded (Oneofs.V1.encodeNoteEvent noteEvent) )
        , ( "json.forest.decode", \_ -> decoded "forest" Nesting.V1.decodeForest forestJson )
        , ( "json.forest.encode", \_ -> encoded (Nesting.V1.encodeForest forest) )
        , ( "json.notes1000.decode", \_ -> decoded "notes" Notes.V1.decodeListNotesResponse notes1000Json )
        , ( "json.notes1000.plain", \_ -> decoded "notes" plainNotes notes1000Json )
        , ( "json.notes1000.encode", \_ -> encoded (Notes.V1.encodeListNotesResponse notes1000) )
        , ( "json.timestamp.decode", \_ -> decoded "ts" Proto.Json.timestamp timestampJson )
        , ( "json.timestamp.fromString", \_ -> Proto.Timestamp.fromString "2026-10-25T12:34:56.789Z" |> Maybe.map (always 1) |> Maybe.withDefault 0 )
        , ( "json.int64.decode", \_ -> decoded "int64" Proto.Json.int64 int64Json )
        , ( "json.parse.note", \_ -> decoded "note" D.value noteJson )
        , ( "json.parse.notes1000", \_ -> decoded "notes" D.value notes1000Json )
        ]


{-| 0 when every fixture decodes as intended, else a count of the ones that
did not: a guard that the timed tasks time success paths.
-}
checks : Int
checks =
    List.length
        (List.filter not
            [ note.title == "Groceries" && note.revision == Just "12345678901234"
            , scalars.stringValue == "hello" && scalars.int64Value == "-9007199254740993"
            , Dict.size team.labels == 20 && Dict.size team.members == 20 && Dict.size team.byId == 20
            , event.nickname == Just "nick" && List.length event.history == 5
            , noteEvent.id == "evt-1"
            , List.length forest.trees == 3
            , List.length notes1000.notes == 1000
            , List.length errors == 5
            , decoded "" Scalars.V1.decodeScalars scalarsSnakeJson == 1
            , decoded "" Maps.V1.decodeTeam labels1000Json == 1
            ]
        )
