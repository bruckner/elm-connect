module Rpc.Internal.Limit exposing
    ( bytesMessage
    , bytesOverRead
    , bytesTooLarge
    , bytesUnlimited
    , encodedWidth
    , jsonTooLarge
    , textOverRead
    , textUnlimited
    , utf8Length
    , width
    , withinText
    , writeTooLargeText
    )

{-| The limits a message is held to: the write limit a request is checked
against before it is sent, and the read limit a successful answer is checked
against before it is decoded, each over text and over bytes, with the message
of a call over either. Not exposed.

`Rpc.Protocol` installs these functions in a protocol
(`Rpc.Internal.Protocol`), each a top-level function, so a program carries
only those its protocols and options reach: a constructor installs the
`Unlimited` pair of its wire, `withReadMaxBytes` and `withWriteMaxBytes` the
ones that measure, and a binary protocol's constructor alone `width` and
`encodedWidth`, the only two here that run elm/bytes. A protocol's reader
(`Rpc.Internal.Connect`, `Rpc.Internal.Transcode`, `Rpc.Internal.GrpcWeb`)
holds its successful answer to the read limit through `withinText` or
`bytesMessage`, and `Rpc.Internal.Plan` words a refused request with
`writeTooLargeText`.

-}

import Bytes exposing (Bytes)
import Bytes.Encode
import Http
import Json.Encode exposing (Value)
import Rpc.Body
import Rpc.Code as Code
import Rpc.Error exposing (Error)
import Rpc.Internal.Envelope as Envelope
import Rpc.Internal.Protocol exposing (BytesMessage, GoodBytes, GoodText, Options, Size)



-- WRITE LIMITS


{-| Whether a request's JSON, as UTF-8, is over the write limit. Installed by
`withWriteMaxBytes`; the JSON is encoded again only then.
-}
jsonTooLarge : Options -> (() -> Value) -> Maybe Size
jsonTooLarge options json =
    options.writeMaxBytes
        |> Maybe.andThen
            (\limit ->
                overLimit limit (Json.Encode.encode 0 (json ()))
                    |> Maybe.map (\size -> { limit = limit, size = size })
            )


{-| Whether a request's protobuf binary is over the write limit.
-}
bytesTooLarge : (Bytes.Encode.Encoder -> Int) -> Options -> (() -> Bytes.Encode.Encoder) -> Maybe Size
bytesTooLarge measure options binary =
    options.writeMaxBytes
        |> Maybe.andThen
            (\limit ->
                let
                    size =
                        measure (binary ())
                in
                if size > limit then
                    Just { limit = limit, size = size }

                else
                    Nothing
            )


{-| No limit: what a protocol's `tooLarge` and `overRead` are until a
modifier installs a limit.
-}
textUnlimited : Options -> a -> Maybe Size
textUnlimited _ _ =
    Nothing


{-| No limit, for a binary protocol. Apart from `textUnlimited` only so that
each protocol's field has its own type.
-}
bytesUnlimited : a -> Options -> b -> Maybe Size
bytesUnlimited _ _ _ =
    Nothing



-- READ LIMITS


{-| A successful text answer, unless it is over the read limit.
-}
withinText : (Options -> String -> Maybe Size) -> Options -> GoodText -> Result Error GoodText
withinText overRead options good =
    case overRead options good.raw of
        Just size ->
            Err (responseTooLarge size good.metadata)

        Nothing ->
            Ok good


{-| A successful binary answer's message, unless it is over the read limit.
-}
bytesMessage : (Options -> Bytes -> Maybe Size) -> Options -> ( Maybe Http.Metadata, Result Error GoodBytes ) -> ( Maybe Http.Metadata, Result Error BytesMessage )
bytesMessage overRead options ( metadata, read ) =
    ( metadata
    , read
        |> Result.andThen
            (\good ->
                case overRead options good.message of
                    Just size ->
                        Err (responseTooLarge size good.metadata)

                    Nothing ->
                        Ok
                            { bytes = good.message
                            , bad = \problem -> Rpc.Error.badBody problem (Envelope.bytesAnswer good.metadata good.raw)
                            }
            )
    )


{-| Whether a successful text answer is over the read limit: its body as
the browser decoded it, written back as UTF-8. Installed by
`withReadMaxBytes`.
-}
textOverRead : Options -> String -> Maybe Size
textOverRead options raw =
    options.readMaxBytes
        |> Maybe.andThen
            (\limit ->
                overLimit limit raw
                    |> Maybe.map (\size -> { limit = limit, size = size })
            )


{-| Whether a successful binary answer's message is over the read limit.
-}
bytesOverRead : (Bytes -> Int) -> Options -> Bytes -> Maybe Size
bytesOverRead width_ options message =
    options.readMaxBytes
        |> Maybe.andThen
            (\limit ->
                let
                    size =
                        width_ message
                in
                if size > limit then
                    Just { limit = limit, size = size }

                else
                    Nothing
            )



-- MEASURES


{-| The size of a text (an answer's body, a request's JSON), in UTF-8 bytes,
when it is over `limit`; `Nothing` when it is within it. The limit
modifiers install no limit below 1.

A text is at least one byte of UTF-8 per UTF-16 unit of its JavaScript string
and at most three, so a text that fits whatever it holds is never counted.

-}
overLimit : Int -> String -> Maybe Int
overLimit limit text =
    let
        units =
            String.length text
    in
    if units * 3 <= limit then
        Nothing

    else
        let
            size =
                utf8Length text
        in
        if size > limit then
            Just size

        else
            Nothing


{-| The length of a string written as UTF-8, in bytes. `String.foldl` is a
loop in elm/core's kernel rather than a recursion, so a body of any length
is counted in constant stack. A surrogate pair is one character of four
bytes. The count is exact for well-formed text, which every body the browser
decoded is (it writes U+FFFD for bytes that are not UTF-8); a lone surrogate
has no UTF-8 form, and counts as three or four.
-}
utf8Length : String -> Int
utf8Length =
    String.foldl (\char size -> size + utf8Width (Char.toCode char)) 0


utf8Width : Int -> Int
utf8Width code =
    if code < 0x80 then
        1

    else if code < 0x0800 then
        2

    else if code > 0xFFFF then
        4

    else
        3


{-| The size of bytes, the binary protocols' measure for their limits.
-}
width : Bytes -> Int
width =
    Bytes.width


{-| The size of the bytes an encoder writes: the binary protocols' measure
for their write limit.
-}
encodedWidth : Bytes.Encode.Encoder -> Int
encodedWidth encoder =
    Bytes.width (Bytes.Encode.encode encoder)



-- MESSAGES


{-| A successful answer over the read limit: its status and headers are kept,
without its body, which was dropped unread.
-}
responseTooLarge : Size -> Http.Metadata -> Error
responseTooLarge { limit, size } metadata =
    Rpc.Error.badResponse Code.ResourceExhausted
        ("message size " ++ String.fromInt size ++ " is larger than configured readMaxBytes " ++ String.fromInt limit)
        { url = metadata.url
        , statusCode = metadata.statusCode
        , statusText = metadata.statusText
        , headers = metadata.headers
        , body = Rpc.Body.none
        }


{-| The message of a request over the write limit, as connect-es words it.
-}
writeTooLargeText : Size -> String
writeTooLargeText { limit, size } =
    "message size " ++ String.fromInt size ++ " is larger than configured writeMaxBytes " ++ String.fromInt limit
