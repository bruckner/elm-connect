module Rpc.Internal.Envelope exposing
    ( Label(..)
    , base64
    , bytesAnswer
    , bytesText
    , encode
    , envelopeText
    , header
    , label
    , metadataOf
    , procedureUrl
    , splitTrailers
    , timeoutMs
    , trimSlash
    )

{-| What is around a call's message, where the protocols agree on it. Of a
request: the URL of its procedure, a timeout header's milliseconds, and its
binary run from an encoder or written as base64. Of an answer: its metadata, a
header by name, its headers apart from its trailers, what a 200's content
type makes of it, its body as an error keeps it or reads it as text, and the
message of one that is malformed. Not exposed.

Each is a top-level function that a protocol's module
(`Rpc.Internal.Connect`, `Rpc.Internal.Transcode`, `Rpc.Internal.GrpcWeb`),
`Rpc.Internal.Status`, `Rpc.Protocol` or `Rpc` names, so a program carries
only those its protocols reach. That keeps elm/bytes, whose kernel comes
whole, out of a JSON program: only a binary protocol's constructor names
`encode` and `base64`, and only the reading of an answer as bytes reaches
`bytesText` and `bytesAnswer`.

The module imports no protocol's module and not `Rpc.Internal.Status`, so each
of those imports it without importing another for a helper.

-}

import Bytes exposing (Bytes)
import Bytes.Decode
import Bytes.Encode
import Dict exposing (Dict)
import Http
import Proto.Bytes
import Rpc.Body
import Rpc.Internal.Protocol exposing (Settings)
import Rpc.Response exposing (Response)



-- REQUESTS


{-| The URL of a call's procedure, where Connect and gRPC-Web send it: the
base URL and the call's procedure path, `/service/method`.
-}
procedureUrl : Settings -> String
procedureUrl settings =
    trimSlash settings.baseUrl ++ settings.procedure


trimSlash : String -> String
trimSlash url =
    if String.endsWith "/" url then
        String.dropRight 1 url

    else
        url


{-| A positive whole number of milliseconds, at most ten digits, as the
protocol requires.
-}
timeoutMs : Float -> String
timeoutMs ms =
    String.fromInt (clamp 1 9999999999 (ceiling ms))


{-| An encoder run, the binary protocols' way to get a request's bytes.
-}
encode : Bytes.Encode.Encoder -> Bytes
encode =
    Bytes.Encode.encode


{-| Bytes as standard base64, the binary protocols' writer for a GET's
query and a trace.
-}
base64 : Bytes -> String
base64 =
    Proto.Bytes.toBase64



-- ANSWERS


{-| An answer's status and headers, or `Nothing` when there was no answer.
-}
metadataOf : Http.Response body -> Maybe Http.Metadata
metadataOf answer =
    case answer of
        Http.GoodStatus_ metadata _ ->
            Just metadata

        Http.BadStatus_ metadata _ ->
            Just metadata

        _ ->
            Nothing


{-| A response header by name, whatever its case.
-}
header : String -> Http.Metadata -> Maybe String
header key metadata =
    metadata.headers
        |> Dict.toList
        |> List.filter (\( k, _ ) -> String.toLower k == key)
        |> List.head
        |> Maybe.map Tuple.second


{-| Split response headers as a Connect unary answer carries its metadata:
trailers as headers named `trailer-<name>` in any case, headers as the rest.
Names are lowercased, and values whose names differ only in case are joined
with `", "` in the order of their original names. A header named `trailer-`
alone names no trailer and stays a header.
-}
splitTrailers : Dict String String -> { headers : Dict String String, trailers : Dict String String }
splitTrailers =
    Dict.foldl
        (\name value split ->
            let
                lower =
                    String.toLower name
            in
            if String.startsWith trailerPrefix lower && String.length lower > String.length trailerPrefix then
                { split | trailers = insertJoined (String.dropLeft (String.length trailerPrefix) lower) value split.trailers }

            else
                { split | headers = insertJoined lower value split.headers }
        )
        { headers = Dict.empty, trailers = Dict.empty }


trailerPrefix : String
trailerPrefix =
    "trailer-"


insertJoined : String -> String -> Dict String String -> Dict String String
insertJoined key value =
    Dict.update key
        (\earlier ->
            case earlier of
                Just first ->
                    Just (first ++ ", " ++ value)

                Nothing ->
                    Just value
        )


{-| What a 200's content type makes of it.
-}
type Label
    = Accepted
    | Unaccepted String
    | Foreign


{-| A 200 by its content type, against the protocol's types (`family`) and
the ones this call reads (`accepted`):

  - `Accepted`: one of `accepted`, or none at all, since a proxy may drop
    the header; the body is the answer.
  - `Unaccepted`: another of the protocol's types, a codec the call does not
    read; the problem names both, and the answer is a `BadResponse`.
  - `Foreign`: not the protocol's at all, as a proxy's HTML page is. The
    protocol's server did not send it, so it is read as a failure, as an
    answer of another status is: a status it carries is the error, a
    `BadStatus`, and one without is a `BadResponse` whose code is
    `Unknown`, as `Rpc.Error.fromResponse` makes of any success. connect-go
    draws the same line, and the Connect conformance suite holds a client
    to it.

-}
label : (String -> Bool) -> List String -> Http.Metadata -> Label
label family accepted metadata =
    case contentType metadata of
        Nothing ->
            Accepted

        Just found ->
            if List.member found accepted then
                Accepted

            else if family found then
                Unaccepted ("content-type " ++ found ++ ", not " ++ String.join " or " accepted)

            else
                Foreign


{-| The answer's content type without its parameters, lowercased, whatever
the header name's case.
-}
contentType : Http.Metadata -> Maybe String
contentType metadata =
    header "content-type" metadata
        |> Maybe.map
            (\value ->
                String.split ";" value
                    |> List.head
                    |> Maybe.withDefault ""
                    |> String.trim
                    |> String.toLower
            )


{-| Bytes read as UTF-8 text; `""` when they are not UTF-8, where a browser
would write U+FFFD for what it cannot read. Only the bytes path reaches it, so a program that reads
no answer as bytes carries no elm/bytes.
-}
bytesText : Bytes -> String
bytesText raw =
    Bytes.Decode.decode (Bytes.Decode.string (Bytes.width raw)) raw
        |> Maybe.withDefault ""


{-| An answer of bytes as an error keeps it.
-}
bytesAnswer : Http.Metadata -> Bytes -> Response
bytesAnswer metadata raw =
    { url = metadata.url
    , statusCode = metadata.statusCode
    , statusText = metadata.statusText
    , headers = metadata.headers
    , body = Rpc.Body.bytes raw
    }


{-| The message of an answer whose framing, content type or status is
malformed.
-}
envelopeText : String -> String
envelopeText problem =
    "bad response: " ++ problem
