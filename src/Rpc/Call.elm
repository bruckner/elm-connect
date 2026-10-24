module Rpc.Call exposing
    ( Call
    , withHeaders, withTimeout, withRetry, withoutRetry, withTracker, viaBinding
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

@docs withHeaders, withTimeout, withRetry, withoutRetry, withTracker, viaBinding


# Reading a call

@docs method, descriptor, serviceName, methodName, idempotency, requestMessage, requestJson, toJson

-}

import Json.Encode exposing (Value)
import Proto.Method as Method exposing (Idempotency, Method)
import Rpc.Internal.Call as Internal
import Rpc.Retry exposing (Retry)


{-| A method applied to its request: everything needed to send it, and the
per-call adjustments made to it. Generated code builds one per method with
[`Rpc.call`](Rpc#call):

    Notes.V1.NotesService.getNote : GetNoteRequest -> Rpc.Call GetNoteRequest Note

It is opaque, and the same type as [`Rpc.Call`](Rpc#Call): adjust one with
the functions below and send it with [`Rpc.send`](Rpc#send) or
[`Rpc.task`](Rpc#task). The package site and compiler errors may show it as
`Rpc.Internal.Call.Call`, its name inside the package; that module is not
exposed, and the type stays opaque.

A call holds functions, its method's encoder and decoder, so `==` on two
calls fails at run time, and the debugger cannot import or export a history
whose messages hold one. Compare [`toJson`](#toJson) instead.

-}
type alias Call req res =
    Internal.Call req res



-- ADJUSTING A CALL


{-| Headers to send with this call, after the config's.

    Notes.getNote { name = "notes/42" }
        |> Rpc.Call.withHeaders [ ( "X-Request-Id", "req-7" ) ]

They are held to the rule for the config's headers
([`Rpc.Config`](Rpc#Config)): a call with a name that is not an HTTP token,
or a value holding NUL, CR, LF or a character above U+00FF, is not sent, and
fails with `NoAnswer (InvalidHeader name)`.

-}
withHeaders : List ( String, String ) -> Call req res -> Call req res
withHeaders extra (Internal.Call c) =
    Internal.Call { c | headers = c.headers ++ extra }


{-| A timeout for this call in milliseconds, in place of the config's.

    Notes.getNote { name = "notes/42" }
        |> Rpc.Call.withTimeout 10000

One that is not a positive number (`0`, a negative number, NaN or infinity)
is ignored, and the config's applies. With a retry policy in effect
([`withRetry`](#withRetry)), the timeout applies to each attempt.

-}
withTimeout : Float -> Call req res -> Call req res
withTimeout ms (Internal.Call c) =
    Internal.Call { c | timeout = Just ms }


{-| A retry policy for this call, in place of the config's `retry`
([`Rpc.Retry`](Rpc-Retry)).

    Notes.getNote { name = "notes/42" }
        |> Rpc.Call.withRetry
            (Rpc.Retry.on [ Rpc.Code.Unavailable ]
                |> Rpc.Retry.withAttempts 5
            )

-}
withRetry : Retry -> Call req res -> Call req res
withRetry policy (Internal.Call c) =
    Internal.Call { c | retry = Internal.OwnRetry policy }


{-| Send this call once, whatever the config's `retry` says: for a call the
user may cancel ([`withTracker`](#withTracker)), and for a call the
application retries on its own.

    Notes.getNote { name = "notes/42" }
        |> Rpc.Call.withoutRetry
        |> Rpc.Call.withTracker "note-42"
        |> Rpc.send config GotNote

-}
withoutRetry : Call req res -> Call req res
withoutRetry (Internal.Call c) =
    Internal.Call { c | retry = Internal.NoRetry }


{-| A tracker for this call, so [`Rpc.cancel`](Rpc#cancel) can cancel it.
elm/http tracks commands only, so only [`Rpc.send`](Rpc#send) without a retry
policy in effect uses it: with no `retry` in the config, or with
[`withoutRetry`](#withoutRetry) on the call. The other ways of sending ignore
it.
-}
withTracker : String -> Call req res -> Call req res
withTracker tracker (Internal.Call c) =
    Internal.Call { c | tracker = Just tracker }


{-| The call over another of its method's HTTP bindings, for transcoding: `0`
is the rule's own, which a call takes unless told otherwise, and `1` and up
its `additional_bindings` in order. `Nothing` when the method has no binding
of that number; a method without a rule has none, and its call goes over the
implicit route. Connect has no use for bindings and ignores the choice.

    Notes.getNote { name = "users/7/notes/42" }
        |> Rpc.Call.viaBinding 1
        |> Maybe.map (Rpc.send config GotNote)
        |> Maybe.withDefault Cmd.none

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

Two calls of one method with equal requests give the same JSON, so compare
calls by this, as `==` on the calls themselves fails at run time:

    Json.Encode.encode 0 (Rpc.Call.toJson a)
        == Json.Encode.encode 0 (Rpc.Call.toJson b)

-}
toJson : Call req res -> Value
toJson c =
    Json.Encode.object
        [ ( "service", Json.Encode.string (serviceName c) )
        , ( "method", Json.Encode.string (methodName c) )
        , ( "request", requestJson c )
        ]
