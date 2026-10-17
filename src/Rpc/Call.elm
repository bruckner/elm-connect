module Rpc.Call exposing
    ( Call
    , withHeaders, withTimeout, withTracker, viaBinding
    , method, descriptor, serviceName, methodName, idempotency, requestMessage, requestJson, toJson
    )

{-| A call: a method applied to its request, what a generated service
function gives and [`Rpc`](Rpc)'s functions send. This module adjusts one and
reads it back.

    Notes.V1.NotesService.getNote { name = "notes/42" }
        |> Rpc.Call.withTimeout 5000
        |> Rpc.Call.withHeaders [ ( "X-Request-Id", requestId ) ]

@docs Call


# Adjusting a call

@docs withHeaders, withTimeout, withTracker, viaBinding


# Reading a call

@docs method, descriptor, serviceName, methodName, idempotency, requestMessage, requestJson, toJson

-}

import Json.Encode exposing (Value)
import Proto.Method as Method exposing (Idempotency, Method)
import Rpc.Internal.Call as Internal


{-| A method applied to its request: everything needed to send it, and the
per-call adjustments made to it. Generated code builds one per method with
[`Rpc.call`](Rpc#call):

    Notes.V1.NotesService.getNote : GetNoteRequest -> Rpc.Call GetNoteRequest Note

It is opaque, and the same type as [`Rpc.Call`](Rpc#Call): adjust one with
the functions below and send it with [`Rpc.send`](Rpc#send) or
[`Rpc.task`](Rpc#task).

-}
type alias Call req res =
    Internal.Call req res



-- ADJUSTING A CALL


{-| Headers to send with this call, after the config's.
-}
withHeaders : List ( String, String ) -> Call req res -> Call req res
withHeaders extra (Internal.Call c) =
    Internal.Call { c | headers = c.headers ++ extra }


{-| A timeout for this call in milliseconds, in place of the config's. One
that is not a positive number (`0`, a negative number, NaN or infinity) is
ignored, and the config's applies.
-}
withTimeout : Float -> Call req res -> Call req res
withTimeout ms (Internal.Call c) =
    Internal.Call { c | timeout = Just ms }


{-| A tracker for this call, so [`Rpc.cancel`](Rpc#cancel) can cancel it.
elm/http tracks commands only, so only [`Rpc.send`](Rpc#send) without a
[`Retry`](Rpc-Retry#Retry) policy uses it; the other ways of sending ignore it.
-}
withTracker : String -> Call req res -> Call req res
withTracker tracker (Internal.Call c) =
    Internal.Call { c | tracker = Just tracker }


{-| The call over another of its method's HTTP bindings, for transcoding: `0`
is the rule's own, which a call takes unless told otherwise, and `1` and up
its `additional_bindings` in order. `Nothing` when the method has no binding
of that number; a method without a rule has none, and its call goes over the
implicit route. Connect has no use for bindings and ignores the choice.
-}
viaBinding : Int -> Call req res -> Maybe (Call req res)
viaBinding index (Internal.Call c) =
    if index >= 0 && index < List.length (Method.bindings (Method.toDescriptor c.method)) then
        Just (Internal.Call { c | binding = index })

    else
        Nothing



-- READING A CALL


{-| The method the call is of.
-}
method : Call req res -> Method req res
method (Internal.Call c) =
    c.method


{-| What the proto says about the method the call is of: its
[`Proto.Method.Descriptor`](Proto-Method#Descriptor).
-}
descriptor : Call req res -> Method.Descriptor
descriptor (Internal.Call c) =
    Method.toDescriptor c.method


{-| The fully-qualified service name, such as `notes.v1.NotesService`.
-}
serviceName : Call req res -> String
serviceName (Internal.Call c) =
    Method.service (Method.toDescriptor c.method)


{-| The method name as declared, such as `GetNote`.
-}
methodName : Call req res -> String
methodName (Internal.Call c) =
    Method.name (Method.toDescriptor c.method)


{-| What the proto says repeating the call does: nothing at all
(`IdempotencyNoSideEffects`, which Connect may send as a GET), nothing more
than the first time (`IdempotencyIdempotent`), or nothing it says
(`IdempotencyUnknown`). A retry policy retries only the first two unless told
otherwise.
-}
idempotency : Call req res -> Idempotency
idempotency (Internal.Call c) =
    Method.idempotency (Method.toDescriptor c.method)


{-| The request the call sends.
-}
requestMessage : Call req res -> req
requestMessage (Internal.Call c) =
    c.message


{-| The request's proto3 JSON.
-}
requestJson : Call req res -> Value
requestJson (Internal.Call c) =
    Method.encodeRequest c.method c.message


{-| The call as JSON, `{"service": …, "method": …, "request": …}`, for logs,
deduplication keys or a queue of calls to send later. Per-call adjustments are
not included.
-}
toJson : Call req res -> Value
toJson c =
    Json.Encode.object
        [ ( "service", Json.Encode.string (serviceName c) )
        , ( "method", Json.Encode.string (methodName c) )
        , ( "request", requestJson c )
        ]
