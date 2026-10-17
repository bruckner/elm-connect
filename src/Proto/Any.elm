module Proto.Any exposing
    ( Any, typeUrl, typeName, is
    , pack, packWith, unpack, Problem(..)
    , describe
    , encodeJson, jsonDecoder
    )

{-| `google.protobuf.Any`: a message of any type, with the URL naming its type.

    detail : Proto.Any.Any
    detail =
        Proto.Any.pack Notes.V1.messageNote note

    Proto.Any.unpack Notes.V1.messageNote detail
    --> Just (Ok note)

An `Any` read from proto3 JSON holds the message's JSON. One read from a Connect
error detail without its `debug` JSON holds only the message's protobuf
binary, which this package does not decode: such an `Any` still says its type,
but [`unpack`](#unpack) gives [`BinaryOnly`](#Problem).

@docs Any, typeUrl, typeName, is


# Packing and unpacking

@docs pack, packWith, unpack, Problem


# Describing

@docs describe


# JSON

@docs encodeJson, jsonDecoder

-}

import Json.Decode
import Json.Encode
import Proto.Internal.Any as Internal exposing (Payload(..))
import Proto.Message as Message exposing (Message)
import Proto.Registry as Registry exposing (Registry)


{-| A packed message and its type URL.
-}
type alias Any =
    Internal.Any


{-| The URL naming the packed message's type, such as
`type.googleapis.com/notes.v1.Note`.
-}
typeUrl : Any -> String
typeUrl (Internal.Any url _) =
    url


{-| The packed message's full name: the type URL after its last `/`, such as
`notes.v1.Note`.
-}
typeName : Any -> String
typeName (Internal.Any url _) =
    nameOf url


nameOf : String -> String
nameOf url =
    String.split "/" url
        |> List.reverse
        |> List.head
        |> Maybe.withDefault url


{-| Whether the packed message is of this type, by full name.
-}
is : Message a -> Any -> Bool
is message any =
    typeName any == Message.typeName (Message.toDescriptor message)



-- PACKING AND UNPACKING


{-| A message as an `Any`, its type URL prefixed `type.googleapis.com/`, as
protobuf's own libraries write it.
-}
pack : Message a -> a -> Any
pack message value =
    Internal.Any (Message.typeUrl (Message.toDescriptor message)) (InJson (Message.encode message value))


{-| A message as an `Any` whose type URL has another prefix:
`packWith "example.com/types" messageNote note` has the type URL
`example.com/types/notes.v1.Note`.
-}
packWith : String -> Message a -> a -> Any
packWith prefix message value =
    let
        slashed =
            if String.endsWith "/" prefix then
                prefix

            else
                prefix ++ "/"
    in
    Internal.Any (slashed ++ Message.typeName (Message.toDescriptor message)) (InJson (Message.encode message value))


{-| The packed message, if it is of this type: `Nothing` for another type,
`Just (Err problem)` for this type when it cannot be read.
-}
unpack : Message a -> Any -> Maybe (Result Problem a)
unpack message ((Internal.Any _ payload) as any) =
    if is message any then
        case payload of
            InJson json ->
                Just (Json.Decode.decodeValue (Message.decoder message) json |> Result.mapError Json)

            InBinary _ ->
                Just (Err BinaryOnly)

    else
        Nothing


{-| Why a message of the right type could not be unpacked.

  - `Json`: its JSON does not decode as the message.
  - `BinaryOnly`: only its protobuf binary arrived (a Connect error detail
    without `debug`), and this package reads JSON alone.

-}
type Problem
    = Json Json.Decode.Error
    | BinaryOnly



-- DESCRIBING


{-| The descriptor of the packed message's type, if the registry has it.
-}
describe : Registry -> Any -> Maybe Message.Descriptor
describe registry any =
    Registry.message (typeName any) registry



-- JSON


{-| The well-known types whose proto3 JSON is not an object of their fields. An
`Any` holding one writes that form under `"value"`, beside `"@type"`.
-}
withJsonForm : List String
withJsonForm =
    [ "google.protobuf.Any"
    , "google.protobuf.Timestamp"
    , "google.protobuf.Duration"
    , "google.protobuf.FieldMask"
    , "google.protobuf.Empty"
    , "google.protobuf.Struct"
    , "google.protobuf.Value"
    , "google.protobuf.ListValue"
    , "google.protobuf.DoubleValue"
    , "google.protobuf.FloatValue"
    , "google.protobuf.Int64Value"
    , "google.protobuf.UInt64Value"
    , "google.protobuf.Int32Value"
    , "google.protobuf.UInt32Value"
    , "google.protobuf.BoolValue"
    , "google.protobuf.StringValue"
    , "google.protobuf.BytesValue"
    ]


hasJsonForm : String -> Bool
hasJsonForm url =
    List.member (nameOf url) withJsonForm


{-| An `Any` in proto3 JSON: the message's own JSON object with `"@type"`
added, or `{"@type": …, "value": …}` for a well-known type with a JSON form of
its own. An `Any` holding only binary is written as Connect writes an error
detail, `{"type": "notes.v1.Note", "value": "<base64>"}`, which
[`jsonDecoder`](#jsonDecoder) does not read. The empty `Any` (no type URL,
as `Proto.Message.default Proto.WellKnown.any`) is `{}`.
-}
encodeJson : Any -> Json.Encode.Value
encodeJson ((Internal.Any url payload) as any) =
    let
        typed =
            ( "@type", Json.Encode.string url )
    in
    case payload of
        InJson json ->
            if hasJsonForm url then
                Json.Encode.object [ typed, ( "value", json ) ]

            else
                case Json.Decode.decodeValue (Json.Decode.keyValuePairs Json.Decode.value) json of
                    Ok pairs ->
                        Json.Encode.object (typed :: pairs)

                    Err _ ->
                        -- Only a hand-built record writes a message as other
                        -- than an object; this keeps its JSON whole.
                        Json.Encode.object [ typed, ( "value", json ) ]

        InBinary bytes ->
            if String.isEmpty url && String.isEmpty bytes then
                Json.Encode.object []

            else
                Json.Encode.object
                    [ ( "type", Json.Encode.string (typeName any) )
                    , ( "value", Json.Encode.string bytes )
                    ]


{-| Reads an `Any` from proto3 JSON: an object with `"@type"`, holding the
message's fields or, for a well-known type with a JSON form of its own,
`"value"`. An object without `"@type"` fails, but for `{}`, the empty `Any`.
-}
jsonDecoder : Json.Decode.Decoder Any
jsonDecoder =
    Json.Decode.keyValuePairs Json.Decode.value
        |> Json.Decode.andThen fromPairs


fromPairs : List ( String, Json.Decode.Value ) -> Json.Decode.Decoder Any
fromPairs pairs =
    case ( lookup "@type" pairs, pairs ) of
        ( Nothing, [] ) ->
            Json.Decode.succeed (Internal.Any "" (InBinary ""))

        ( Nothing, _ ) ->
            Json.Decode.fail "Expecting an Any: an object with \"@type\""

        ( Just found, _ ) ->
            case Json.Decode.decodeValue Json.Decode.string found of
                Err _ ->
                    Json.Decode.fail "Expecting an Any whose \"@type\" is a string"

                Ok url ->
                    if hasJsonForm url then
                        case lookup "value" pairs of
                            Just json ->
                                Json.Decode.succeed (Internal.Any url (InJson json))

                            Nothing ->
                                Json.Decode.fail ("Expecting an Any of " ++ nameOf url ++ " to hold \"value\"")

                    else
                        pairs
                            |> List.filter (\( key, _ ) -> key /= "@type")
                            |> Json.Encode.object
                            |> InJson
                            |> Internal.Any url
                            |> Json.Decode.succeed


lookup : String -> List ( String, a ) -> Maybe a
lookup key pairs =
    case pairs of
        [] ->
            Nothing

        ( k, v ) :: rest ->
            if k == key then
                Just v

            else
                lookup key rest
