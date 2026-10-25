module Live.Stream exposing (Entry, Opening, Options, entry)

{-| What the live runner opens for a streaming case: an entry of a dispatch
table turns a case's request into the command `Rpc.Stream.open` gives, and
each event the companion sends back into the JSON the case expects.
-}

import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode exposing (Value)
import Live.Call
import Rpc
import Rpc.Code
import Rpc.Error
import Rpc.Stream exposing (Event(..), StreamCall)


{-| A case's stream options: its call's own headers and timeout.
-}
type alias Options =
    { headers : List ( String, String ), timeout : Maybe Float }


{-| An opened stream: the command for the companion, and how to report each
of its events.
-}
type alias Opening =
    { command : Value, report : Value -> Value }


{-| `Err` with a reason when the request does not decode; otherwise what
`Rpc.Stream.open` answered, an error or the opening.
-}
type alias Entry =
    Rpc.Config -> String -> Value -> Options -> Result String (Result Rpc.Error Opening)


{-| The entry for a server-streaming method, from its generated call
function, its request's decoder and its response's encoder.
-}
entry : (req -> StreamCall req res) -> Decoder req -> (res -> Value) -> Entry
entry toCall requestDecoder encodeResponse config id request options =
    case Decode.decodeValue requestDecoder request of
        Err problem ->
            Err ("the request does not decode: " ++ Decode.errorToString problem)

        Ok decoded ->
            let
                call =
                    toCall decoded
                        |> Rpc.Stream.withHeaders options.headers
                        |> (case options.timeout of
                                Just ms ->
                                    Rpc.Stream.withTimeout ms

                                Nothing ->
                                    identity
                           )
            in
            Ok
                (Rpc.Stream.open config { id = id, call = call }
                    |> Result.map (\command -> { command = command, report = reportEvent encodeResponse call })
                )


{-| An event as a case expects it: `opened` with the status, `message` with
the message, `ended` with the trailers, `failed` with the error's code and
the error as a unary result reports it.
-}
reportEvent : (res -> Value) -> StreamCall req res -> Value -> Value
reportEvent encodeResponse call value =
    case Decode.decodeValue (Rpc.Stream.event call) value of
        Ok (Opened opened) ->
            Encode.object [ ( "kind", Encode.string "opened" ), ( "status", Encode.int opened.status ) ]

        Ok (Message res) ->
            Encode.object [ ( "kind", Encode.string "message" ), ( "message", encodeResponse res ) ]

        Ok (Ended ended) ->
            Encode.object [ ( "kind", Encode.string "ended" ), ( "trailers", Encode.dict identity (Encode.list Encode.string) ended.trailers ) ]

        Ok (Failed error) ->
            Encode.object
                [ ( "kind", Encode.string "failed" )
                , ( "code", Encode.string (Rpc.Code.toString (Rpc.Error.code error)) )
                , ( "result", Live.Call.encodeResult encodeResponse (Err error) )
                ]

        Err problem ->
            Encode.object [ ( "kind", Encode.string "undecodable" ), ( "problem", Encode.string (Decode.errorToString problem) ) ]
