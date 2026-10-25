module Proto.Internal.Method exposing (Binary, ConnectMessage, Method(..), binaryUnder)

{-| The `Method` type, defined here so that `Rpc` can reach the bytes path
`Proto.Method.withBinary` builds: writing a request as protobuf binary and
reading a binary answer. Only a method with binary codecs carries that code,
so a program without any carries none of it, nor `Proto.Binary`,
`Proto.Bytes` or elm/bytes. The descriptor is a parameter because its type,
with `Idempotency` and its readers, stays in `Proto.Method`.
-}

import Bytes exposing (Bytes)
import Bytes.Decode
import Bytes.Encode
import Http
import Json.Decode
import Json.Encode
import Rpc.Body exposing (Body)
import Rpc.Error exposing (Error, Reason)


type Method descriptor req res
    = Method
        { encodeRequest : req -> Json.Encode.Value
        , responseDecoder : Json.Decode.Decoder res
        , descriptor : descriptor
        , binary : Maybe (Binary req res)
        , json : Bool
        }


{-| The binary codecs, and what Connect's proto codec does with them:

  - `message`: the request as Connect sends it.
  - `tooLarge`: why the request is over a write limit, if it is.
  - `read`: an answer read as bytes, given the transport's read limit and
    the reading of a text answer, which every answer but a 200 is.

-}
type alias Binary req res =
    { encodeRequest : req -> Bytes.Encode.Encoder
    , responseDecoder : Int -> Bytes.Decode.Decoder res
    , message : req -> ConnectMessage
    , tooLarge : Int -> req -> Maybe Reason
    , read : Maybe Int -> (Http.Response String -> Result Error res) -> Http.Response Bytes -> Result Error res
    }


{-| A request message as Connect sends it: its body as a POST, and as a GET
the query parameters before `message` (`encoding`, and `base64` for binary)
and `message`'s value, written only for a GET.
-}
type alias ConnectMessage =
    { body : Body, encoding : String, query : () -> String }


{-| The bytes path, when the transport sends protobuf binary (`proto`) and
the method has binary codecs.
-}
binaryUnder : Bool -> Method descriptor req res -> Maybe (Binary req res)
binaryUnder proto (Method m) =
    if proto then
        m.binary

    else
        Nothing
