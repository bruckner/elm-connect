module Rpc.Body exposing (Body, none, text, bytes, bytesAs, toText, toBytes, contentType)

{-| The body of an [`Rpc.Request`](Rpc#Request) or an
[`Rpc.Response`](Rpc#Response): none, text or bytes. A request's JSON is text,
sent as `application/json`; its protobuf binary, over
[`Rpc.Protocol.connectProto`](Rpc-Protocol#connectProto), is bytes, sent as
`application/proto`. An answer's body is as it arrived: text, or bytes when
the answer was read as bytes. A request's body is sent as the type
[`contentType`](#contentType) gives.

    Rpc.Body.toText request.body == Just "{\"name\":\"notes/42\"}"

@docs Body, none, text, bytes, bytesAs, toText, toBytes, contentType

-}

import Bytes exposing (Bytes)


{-| A body. It is opaque: make one with [`none`](#none), [`text`](#text),
[`bytes`](#bytes) or [`bytesAs`](#bytesAs) and read it with
[`toText`](#toText), [`toBytes`](#toBytes) and [`contentType`](#contentType).
-}
type Body
    = None
    | Text String
    | Binary String Bytes


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
is what arrived when the answer was read as bytes.
-}
bytes : Bytes -> Body
bytes =
    Binary "application/proto"


{-| A body of bytes sent as another content type.

    Rpc.Body.bytesAs "application/octet-stream" raw

-}
bytesAs : String -> Bytes -> Body
bytesAs =
    Binary


{-| The body's text, or `Nothing` when there is none or it is bytes: bytes are
never read as text.
-}
toText : Body -> Maybe String
toText body =
    case body of
        Text content ->
            Just content

        _ ->
            Nothing


{-| The body's bytes, or `Nothing` when there is none or it is text.
-}
toBytes : Body -> Maybe Bytes
toBytes body =
    case body of
        Binary _ content ->
            Just content

        _ ->
            Nothing


{-| The content type a request's body is sent as: `application/json` for
text, the bytes' own type for bytes (`application/proto` unless
[`bytesAs`](#bytesAs) gave another), and `Nothing` for no body.

    Http.request
        { …
        , body =
            case ( Rpc.Body.toText sent.body, Rpc.Body.toBytes sent.body, Rpc.Body.contentType sent.body ) of
                ( Just json, _, _ ) ->
                    Http.stringBody "application/json" json

                ( Nothing, Just binary, Just type_ ) ->
                    Http.bytesBody type_ binary

                _ ->
                    Http.emptyBody
        , …
        }

-}
contentType : Body -> Maybe String
contentType body =
    case body of
        None ->
            Nothing

        Text _ ->
            Just "application/json"

        Binary type_ _ ->
            Just type_
