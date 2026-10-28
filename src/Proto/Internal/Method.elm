module Proto.Internal.Method exposing (Binary, Method(..), Read(..), binaryUnder)

{-| The `Method` type, which `Proto.Method` names by an alias. It is defined
here so that other modules of the package can reach what a method holds while
users cannot, so that `Rpc` can read a method's routes, which
`Proto.Method` exposes only to set, and so that `Rpc` can reach the bytes path
`Proto.Method.withBinary` builds: writing a request as protobuf binary and
reading a binary answer. Only a method with binary codecs carries that code,
so a program without any carries none of it, nor `Proto.Binary`,
`Proto.Bytes` or elm/bytes. The idempotency is a parameter because its
type stays in `Proto.Method`, which exposes its constructors. Its types are
elm/core's, elm/bytes', elm/http's and `Proto.Route`'s, so that no `Proto`
module imports an `Rpc` one.

A method holds its identity (service, name, idempotency) and one route
function per HTTP binding, not its descriptor: the descriptor's type names
and bindings as data are a separate value a program keeps only if it names
it.

-}

import Bytes exposing (Bytes)
import Bytes.Encode
import Http
import Json.Decode
import Json.Encode
import Proto.Internal.Binary
import Proto.Route exposing (Route)


type Method idempotency req res
    = Method
        { service : String
        , name : String
        , idempotency : idempotency
        , encodeRequest : req -> Json.Encode.Value
        , responseDecoder : Json.Decode.Decoder res
        , binary : Maybe (Binary req res)
        , json : Bool
        , routes : List (req -> Route)
        }


{-| The protobuf binary codecs, which `Proto.Method.withBinary` and
`Proto.Method.methodBinary` give, and the bytes path built from them:

  - `message`: the request's binary, and a GET's base64 of it, written only
    when asked for.
  - `tooLarge`: the request's size in bytes and the limit, when there is a
    limit and the request is over it.
  - `read`: an answer read as bytes, given the transport's read limit: a
    200 read as the response, and any other answer as UTF-8 text, for the
    JSON error reading.
  - `base64`: bytes as base64, for a trace.

-}
type alias Binary req res =
    { encodeRequest : req -> Bytes.Encode.Encoder
    , responseDecoder : Proto.Internal.Binary.Decoder res
    , message : req -> { bytes : Bytes, base64Url : () -> String }
    , tooLarge : Maybe Int -> req -> Maybe { limit : Int, size : Int }
    , read : Maybe Int -> Http.Response Bytes -> Read res
    , base64 : Bytes -> String
    }


{-| An answer read as bytes: a 200's response; a 200's size and the limit,
when it is over the read limit; a 200 that is not the response, of another
content type than `application/proto` or not decoding, with the problem and
the answer; or any other answer as text, which the JSON error reading takes.
-}
type Read res
    = Read res
    | TooLong { limit : Int, size : Int }
    | NotBinary String Http.Metadata Bytes
    | AsText (Http.Response String)


{-| The bytes path, when the transport sends protobuf binary (`proto`) and
the method has binary codecs.
-}
binaryUnder : Bool -> Method idempotency req res -> Maybe (Binary req res)
binaryUnder proto (Method m) =
    if proto then
        m.binary

    else
        Nothing
