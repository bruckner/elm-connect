module Live.Call exposing (Calls, Client(..), Entry, Envelope, Outcome, Protocol(..), Respond, Sending(..), Sent, detailWith, entryWith)

{-| What the live runner sends: an envelope read from JSON, and an entry of a
dispatch table, which turns one into a sent call and its result into JSON.

A dispatch table (`Live.Notes.table`) lists one entry per method, each built by
`Live.Codec.entry` from the generated call function and the codecs the runner
needs beyond it: the request's decoder, since the envelope holds the request as
proto3 JSON, and the response's message, whose encoder the result reports it
with (as JSON, and as protobuf binary too when the message has binary codecs).

A call carries its codec in its type, so an entry holds the call function once
per codec the bindings have it in ([`Calls`](#Calls)): bindings generated with
`wire=both`, as the runner's are, have both, and `Live.Codec` takes each
generated call function at each codec.

-}

import Dict
import Http
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode exposing (Value)
import Proto.Any
import Proto.Binary
import Proto.Bytes
import Proto.Error
import Proto.ErrorDetails
import Proto.Json
import Proto.Message exposing (Message)
import Proto.Registry
import Rpc
import Rpc.Body
import Rpc.Call
import Rpc.Client
import Rpc.Code
import Rpc.Error
import Rpc.Trace
import Task


{-| One call to make: the method, its request as proto3 JSON, the protocol,
the client, the binding, if one is chosen, the call's own headers, the
headers `FromRequest` rewrites, and the milliseconds after which to cancel
it, if it is to be.
-}
type alias Envelope =
    { id : String
    , service : String
    , method : String
    , request : Value
    , protocol : Protocol
    , client : Client
    , binding : Maybe Int
    , headers : List ( String, String )
    , rewrite : List ( String, String )
    , sending : Sending
    , tracker : Maybe String
    , cancelAfter : Maybe Int
    }


{-| Which of the runtime's ways of sending a call to use. `Halves` sends
through the pure halves, as an application that needs the whole answer does:
`Rpc.request`, `Http.request` with the answer kept whole, and `Rpc.response`.
`Traced` gives the answer's status, headers and trailers in the trace.
`FromRequest` builds the request with `Rpc.request`, rewrites it and sends
it with `Rpc.taskFromRequest`, as an application refreshing a token does.
-}
type Sending
    = Traced
    | Plain
    | AsTask
    | Halves
    | FromRequest


{-| The protocol a call goes over, as the envelope names it.
-}
type Protocol
    = Connect
    | Transcode
    | GrpcWeb


{-| The client an envelope's `config` describes, by the codec it names.
-}
type Client
    = JsonClient (Rpc.Client Rpc.Json)
    | ProtoClient (Rpc.Client Rpc.Proto)


{-| A method's generated call function, once per codec the bindings have it in.
-}
type alias Calls req res =
    { json : Maybe (req -> Rpc.Call Rpc.Json req res)
    , proto : Maybe (req -> Rpc.Call Rpc.Proto req res)
    }


{-| How a dispatch table sends an envelope's call: `Err` with a reason when
the request does not decode, the binding does not exist or the call cannot be
cancelled as asked, or the commands that send it and cancel it.
-}
type alias Entry msg =
    Envelope -> (Outcome -> msg) -> Result String (Sent msg)


{-| A call's commands: `send` sends it and reports the outcome; `cancel`, for
an envelope with `cancelAfter`, cancels it with `Rpc.cancel`, which reports
nothing, and reports `{"canceled": true}` itself, as an application records
that it withdrew a call. The caller reports whichever outcome comes first.
-}
type alias Sent msg =
    { send : Cmd msg, cancel : Maybe (Cmd msg) }


{-| What became of a call, as JSON: the result, the trace when the call was
sent with `Rpc.sendTraced` (`Rpc.Trace.toJson`; `null` otherwise), and the answer's status and
headers when it was sent through the halves and an answer came (`null`
otherwise).
-}
type alias Outcome =
    { id : String, result : Value, trace : Value, response : Value }


{-| How a result is written: a response as the result's fields, its proto3
JSON under `ok`, and its protobuf binary as base64 under `okBinary` when the
call can go over binary; and an error's detail as proto3 JSON. `Live.Codec`
writes them through the runner's registry.
-}
type alias Respond res =
    { response : res -> List ( String, Value )
    , detail : Result Proto.Error.Error Proto.Any.Any -> Value
    }


{-| The entry for a method, from its generated call functions, its request's
decoder and how its response is written. An envelope whose codec the entry
has no call function in is refused.
-}
entryWith : Calls req res -> Decoder req -> Respond res -> Entry msg
entryWith calls requestDecoder respond envelope toMsg =
    case Decode.decodeValue requestDecoder envelope.request of
        Err problem ->
            Err ("the request does not decode: " ++ Decode.errorToString problem)

        Ok request ->
            let
                missing codec =
                    Err ("this entry has no " ++ codec ++ " codecs for " ++ envelope.service ++ "/" ++ envelope.method)
            in
            case envelope.client of
                JsonClient client ->
                    case calls.json of
                        Just toCall ->
                            prepare (viaBinding envelope) envelope (toCall request)
                                |> Result.andThen
                                    (sendWith client
                                        (\c deliver -> Http.expectStringResponse deliver (\answer -> Ok ( encodeAnswer answer, Rpc.response client c answer )))
                                        envelope
                                        respond
                                        toMsg
                                    )

                        Nothing ->
                            missing "proto3 JSON"

                ProtoClient client ->
                    case calls.proto of
                        Just toCall ->
                            prepare (\_ _ -> Err "a binding is chosen on a call over JSON") envelope (toCall request)
                                |> Result.andThen
                                    (sendWith client
                                        (\c deliver -> Http.expectBytesResponse deliver (\answer -> Ok ( encodeAnswer answer, Rpc.responseBytes client c answer )))
                                        envelope
                                        respond
                                        toMsg
                                    )

                        Nothing ->
                            missing "protobuf binary"


{-| A call with the envelope's headers, over its binding when it names one,
which `via` takes: transcoding's bindings are JSON's, so a binary call has
none.
-}
prepare : (Int -> Rpc.Call codec req res -> Result String (Rpc.Call codec req res)) -> Envelope -> Rpc.Call codec req res -> Result String (Rpc.Call codec req res)
prepare via envelope call =
    let
        plain =
            Rpc.Call.withHeaders envelope.headers call
    in
    case envelope.binding of
        Nothing ->
            Ok plain

        Just index ->
            via index plain


{-| A JSON call over its binding `index`, or why it has none.
-}
viaBinding : Envelope -> Int -> Rpc.Call Rpc.Json req res -> Result String (Rpc.Call Rpc.Json req res)
viaBinding envelope index call =
    Rpc.Call.viaBinding index call
        |> Result.fromMaybe
            ("binding "
                ++ String.fromInt index
                ++ " is not one "
                ++ envelope.service
                ++ "/"
                ++ envelope.method
                ++ " has"
            )


{-| How the pure halves read an answer for a client: as text through
`Rpc.response`, or as bytes through `Rpc.responseBytes`, keeping the answer's
status and headers.
-}
type alias Reading codec req res msg =
    Rpc.Call codec req res -> (Result Never ( Value, Result Rpc.Error res ) -> msg) -> Http.Expect msg


{-| The commands for a call. Only a call elm/http sends under a tracker can be
aborted: one sent with `send` without a retry policy, or through the halves
with the tracker on `Http.request`. `sendTraced`, `task`, `taskFromRequest`
and `send` with a retry policy ignore the tracker, so a call sent so with `cancelAfter` is
refused rather than reported cancelled while it runs on. A call to be
cancelled without a tracker of its own gets its id as one.
-}
sendWith : Rpc.Client codec -> Reading codec req res msg -> Envelope -> Respond res -> (Outcome -> msg) -> Rpc.Call codec req res -> Result String (Sent msg)
sendWith client reading envelope respond toMsg c =
    let
        tracker =
            case ( envelope.tracker, envelope.cancelAfter ) of
                ( Just name, _ ) ->
                    Just name

                ( Nothing, Just _ ) ->
                    Just envelope.id

                ( Nothing, Nothing ) ->
                    Nothing

        tracked =
            case tracker of
                Just name ->
                    Rpc.Call.withTracker name c

                Nothing ->
                    c

        report trace result =
            reportWith trace Encode.null result

        reportWith trace answer result =
            toMsg
                { id = envelope.id
                , result = encodeResult respond result
                , trace = trace
                , response = answer
                }

        cancelling =
            case ( envelope.cancelAfter, tracker ) of
                ( Just _, Just name ) ->
                    Just
                        (Cmd.batch
                            [ Rpc.cancel name
                            , Task.succeed
                                { id = envelope.id
                                , result = Encode.object [ ( "canceled", Encode.bool True ) ]
                                , trace = Encode.null
                                , response = Encode.null
                                }
                                |> Task.perform toMsg
                            ]
                        )

                _ ->
                    Nothing

        uncancellable send =
            case envelope.cancelAfter of
                Just _ ->
                    Err ("a call sent with " ++ send ++ " cannot be cancelled: it ignores the tracker")

                Nothing ->
                    Ok Nothing
    in
    case envelope.sending of
        Traced ->
            uncancellable "sendTraced"
                |> Result.map (Sent (Rpc.sendTraced client (\trace -> report (Rpc.Trace.toJson trace)) tracked))

        Plain ->
            case Rpc.Client.retry client of
                Just _ ->
                    uncancellable "send and a retry policy"
                        |> Result.map (Sent (Rpc.send client (report Encode.null) tracked))

                Nothing ->
                    Ok (Sent (Rpc.send client (report Encode.null) tracked) cancelling)

        AsTask ->
            uncancellable "task"
                |> Result.map (Sent (Rpc.task client tracked |> Task.attempt (report Encode.null)))

        Halves ->
            Ok
                (Sent (sendHalves client reading tracked tracker (\( answer, result ) -> reportWith Encode.null answer result))
                    cancelling
                )

        FromRequest ->
            uncancellable "taskFromRequest"
                |> Result.map
                    (Sent
                        (Rpc.request client tracked
                            |> rewriteHeaders envelope.rewrite
                            |> Rpc.taskFromRequest client tracked
                            |> Task.attempt (report Encode.null)
                        )
                    )


{-| A request with each of `rewrites` in place of the header of its name, in
any case, where it has one, and after its headers where it has none.
-}
rewriteHeaders : List ( String, String ) -> Rpc.Request -> Rpc.Request
rewriteHeaders rewrites sent =
    let
        rewriteOne ( name, value ) headers =
            if List.any (\( n, _ ) -> String.toLower n == String.toLower name) headers then
                List.map
                    (\( n, v ) ->
                        if String.toLower n == String.toLower name then
                            ( n, value )

                        else
                            ( n, v )
                    )
                    headers

            else
                headers ++ [ ( name, value ) ]
    in
    { sent | headers = List.foldl rewriteOne sent.headers rewrites }


{-| Send a call as `Rpc.request` describes it, with elm/http directly, and read
the answer with `Rpc.response` or `Rpc.responseBytes`, keeping the answer's
status and headers.
-}
sendHalves : Rpc.Client codec -> Reading codec req res msg -> Rpc.Call codec req res -> Maybe String -> (( Value, Result Rpc.Error res ) -> msg) -> Cmd msg
sendHalves client reading c tracker toMsg =
    let
        sent =
            Rpc.request client c

        perform =
            if sent.withCredentials then
                Http.riskyRequest

            else
                Http.request

        deliver outcome =
            case outcome of
                Ok pair ->
                    toMsg pair

                Err impossible ->
                    never impossible
    in
    perform
        { method = sent.method
        , headers = List.map (\( name, value ) -> Http.header name value) sent.headers
        , url = sent.url
        , body =
            case ( Rpc.Body.toText sent.body, Rpc.Body.toBytes sent.body, Rpc.Body.contentType sent.body ) of
                ( Just json, _, _ ) ->
                    Http.stringBody "application/json" json

                ( Nothing, Just binary, Just type_ ) ->
                    Http.bytesBody type_ binary

                _ ->
                    Http.emptyBody
        , expect = reading c deliver
        , timeout = sent.timeout
        , tracker = tracker
        }


encodeAnswer : Http.Response body -> Value
encodeAnswer answer =
    let
        withMetadata metadata =
            Encode.object
                [ ( "status", Encode.int metadata.statusCode )
                , ( "headers", Encode.list (\( k, v ) -> Encode.list Encode.string [ k, v ]) (Dict.toList metadata.headers) )
                ]
    in
    case answer of
        Http.GoodStatus_ metadata _ ->
            withMetadata metadata

        Http.BadStatus_ metadata _ ->
            withMetadata metadata

        _ ->
            Encode.null


{-| A detail read, as its proto3 JSON through `registry` (the runner's own
table, whatever the client's), or Connect's `{"type", "value"}` form for one
of a type it lacks; a detail problem as `{"unregisteredType": url}`, or
`{"invalidDetail": reason}` with the error's text for any other. A detail
held as JSON alone, which a lenient client registry reads, is unpacked with
its `google.rpc` typed value and written as that value, so that a case's
expected JSON says it unpacks; `{"notUnpacked": url}` when it does not.
-}
detailWith : Proto.Registry.Registry -> Result Proto.Error.Error Proto.Any.Any -> Value
detailWith registry detail =
    case detail of
        Ok any ->
            case Proto.Any.bytes any of
                Just binary ->
                    case Proto.Json.encodeAnyWith registry any of
                        Ok json ->
                            json

                        Err _ ->
                            Encode.object
                                [ ( "type", Encode.string (Proto.Any.typeName any) )
                                , ( "value", Encode.string (Proto.Bytes.toBase64 binary) )
                                ]

                Nothing ->
                    case unpackedDetail any |> Maybe.andThen (Proto.Json.encodeAnyWith registry >> Result.toMaybe) of
                        Just json ->
                            json

                        Nothing ->
                            Encode.object [ ( "notUnpacked", Encode.string (Proto.Any.typeUrl any) ) ]

        Err (Proto.Error.UnregisteredType url) ->
            Encode.object [ ( "unregisteredType", Encode.string url ) ]

        Err problem ->
            Encode.object [ ( "invalidDetail", Encode.string (Proto.Error.toString problem) ) ]


{-| A detail unpacked with its `google.rpc` typed value and packed again.
-}
unpackedDetail : Proto.Any.Any -> Maybe Proto.Any.Any
unpackedDetail any =
    [ repacked Proto.ErrorDetails.errorInfo
    , repacked Proto.ErrorDetails.retryInfo
    , repacked Proto.ErrorDetails.debugInfo
    , repacked Proto.ErrorDetails.quotaFailure
    , repacked Proto.ErrorDetails.preconditionFailure
    , repacked Proto.ErrorDetails.badRequest
    , repacked Proto.ErrorDetails.requestInfo
    , repacked Proto.ErrorDetails.resourceInfo
    , repacked Proto.ErrorDetails.help
    , repacked Proto.ErrorDetails.localizedMessage
    ]
        |> List.filterMap (\unpack -> unpack any)
        |> List.head


repacked : Message a -> Proto.Any.Any -> Maybe Proto.Any.Any
repacked message any =
    Proto.Any.unpack message any |> Maybe.map (Proto.Any.pack message)


{-| A result as JSON: the response's fields (`Respond`); an error's details
under `details`, as `Respond` writes each, and under `detailsBinary` each
one's `Any` in protobuf binary (`null` for a detail problem).
-}
encodeResult : Respond res -> Result Rpc.Error res -> Value
encodeResult respond result =
    case result of
        Ok response ->
            Encode.object (respond.response response)

        Err (Rpc.Error.RpcStatus status answer) ->
            Encode.object
                [ ( "error"
                  , Encode.object
                        [ ( "code", Encode.string (Rpc.Code.toString status.code) )
                        , ( "message", Encode.string status.message )
                        , ( "details", Encode.list respond.detail status.details )
                        , ( "detailsBinary"
                          , Encode.list
                                (Result.map (Proto.Binary.encode (Proto.Binary.messageEncoder Proto.Binary.any) >> Proto.Bytes.toBase64 >> Encode.string)
                                    >> Result.withDefault Encode.null
                                )
                                status.details
                          )
                        , ( "source", Encode.string (sourceToString status.source) )
                        , ( "response", encodeResponse_ answer )
                        ]
                  )
                ]

        Err ((Rpc.Error.HttpStatus answer) as error) ->
            Encode.object
                [ ( "error"
                  , Encode.object
                        [ ( "code", Encode.string (Rpc.Code.toString (Rpc.Error.code error)) )
                        , ( "message", Encode.string (Rpc.Error.message error) )
                        , ( "details", Encode.list identity [] )
                        , ( "source", Encode.string "HttpStatus" )
                        , ( "response", encodeResponse_ answer )
                        ]
                  )
                ]

        Err ((Rpc.Error.BadBody problem answer) as error) ->
            badResponse error (Proto.Error.toString problem) answer

        Err ((Rpc.Error.BadEnvelope problem answer) as error) ->
            badResponse error problem answer

        Err ((Rpc.Error.BadMessageCount count answer) as error) ->
            badResponse error (messageCountText count) answer

        Err (Rpc.Error.ResponseTooLarge { limit, size }) ->
            noAnswer ("ResponseTooLarge " ++ String.fromInt size ++ " " ++ String.fromInt limit)

        Err Rpc.Error.Timeout ->
            noAnswer "Timeout"

        Err Rpc.Error.NetworkError ->
            noAnswer "NetworkError"

        Err (Rpc.Error.BadUrl url) ->
            noAnswer ("BadUrl " ++ url)

        Err (Rpc.Error.BadHeader name) ->
            noAnswer ("BadHeader " ++ name)

        Err (Rpc.Error.BadPathValue { field, template }) ->
            noAnswer ("BadPathValue " ++ field ++ " " ++ template)

        Err (Rpc.Error.RequestTooLarge { limit, size }) ->
            noAnswer ("RequestTooLarge " ++ String.fromInt size ++ " " ++ String.fromInt limit)

        Err (Rpc.Error.BadAny problem) ->
            noAnswer ("BadAny " ++ anyProblemText problem)


{-| An answer that could not be read as the response: its code, what was
wrong with it, and the answer.
-}
badResponse : Rpc.Error -> String -> Rpc.Response -> Value
badResponse error problem answer =
    Encode.object
        [ ( "badResponse"
          , Encode.object
                [ ( "code", Encode.string (Rpc.Code.toString (Rpc.Error.code error)) )
                , ( "problem", Encode.string problem )
                , ( "response", encodeResponse_ answer )
                ]
          )
        ]


{-| A call that had no answer, or whose answer was refused unread, as the
cases name it.
-}
noAnswer : String -> Value
noAnswer reason =
    Encode.object [ ( "noAnswer", Encode.string reason ) ]


{-| A unary gRPC-Web answer's wrong message count, worded as the runtime's
message words it.
-}
messageCountText : Int -> String
messageCountText count =
    if count == 0 then
        "a unary gRPC-Web answer with status 0 and no message"

    else
        "a unary gRPC-Web answer with status 0 and more than one message"


{-| The answer an error was read from: its status and body. The headers are
left out; the trace carries what a case wants of them.
-}
encodeResponse_ : Rpc.Response -> Value
encodeResponse_ answer =
    Encode.object
        ([ ( "statusCode", Encode.int answer.statusCode )
         , ( "statusText", Encode.string answer.statusText )
         , ( "body", Encode.string (Maybe.withDefault "" (Rpc.Body.toText answer.body)) )
         ]
            ++ (case Rpc.Body.toBytes answer.body of
                    Just binary ->
                        [ ( "bodyBase64", Encode.string (Proto.Bytes.toBase64 binary) ) ]

                    Nothing ->
                        []
               )
        )


sourceToString : Rpc.Error.Source -> String
sourceToString source =
    case source of
        Rpc.Error.ConnectBody ->
            "ConnectBody"

        Rpc.Error.StatusBody ->
            "StatusBody"

        Rpc.Error.GrpcHeaders ->
            "GrpcHeaders"

        Rpc.Error.GrpcTrailers ->
            "GrpcTrailers"

        Rpc.Error.ConnectEndStream ->
            "ConnectEndStream"


{-| A bad `Any`'s problem, by its kind.
-}
anyProblemText : Proto.Error.Error -> String
anyProblemText problem =
    case problem of
        Proto.Error.UnregisteredType url ->
            "UnregisteredType " ++ url

        Proto.Error.BadBinary binary ->
            "BadBinary " ++ binary.typeName

        Proto.Error.BadJson _ ->
            "BadJson"

        Proto.Error.TypeMismatch { expected } ->
            "TypeMismatch " ++ expected
