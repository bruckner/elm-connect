module Proto.Internal.Binary exposing (Decoder(..), Encoder(..), Failure, crossed, encode, encoder, run, runBase64)

{-| The binary decoder type, defined here so that `Proto.Message` can run a
decoder without importing `Proto.Binary`, which imports it through
`Proto.Json` and `Proto.Any`.

A decoder reads twice, only when it must. Its fast reader is what every
message pays for: it reads as protobuf does and says only whether the bytes
are the message. When they are not, its locating reader reads the same
bytes again, bounded at every step by the region it is in (the input, a
message, a packed run, a map entry), and says why and where. Keeping the
locating work off the fast reader keeps a successful decode at the cost of
one that cannot explain itself (docs/decisions.md, "The binary decoder
reads twice").

-}

import Bytes exposing (Bytes)
import Bytes.Decode
import Bytes.Encode
import Proto.Bytes
import Proto.Error exposing (Reason(..))


{-| A message decoder: the message's full name and its two readers, each
given the number of bytes the message occupies.
-}
type Decoder a
    = Decoder
        { name : String
        , fast : Int -> Bytes.Decode.Decoder a
        , located : Int -> Bytes.Decode.Decoder (Result Failure a)
        }


{-| A message encoder: elm/bytes' encoder and the number of bytes it writes.
-}
type Encoder
    = Encoder Int Bytes.Encode.Encoder


encode : Encoder -> Bytes
encode (Encoder _ e) =
    Bytes.Encode.encode e


{-| elm/bytes' encoder alone, for a request body.
-}
encoder : Encoder -> Bytes.Encode.Encoder
encoder (Encoder _ e) =
    e


{-| A failure while it unwinds: its reason, the fields it is in (message
name and field number, outermost first) and its offset from the start of
the region it has unwound to.

While a failure unwinds, `Truncated` means a read past the end of the
region being read; whether that is the end of the input or of a region the
input holds whole is known only once the failure leaves the region
([`crossed`](#crossed)) or reaches the top.

It is a `Proto.Error.Binary` without the message's name, which belongs to
the decoder that was run and which [`run`](#run) adds once the failure
reaches the top.

-}
type alias Failure =
    { reason : Reason
    , path : List ( String, Int )
    , offset : Int
    }


{-| A failure leaving a length-delimited region that started `base` bytes
into the enclosing one: a read past the region's end is a `LengthOverrun`,
since the enclosing region held all of it.
-}
crossed : Int -> Failure -> Failure
crossed base failure =
    { reason =
        if failure.reason == Truncated then
            LengthOverrun

        else
            failure.reason
    , path = failure.path
    , offset = failure.offset + base
    }


{-| A whole input decoded as one message: the fast reader first, and the
locating one over the same input only when it fails. The two readers fail
on the same inputs; were they ever to disagree, the report says
`Unlocated`.
-}
run : Decoder a -> Bytes -> Result Proto.Error.Binary a
run (Decoder d) input =
    let
        width =
            Bytes.width input
    in
    case Bytes.Decode.decode (d.fast width) input of
        Just value ->
            Ok value

        Nothing ->
            case Bytes.Decode.decode (d.located width) input of
                Just (Err failure) ->
                    Err
                        { typeName = d.name
                        , reason = failure.reason
                        , path = failure.path
                        , offset = failure.offset
                        }

                _ ->
                    Err { typeName = d.name, reason = Unlocated, path = [], offset = 0 }


{-| A message from its binary as base64 text, as an `Any` holds it. An `Any`
holds only base64 its own code wrote or checked, so text that is not base64
is a bug here, and reads as `Unlocated`.
-}
runBase64 : Decoder a -> String -> Result Proto.Error.Binary a
runBase64 ((Decoder d) as decoder) base64 =
    case Proto.Bytes.fromBase64 base64 of
        Just input ->
            run decoder input

        Nothing ->
            Err { typeName = d.name, reason = Unlocated, path = [], offset = 0 }
