module Proto.AnyTest exposing (suite)

import Expect
import Json.Decode
import Json.Encode
import Proto.Any as Any exposing (Any, Problem(..))
import Proto.Duration as Duration exposing (Duration)
import Proto.Field as Field exposing (Cardinality(..), Kind(..), Scalar(..))
import Proto.Message as Message exposing (Message)
import Proto.Registry as Registry
import Proto.WellKnown as WellKnown
import Test exposing (Test, describe, test)


type alias Note =
    { title : String, pinned : Bool }


{-| A message as generated code gives one.
-}
messageNote : Message Note
messageNote =
    noteAs descriptorNote


descriptorNote : Message.Descriptor
descriptorNote =
    Message.descriptor "notes.v1.Note"
        [ Field.descriptor "title" "title" 1 CardinalitySingular (KindScalar ScalarString)
        , Field.descriptor "pinned" "pinned" 2 CardinalitySingular (KindScalar ScalarBool)
        ]


{-| Note's codecs under another descriptor.
-}
noteAs : Message.Descriptor -> Message Note
noteAs =
    Message.message
        (\value ->
            Json.Encode.object
                [ ( "title", Json.Encode.string value.title )
                , ( "pinned", Json.Encode.bool value.pinned )
                ]
        )
        (Json.Decode.map2 Note
            (Json.Decode.field "title" Json.Decode.string)
            (Json.Decode.field "pinned" Json.Decode.bool)
        )
        { title = "", pinned = False }


note : Note
note =
    { title = "groceries", pinned = True }


written : Any -> String
written any =
    Json.Encode.encode 0 (Any.encodeJson any)


read : String -> Result String Any
read text =
    Json.Decode.decodeString Any.jsonDecoder text
        |> Result.mapError Json.Decode.errorToString


{-| Through JSON and back.
-}
roundTrip : Any -> Result String Any
roundTrip any =
    read (written any)


{-| An unpacked result with its decode error, if any, reduced to a word.
-}
outcome : Maybe (Result Problem a) -> Maybe (Result String a)
outcome =
    Maybe.map
        (Result.mapError
            (\problem ->
                case problem of
                    Json _ ->
                        "json"

                    BinaryOnly ->
                        "binary only"
            )
        )


suite : Test
suite =
    describe "Proto.Any"
        [ test "a message is its own object plus @type" <|
            \_ ->
                written (Any.pack messageNote note)
                    |> Expect.equal """{"@type":"type.googleapis.com/notes.v1.Note","title":"groceries","pinned":true}"""
        , test "a message unpacks after a round trip through JSON" <|
            \_ ->
                roundTrip (Any.pack messageNote note)
                    |> Result.map (Any.unpack messageNote >> outcome)
                    |> Expect.equal (Ok (Just (Ok note)))
        , test "a well-known type with a JSON form of its own is under value" <|
            \_ ->
                [ Any.pack WellKnown.duration (Duration.fromMilliseconds 1500)
                , Any.pack WellKnown.empty ()
                , Any.pack WellKnown.stringValue "hi"
                ]
                    |> List.map written
                    |> Expect.equal
                        [ """{"@type":"type.googleapis.com/google.protobuf.Duration","value":"1.500s"}"""
                        , """{"@type":"type.googleapis.com/google.protobuf.Empty","value":{}}"""
                        , """{"@type":"type.googleapis.com/google.protobuf.StringValue","value":"hi"}"""
                        ]
        , test "a well-known type unpacks after a round trip through JSON" <|
            \_ ->
                roundTrip (Any.pack WellKnown.duration (Duration.fromMilliseconds 1500))
                    |> Result.map (Any.unpack WellKnown.duration >> outcome >> Maybe.map (Result.map Duration.milliseconds))
                    |> Expect.equal (Ok (Just (Ok 1500)))
        , test "an Any packs inside an Any" <|
            \_ ->
                let
                    packed =
                        Any.pack WellKnown.any (Any.pack messageNote note)
                in
                ( written packed
                , roundTrip packed
                    |> Result.map (Any.unpack WellKnown.any >> Maybe.andThen Result.toMaybe >> Maybe.andThen (Any.unpack messageNote) >> outcome)
                )
                    |> Expect.equal
                        ( """{"@type":"type.googleapis.com/google.protobuf.Any","value":{"@type":"type.googleapis.com/notes.v1.Note","title":"groceries","pinned":true}}"""
                        , Ok (Just (Ok note))
                        )
        , test "the type URL, the type name and is" <|
            \_ ->
                let
                    packed =
                        Any.packWith "example.com/types" messageNote note
                in
                ( ( Any.typeUrl packed, Any.typeName packed )
                , ( Any.is messageNote packed, Any.is WellKnown.duration packed )
                , Any.typeUrl (Any.packWith "example.com/" messageNote note)
                )
                    |> Expect.equal
                        ( ( "example.com/types/notes.v1.Note", "notes.v1.Note" )
                        , ( True, False )
                        , "example.com/notes.v1.Note"
                        )
        , test "unpacking another type is Nothing, an undecodable one a Json problem" <|
            \_ ->
                ( Any.unpack WellKnown.duration (Any.pack messageNote note) |> outcome
                , read """{"@type":"type.googleapis.com/notes.v1.Note","title":7}"""
                    |> Result.map (Any.unpack messageNote >> outcome)
                )
                    |> Expect.equal ( Nothing, Ok (Just (Err "json")) )
        , test "describe finds the type in a registry" <|
            \_ ->
                let
                    registry =
                        Registry.union (Registry.fromDescriptors [ descriptorNote ] []) Registry.wellKnown
                in
                [ Any.pack messageNote note
                , Any.pack WellKnown.timestamp (Message.default WellKnown.timestamp)
                , Any.packWith "example.com" (noteAs (Message.descriptor "other.v1.Thing" [])) note
                ]
                    |> List.map (Any.describe registry >> Maybe.map (\found -> ( Message.typeName found, List.map Field.jsonName (Message.fields found) )))
                    |> Expect.equal
                        [ Just ( "notes.v1.Note", [ "title", "pinned" ] )
                        , Just ( "google.protobuf.Timestamp", [ "seconds", "nanos" ] )
                        , Nothing
                        ]
        , test "an object without @type fails, but for the empty Any" <|
            \_ ->
                ( ( read """{"title":"groceries"}""" |> Result.map written
                  , read """{"@type":"type.googleapis.com/google.protobuf.Duration"}""" |> Result.map written
                  )
                , ( read "{}" |> Result.map Any.typeUrl
                  , written (Message.default WellKnown.any)
                  )
                )
                    |> Expect.equal
                        ( ( Err "Problem with the given value:\n\n{\n        \"title\": \"groceries\"\n    }\n\nExpecting an Any: an object with \"@type\""
                          , Err "Problem with the given value:\n\n{\n        \"@type\": \"type.googleapis.com/google.protobuf.Duration\"\n    }\n\nExpecting an Any of google.protobuf.Duration to hold \"value\""
                          )
                        , ( Ok "", "{}" )
                        )
        ]
