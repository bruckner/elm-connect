module Proto.Method exposing
    ( Method, method, withBinary, methodBinary
    , encodeRequest, responseDecoder, toDescriptor, encodeRequestBytes, responseBytesDecoder, hasJson
    , Descriptor, descriptor
    , service, name, idempotency, input, output, bindings
    , Idempotency(..)
    )

{-| A method: its typed value, which holds the codecs of its request and
response and its descriptor, and its descriptor, what the proto says about it
as data. Generated code builds the descriptor once per method in its
service's module (`Notes.V1.NotesService.descriptorGetNote : Descriptor`) and
gives the typed value to [`Rpc.call`](Rpc#call).

The descriptor's idempotency is a union whose constructors carry its name as a
prefix (`IdempotencyNoSideEffects`), so it can be exposed with `(..)` beside
any other union.

@docs Method, method, withBinary, methodBinary


# Reading a typed value

@docs encodeRequest, responseDecoder, toDescriptor, encodeRequestBytes, responseBytesDecoder, hasJson


# Descriptors

@docs Descriptor, descriptor


# Reading a descriptor

@docs service, name, idempotency, input, output, bindings


# Unions

@docs Idempotency

-}

import Bytes
import Bytes.Decode
import Bytes.Encode
import Dict
import Http
import Json.Decode
import Json.Encode
import Proto.Binary
import Proto.Bytes
import Proto.Http exposing (Binding)
import Proto.Internal.Method as Internal exposing (Read(..))


{-| A method taking a `req` and answering a `res`. It is opaque: built by
[`method`](#method) and read by the functions below. The package site and
compiler errors may show it as `Proto.Internal.Method.Method`, its name
inside the package.

It holds what sending a call needs: the request's encoder, the response's
decoder and the method's descriptor. The types'
[`Message`](Proto-Message#Message) values, with their defaults and field
trees, are not part of it.

-}
type alias Method req res =
    Internal.Method Descriptor req res


{-| A method from its request's proto3 JSON encoder, its response's proto3
JSON decoder and its descriptor. Generated code writes:

    descriptorGetNote =
        Proto.Method.descriptor "notes.v1.NotesService"
            "GetNote"
            Proto.Method.IdempotencyNoSideEffects
            "notes.v1.GetNoteRequest"
            "notes.v1.Note"
            [ Proto.Http.binding { … } ]

    getNote =
        Rpc.call
            (Proto.Method.method Notes.V1.encodeGetNoteRequest
                Notes.V1.decodeNote
                descriptorGetNote
            )

-}
method : (req -> Json.Encode.Value) -> Json.Decode.Decoder res -> Descriptor -> Method req res
method encode decoder methodDescriptor =
    Internal.Method
        { encodeRequest = encode
        , responseDecoder = decoder
        , descriptor = methodDescriptor
        , binary = Nothing
        , json = True
        }


{-| The method with protobuf binary codecs too, as generated code under
`codec=both` writes it:

    getNote =
        Rpc.call
            (Proto.Method.method Notes.V1.encodeGetNoteRequest
                Notes.V1.decodeNote
                descriptorGetNote
                |> Proto.Method.withBinary
                    Notes.V1.encodeGetNoteRequestBytes
                    Notes.V1.decodeNoteBytes
            )

-}
withBinary : (req -> Bytes.Encode.Encoder) -> Proto.Binary.Decoder res -> Method req res -> Method req res
withBinary encodeBinary binaryDecoder (Internal.Method m) =
    Internal.Method { m | binary = Just (binary encodeBinary binaryDecoder (output m.descriptor)) }


{-| A method with protobuf binary codecs alone, as generated code under
`codec=binary` writes it. Its JSON encoder writes `null` and its JSON decoder
fails, so its calls are for Connect's protobuf binary codec, not for
transcoding.
-}
methodBinary : (req -> Bytes.Encode.Encoder) -> Proto.Binary.Decoder res -> Descriptor -> Method req res
methodBinary encodeBinary binaryDecoder methodDescriptor =
    Internal.Method
        { encodeRequest = \_ -> Json.Encode.null
        , responseDecoder = Json.Decode.fail (name methodDescriptor ++ " was generated with protobuf binary codecs alone (codec=binary)")
        , descriptor = methodDescriptor
        , binary = Just (binary encodeBinary binaryDecoder (output methodDescriptor))
        , json = False
        }


{-| The binary codecs and the bytes path Connect's proto codec takes with
them. They are built here, under `withBinary`, so that a program without
binary codecs carries none of that code, nor elm/bytes': a single
`Bytes.width` on the path every call takes would bring its kernel whole.
-}
binary : (req -> Bytes.Encode.Encoder) -> Proto.Binary.Decoder res -> String -> Internal.Binary req res
binary encodeBinary binaryDecoder responseName =
    { encodeRequest = encodeBinary
    , responseDecoder = binaryDecoder
    , message =
        \value ->
            let
                bytes =
                    Proto.Binary.encode encodeBinary value
            in
            { bytes = bytes, base64Url = \() -> base64Url (Proto.Bytes.toBase64 bytes) }
    , tooLarge =
        \limit value ->
            limit
                |> Maybe.andThen
                    (\most ->
                        let
                            size =
                                Bytes.width (Proto.Binary.encode encodeBinary value)
                        in
                        if size > max 0 most then
                            Just { limit = most, size = size }

                        else
                            Nothing
                    )
    , read = read binaryDecoder responseName
    , base64 = Proto.Bytes.toBase64
    }


{-| A 200 must come as `application/proto` or with no content type; every
other answer is text.
-}
read : Proto.Binary.Decoder res -> String -> Maybe Int -> Http.Response Bytes.Bytes -> Read res
read binaryDecoder responseName limit answer =
    case answer of
        Http.GoodStatus_ metadata raw ->
            if metadata.statusCode /= 200 then
                AsText (Http.GoodStatus_ metadata (text raw))

            else
                case contentType metadata of
                    Just other ->
                        if other == "application/proto" then
                            readBinary binaryDecoder responseName limit metadata raw

                        else
                            NotBinary ("content-type " ++ other ++ ", not application/proto") metadata raw

                    Nothing ->
                        readBinary binaryDecoder responseName limit metadata raw

        Http.BadStatus_ metadata raw ->
            AsText (Http.BadStatus_ metadata (text raw))

        Http.BadUrl_ url ->
            AsText (Http.BadUrl_ url)

        Http.Timeout_ ->
            AsText Http.Timeout_

        Http.NetworkError_ ->
            AsText Http.NetworkError_


readBinary : Proto.Binary.Decoder res -> String -> Maybe Int -> Http.Metadata -> Bytes.Bytes -> Read res
readBinary binaryDecoder responseName limit metadata raw =
    let
        size =
            Bytes.width raw
    in
    case limit of
        Just most ->
            if size > max 0 most then
                TooLong { limit = most, size = size }

            else
                decodeBinary binaryDecoder responseName metadata raw

        Nothing ->
            decodeBinary binaryDecoder responseName metadata raw


decodeBinary : Proto.Binary.Decoder res -> String -> Http.Metadata -> Bytes.Bytes -> Read res
decodeBinary binaryDecoder responseName metadata raw =
    case Proto.Binary.decode binaryDecoder raw of
        Just value ->
            Read value

        Nothing ->
            NotBinary ("the body is not a " ++ responseName ++ " in protobuf binary") metadata raw


{-| Bytes as UTF-8 text; `""` when they are not UTF-8.
-}
text : Bytes.Bytes -> String
text raw =
    Bytes.Decode.decode (Bytes.Decode.string (Bytes.width raw)) raw
        |> Maybe.withDefault ""


{-| The answer's content type without its parameters, lowercased, whatever
the header name's case.
-}
contentType : Http.Metadata -> Maybe String
contentType metadata =
    metadata.headers
        |> Dict.toList
        |> List.filter (\( k, _ ) -> String.toLower k == "content-type")
        |> List.head
        |> Maybe.map
            (\( _, value ) ->
                String.split ";" value
                    |> List.head
                    |> Maybe.withDefault ""
                    |> String.trim
                    |> String.toLower
            )


{-| Base64 in the URL-safe alphabet without padding, as Connect's GET carries
binary.
-}
base64Url : String -> String
base64Url =
    String.foldr
        (\char done ->
            case char of
                '+' ->
                    String.cons '-' done

                '/' ->
                    String.cons '_' done

                '=' ->
                    done

                _ ->
                    String.cons char done
        )
        ""


{-| The request's protobuf binary encoder, when the method has one.
-}
encodeRequestBytes : Method req res -> Maybe (req -> Bytes.Encode.Encoder)
encodeRequestBytes (Internal.Method m) =
    Maybe.map .encodeRequest m.binary


{-| The response's protobuf binary decoder, when the method has one.
-}
responseBytesDecoder : Method req res -> Maybe (Proto.Binary.Decoder res)
responseBytesDecoder (Internal.Method m) =
    Maybe.map .responseDecoder m.binary


{-| Whether the method has proto3 JSON codecs: `False` for one built with
[`methodBinary`](#methodBinary), whose calls only Connect's proto codec
([`Rpc.Transport.withCodec`](Rpc-Transport#withCodec)) can send.
-}
hasJson : Method req res -> Bool
hasJson (Internal.Method m) =
    m.json


{-| A request as proto3 JSON.
-}
encodeRequest : Method req res -> req -> Json.Encode.Value
encodeRequest (Internal.Method m) =
    m.encodeRequest


{-| The response's proto3 JSON decoder.
-}
responseDecoder : Method req res -> Json.Decode.Decoder res
responseDecoder (Internal.Method m) =
    m.responseDecoder


{-| What the proto says about the method: its service and name, idempotency,
the full names of its types, and its HTTP bindings, read by the functions
below.
-}
toDescriptor : Method req res -> Descriptor
toDescriptor (Internal.Method m) =
    m.descriptor


{-| A method's descriptor: its service and name, its idempotency, its types
and its HTTP bindings. It is opaque, built by [`descriptor`](#descriptor) and
read by the functions below.
-}
type Descriptor
    = Descriptor
        { service : String
        , name : String
        , idempotency : Idempotency
        , input : String
        , output : String
        , bindings : List Binding
        }


{-| A method's `idempotency_level`, as `google.protobuf.MethodOptions` declares
it:

  - `IdempotencyUnknown`: not declared, so the method may have side effects.
  - `IdempotencyNoSideEffects`: it changes nothing, so Connect may send it as
    a GET, and a retry policy for idempotent calls may retry it.
  - `IdempotencyIdempotent`: calling it again has no further effect, so a
    retry policy for idempotent calls may retry it, but it is never a GET.

-}
type Idempotency
    = IdempotencyUnknown
    | IdempotencyNoSideEffects
    | IdempotencyIdempotent


{-| A method: the full name of its service (`notes.v1.NotesService`), its name
as declared (`GetNote`), its idempotency, the full names of its request and
response types, and its `google.api.http` rule as
[`Proto.Http`](Proto-Http) data, the rule's own binding first and then its
`additional_bindings` in order (`[]` for a method without one).
-}
descriptor : String -> String -> Idempotency -> String -> String -> List Binding -> Descriptor
descriptor serviceName methodName level inputType outputType methodBindings =
    Descriptor
        { service = serviceName
        , name = methodName
        , idempotency = level
        , input = inputType
        , output = outputType
        , bindings = methodBindings
        }


{-| The full name of its service, such as `notes.v1.NotesService`.
-}
service : Descriptor -> String
service (Descriptor m) =
    m.service


{-| The method's name as declared, such as `GetNote`. With the service, its
Connect path.
-}
name : Descriptor -> String
name (Descriptor m) =
    m.name


{-| Its declared `idempotency_level`.
-}
idempotency : Descriptor -> Idempotency
idempotency (Descriptor m) =
    m.idempotency


{-| The full name of its request type, such as `notes.v1.GetNoteRequest`.
-}
input : Descriptor -> String
input (Descriptor m) =
    m.input


{-| The full name of its response type, such as `notes.v1.Note`.
-}
output : Descriptor -> String
output (Descriptor m) =
    m.output


{-| Its `google.api.http` rule: the rule's own binding first, then its
`additional_bindings` in order; `[]` for a method without one.
-}
bindings : Descriptor -> List Binding
bindings (Descriptor m) =
    m.bindings
