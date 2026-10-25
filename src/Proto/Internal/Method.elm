module Proto.Internal.Method exposing (Binary, Method(..), Read(..), binaryUnder)

{-| The `Method` type, which `Proto.Method` names by an alias. It is defined
here so that other modules of the package can reach what a method holds while
users cannot, and so that `Rpc` can reach the bytes path
`Proto.Method.withBinary` builds: writing a request as protobuf binary and
reading a binary answer. Only a method with binary codecs carries that code,
so a program without any carries none of it, nor `Proto.Binary`,
`Proto.Bytes` or elm/bytes. The descriptor is a parameter because its type,
with `Idempotency` and its readers, stays in `Proto.Method`. Its types are
elm/core's, elm/bytes' and elm/http's, so that no `Proto` module imports an
`Rpc` one.
-}

import Bytes exposing (Bytes)
import Bytes.Encode
import Http
import Json.Decode
import Json.Encode
import Proto.Internal.Binary


type Method descriptor req res
    = Method
        { encodeRequest : req -> Json.Encode.Value
        , responseDecoder : Json.Decode.Decoder res
        , descriptor : descriptor
        , binary : Maybe (Binary req res)
        , json : Bool
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
binaryUnder : Bool -> Method descriptor req res -> Maybe (Binary req res)
binaryUnder proto (Method m) =
    if proto then
        m.binary

    else
        Nothing
