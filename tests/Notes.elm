module Notes exposing
    ( GetNote
    , base
    , binaryOnly
    , both
    , decodeTitle
    , decodeTitleBytesAs
    , encodeGetNote
    , encodeGetNoteBytes
    , jsonOnly
    , over
    , title
    , titleAs
    , titleHi
    )

{-| The method the `Rpc` tests call, written by hand in the generated shape:
`notes.v1.Notes/GetNote`, whose request names a note and whose response is a
message of one string field, the note's title, read as a `String`. Here are
its codecs, the method with both codecs and with either alone, and a client
of the test server.

The response's type name appears in a binary failure's text and in an `Any`'s
type URL, and the tests that read those do not all give it one name: it is
`notes.v1.Title` unless a test names it with `decodeTitleBytesAs` or
`titleAs`.

-}

import Bytes exposing (Bytes)
import Bytes.Encode
import Json.Decode
import Json.Encode
import Octets exposing (bytesOf)
import Proto.Binary
import Proto.Json
import Proto.Message exposing (Message)
import Proto.Method exposing (Idempotency(..))
import Rpc
import Rpc.Protocol


type alias GetNote =
    { name : String }


encodeGetNote : GetNote -> Json.Encode.Value
encodeGetNote r =
    Json.Encode.object [ ( "name", Json.Encode.string r.name ) ]


encodeGetNoteBytes : GetNote -> Bytes.Encode.Encoder
encodeGetNoteBytes r =
    Bytes.Encode.sequence [ Proto.Binary.implicit Proto.Binary.string 1 r.name ]


decodeTitle : Json.Decode.Decoder String
decodeTitle =
    Json.Decode.field "title" Json.Decode.string


encodeTitle : String -> Json.Encode.Value
encodeTitle t =
    Json.Encode.object [ ( "title", Json.Encode.string t ) ]


encodeTitleBytes : String -> Bytes.Encode.Encoder
encodeTitleBytes t =
    Bytes.Encode.sequence [ Proto.Binary.implicit Proto.Binary.string 1 t ]


decodeTitleBytes : Proto.Binary.Decoder String
decodeTitleBytes =
    decodeTitleBytesAs "notes.v1.Title"


{-| The response's binary decoder, under this type name.
-}
decodeTitleBytesAs : String -> Proto.Binary.Decoder String
decodeTitleBytesAs typeName =
    Proto.Binary.merge typeName
        (\number wire value ->
            case number of
                1 ->
                    Proto.Binary.field Proto.Binary.string identity wire value

                _ ->
                    Proto.Binary.skip wire value
        )
        identity
        ""


{-| The response as generated code gives a message.
-}
title : Message String
title =
    titleAs "notes.v1.Title"


{-| The response's message, under this type name.
-}
titleAs : String -> Message String
titleAs typeName =
    Proto.Message.init typeName (Proto.Json.succeed << encodeTitle) decodeTitle encodeTitleBytes (decodeTitleBytesAs typeName)


{-| A note whose title is "hi", in protobuf binary.
-}
titleHi : Bytes
titleHi =
    bytesOf [ 0x0A, 0x02, 0x68, 0x69 ]


{-| `GetNote` has no side effects, so a protocol that sends such a call as a
GET sends this one so.
-}
getNoteIn : Proto.Method.Method codec GetNote String -> Proto.Method.Method codec GetNote String
getNoteIn =
    Proto.Method.withIdempotency IdempotencyNoSideEffects


{-| The method with both codecs, as `wire=both` generates it.
-}
both : GetNote -> Rpc.Call codec GetNote String
both =
    Rpc.call (getNoteIn (Proto.Method.init "notes.v1.Notes" "GetNote" (encodeGetNote >> Proto.Json.succeed) (\_ -> decodeTitle) encodeGetNoteBytes decodeTitleBytes))


{-| The method with JSON alone.
-}
jsonOnly : GetNote -> Rpc.Call Rpc.Json GetNote String
jsonOnly =
    Rpc.call (getNoteIn (Proto.Method.initJson "notes.v1.Notes" "GetNote" (encodeGetNote >> Proto.Json.succeed) (\_ -> decodeTitle)))


{-| The method with binary alone.
-}
binaryOnly : GetNote -> Rpc.Call Rpc.Proto GetNote String
binaryOnly =
    Rpc.call (getNoteIn (Proto.Method.initProto "notes.v1.Notes" "GetNote" encodeGetNoteBytes decodeTitleBytes))


{-| A client of the test server over Connect with JSON.
-}
base : Rpc.Client Rpc.Json
base =
    over Rpc.Protocol.connect


{-| A client of the test server over a protocol, with nothing else set.
-}
over : Rpc.Protocol.Protocol codec -> Rpc.Client codec
over protocol =
    Rpc.client protocol "https://api.example.com"
