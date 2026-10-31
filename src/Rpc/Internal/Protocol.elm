module Rpc.Internal.Protocol exposing (BinaryWire, BytesMessage, GoodBytes, GoodText, Options, Protocol(..), Settings, TextWire, Wire(..))

{-| The protocol calls are sent over. Not exposed: `Rpc.Protocol` builds one
and aliases the type, and `Rpc` sends a call through what it holds.

A protocol is one value holding its data half (its name, the codec it
speaks, its options) and its function half (how it builds a request and
reads an answer). Every function in it is a top-level function, chosen by
the constructor or installed by a modifier, which takes the options as an
argument rather than closing over them: two protocols built alike hold the
same functions and equal data, so `==` holds between them (elm/core
compares by reference first), and a program that never names a constructor
or a modifier carries none of its code.

The functions are monomorphic in the request and response types (Elm has no
rank-2 types, so a record field cannot hold a function polymorphic in
them): they build from and read to JSON values or bytes, and the method's
codecs, which the call holds, do the rest.

This module holds the types only. A protocol's module
(`Rpc.Internal.Connect`, `Rpc.Internal.Transcode`, `Rpc.Internal.GrpcWeb`)
holds every function `Rpc.Protocol` installs for it; `Rpc.Internal.Status`
reads a failure's status whatever the protocol; `Rpc.Internal.Http` holds what
every builder shares, the read and write limits, and what elm/http accepts; and `Rpc.Internal.Plan` is the one place a
method's codecs meet the protocol's functions.

-}

import Bytes exposing (Bytes)
import Bytes.Encode
import Http
import Json.Encode exposing (Value)
import Proto.Method exposing (Idempotency)
import Proto.Route exposing (Route)
import Rpc.Error exposing (Error, Reason)
import Rpc.Request exposing (Request)


type Protocol codec
    = Protocol
        { name : String
        , codec : String
        , options : Options
        , wire : Wire
        }


{-| The options, as data: whether Connect sends a method without side effects
as a GET (`get`, which `withConnectGet` sets beside installing the GET
builder), the longest GET URL, and the read and write limits.
-}
type alias Options =
    { get : Bool
    , maxGetUrl : Maybe Int
    , readMaxBytes : Maybe Int
    , writeMaxBytes : Maybe Int
    }


{-| What a request is built with, from the client and the call: the base
URL, the call's procedure path (`/service/method`) and its method's
idempotency, the client's headers then the call's, the timeout in effect (a
usable one: a positive number of milliseconds) and whether credentials go
cross-origin.
-}
type alias Settings =
    { baseUrl : String
    , procedure : String
    , idempotency : Idempotency
    , headers : List ( String, String )
    , timeout : Maybe Float
    , withCredentials : Bool
    }


{-| The function half: text (proto3 JSON) or bytes (protobuf binary).
-}
type Wire
    = Text TextWire
    | Binary BinaryWire


{-| A protocol speaking JSON:

  - `build`: the request, from the options, the settings, the call's
    route (when `routed`) and the request's JSON,
    encoded only by a builder that sends it whole (over a route, the
    route holds the body).
  - `routed`: whether the protocol reads a method's routes, so that a call
    builds its route only where it is read.
  - `message`: what a successful answer holds to decode, or the error the
    answer stands for; given `overRead`, so that the read limit is checked
    by whatever function a modifier installed, and the field of the
    response the route's `response_body` names, when it names one.
  - `tooLarge`: whether the request's JSON is over the write limit;
    installed by `withWriteMaxBytes`, else a function that says no. It is
    given the JSON to encode, so that the message is encoded to be measured
    only when there is a limit.
  - `overRead`: whether a successful answer's body is over the read limit;
    installed by `withReadMaxBytes`.
  - `timeoutHeader`: the header the protocol carries a timeout in over a
    route, and how it writes one, for a retry deadline that shortens it.

-}
type alias TextWire =
    { build : Options -> Settings -> Maybe Route -> (() -> Value) -> Request
    , routed : Bool
    , message : (Options -> String -> Maybe Reason) -> Options -> Maybe String -> Http.Response String -> Result Error GoodText
    , tooLarge : Options -> (() -> Value) -> Maybe Reason
    , overRead : Options -> String -> Maybe Reason
    , timeoutHeader : Maybe Route -> Maybe ( String, Float -> String )
    }


{-| A successful text answer: its metadata, its body as it came, the text to
decode (`{}` for an empty transcoding body) and the field of the response
it holds, when a binding's `response_body` names one.
-}
type alias GoodText =
    { metadata : Http.Metadata
    , raw : String
    , text : String
    , field : Maybe String
    }


{-| A protocol speaking protobuf binary, as `TextWire` but over bytes; `build`
takes the protocol's own base64 writer, for a GET's query, and the
request's encoder, which only these functions run; `message` takes the
call's `service/method`, for the error of a body that is not its response,
and gives the answer's metadata beside its result; `base64` writes a
request's binary for a trace. The limits take the protocol's `width` to
measure bytes with, so that a JSON program naming a limit modifier, which
installs the binary check too, reaches no elm/bytes code: its kernel comes
whole.
-}
type alias BinaryWire =
    { build : (Bytes -> String) -> Options -> Settings -> Bytes.Encode.Encoder -> Request
    , message : (Options -> Bytes -> Maybe Reason) -> Options -> String -> Http.Response Bytes -> ( Maybe Http.Metadata, Result Error BytesMessage )
    , tooLarge : (Bytes -> Int) -> Options -> (() -> Bytes.Encode.Encoder) -> Maybe Reason
    , overRead : (Bytes -> Int) -> Options -> Bytes -> Maybe Reason
    , width : Bytes -> Int
    , timeoutHeader : Maybe ( String, Float -> String )
    , base64 : Bytes -> String
    }


{-| A successful binary answer's message, and the error it stands for when
the method's decoder does not read it.
-}
type alias BytesMessage =
    { bytes : Bytes
    , bad : () -> Error
    }


{-| A successful binary answer: its metadata, its body as it came, and the
response message's bytes.
-}
type alias GoodBytes =
    { metadata : Http.Metadata
    , raw : Bytes
    , message : Bytes
    }
