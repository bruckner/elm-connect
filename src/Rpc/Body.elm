module Rpc.Body exposing (Body, none, text, bytes, toText, toBytes)

{-| The body of an [`Rpc.Request`](Rpc#Request) or an
[`Rpc.Response`](Rpc#Response): none, text or bytes. A request's JSON is text,
sent as `application/json`; its protobuf binary, under
[`Rpc.Transport.withCodec Proto`](Rpc-Transport#withCodec), is bytes, sent as
`application/proto`. An answer's body is as it arrived: text, or bytes when
the call was read as protobuf binary.

    Rpc.Body.toText request.body == Just "{\"name\":\"notes/42\"}"

@docs Body, none, text, bytes, toText, toBytes

-}

import Bytes exposing (Bytes)


{-| A body. It is opaque: make one with [`none`](#none), [`text`](#text) or
[`bytes`](#bytes) and read it with [`toText`](#toText) and
[`toBytes`](#toBytes).
-}
type Body
    = None
    | Text String
    | Binary Bytes


{-| No body, as a GET has.
-}
none : Body
none =
    None


{-| A body of text: a request's is sent as `application/json`, an answer's is
what arrived, empty when the server sent none.
-}
text : String -> Body
text =
    Text


{-| A body of bytes: a request's is sent as `application/proto`, an answer's
is what arrived when the call was read as protobuf binary.
-}
bytes : Bytes -> Body
bytes =
    Binary


{-| The body's text, or `Nothing` when there is none or it is bytes.
-}
toText : Body -> Maybe String
toText body =
    case body of
        None ->
            Nothing

        Text content ->
            Just content

        Binary _ ->
            Nothing


{-| The body's bytes, or `Nothing` when there is none or it is text.
-}
toBytes : Body -> Maybe Bytes
toBytes body =
    case body of
        Binary content ->
            Just content

        _ ->
            Nothing
