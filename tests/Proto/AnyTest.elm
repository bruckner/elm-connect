module Proto.AnyTest exposing (suite)

import Bytes.Encode
import Expect
import Json.Decode
import Json.Encode
import Proto.Any as Any exposing (Any)
import Proto.Binary
import Proto.Descriptors as Descriptors
import Proto.Duration as Duration
import Proto.Error exposing (Error(..))
import Proto.Field as Field exposing (Cardinality(..), Kind(..), Scalar(..))
import Proto.Json
import Proto.Message as Message exposing (Message)
import Proto.Registry as Registry exposing (Registry)
import Proto.WellKnown as WellKnown
import Test exposing (Test, describe, test)
import Time


type alias Note =
    { title : String, pinned : Bool }


{-| A message as generated code gives one.
-}
messageNote : Message Note
messageNote =
    noteAs "notes.v1.Note"


descriptorNote : Message.Descriptor
descriptorNote =
    Message.descriptor "notes.v1.Note"
        [ Field.descriptor "title" "title" 1 CardinalitySingular (KindScalar ScalarString)
        , Field.descriptor "pinned" "pinned" 2 CardinalitySingular (KindScalar ScalarBool)
        ]


{-| Note's codecs under another full name.
-}
noteAs : String -> Message Note
noteAs name =
    Message.init name encodeNote decodeNote encodeNoteBytes decodeNoteBytes


encodeNote : Note -> Json.Encode.Value
encodeNote value =
    Json.Encode.object
        [ ( "title", Json.Encode.string value.title )
        , ( "pinned", Json.Encode.bool value.pinned )
        ]


decodeNote : Json.Decode.Decoder Note
decodeNote =
    Json.Decode.map2 Note
        (Json.Decode.field "title" Json.Decode.string)
        (Json.Decode.field "pinned" Json.Decode.bool)


encodeNoteBytes : Note -> Bytes.Encode.Encoder
encodeNoteBytes value =
    Bytes.Encode.sequence
        [ Proto.Binary.implicit Proto.Binary.string 1 value.title
        , Proto.Binary.implicit Proto.Binary.bool 2 value.pinned
        ]


decodeNoteBytes : Proto.Binary.Decoder Note
decodeNoteBytes =
    Proto.Binary.merge "notes.v1.Note"
        (\number wire value ->
            case number of
                1 ->
                    Proto.Binary.field Proto.Binary.string (\v -> { value | title = v }) wire value

                2 ->
                    Proto.Binary.field Proto.Binary.bool (\v -> { value | pinned = v }) wire value

                _ ->
                    Proto.Binary.skip wire value
        )
        identity
        { title = "", pinned = False }


{-| The registry generated code gives a package of `notes.v1.Note`, with the
well-known types.
-}
registry : Registry
registry =
    Registry.empty
        |> Registry.register (Message.init "notes.v1.Note" encodeNote decodeNote encodeNoteBytes decodeNoteBytes)
        |> Registry.union WellKnown.registry


note : Note
note =
    { title = "groceries", pinned = True }


written : Any -> String
written any =
    Proto.Json.encodeAnyWith registry any
        |> Result.map (Json.Encode.encode 0)
        |> Result.withDefault "unwritable"


read : String -> Result String Any
read text =
    Json.Decode.decodeString (Proto.Json.anyWith registry) text
        |> Result.mapError Json.Decode.errorToString


{-| Through JSON and back.
-}
roundTrip : Any -> Result String Any
roundTrip any =
    read (written any)


{-| A problem reduced to a word.
-}
word : Result Error a -> Result String a
word =
    Result.mapError
        (\problem ->
            case problem of
                TypeMismatch { expected, actual } ->
                    "type " ++ actual ++ " as " ++ expected

                BadBinary binary ->
                    "binary " ++ binary.typeName

                BadJson _ ->
                    "json"

                UnregisteredType url ->
                    "unregistered " ++ url
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
                    |> Result.map (Any.unpack messageNote)
                    |> Expect.equal (Ok (Just note))
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
                    |> Result.map (Any.unpack WellKnown.duration >> Maybe.map Duration.toMilliseconds)
                    |> Expect.equal (Ok (Just 1500))
        , test "an Any packs inside an Any" <|
            \_ ->
                let
                    packed =
                        Any.pack WellKnown.any (Any.pack messageNote note)
                in
                ( written packed
                , roundTrip packed
                    |> Result.map (Any.unpack WellKnown.any >> Maybe.andThen (Any.unpack messageNote))
                )
                    |> Expect.equal
                        ( """{"@type":"type.googleapis.com/google.protobuf.Any","value":{"@type":"type.googleapis.com/notes.v1.Note","title":"groceries","pinned":true}}"""
                        , Ok (Just note)
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
        , test "unpacking another type is a TypeMismatch naming both" <|
            \_ ->
                ( Any.tryUnpack WellKnown.duration (Any.pack messageNote note) |> word
                , Any.unpack WellKnown.duration (Any.pack messageNote note)
                )
                    |> Expect.equal ( Err "type notes.v1.Note as google.protobuf.Duration", Nothing )
        , test "toJson gives the message's JSON through the registry" <|
            \_ ->
                [ Any.pack messageNote note, Any.pack WellKnown.stringValue "hi" ]
                    |> List.map (Any.toJson registry >> Result.map (Json.Encode.encode 0))
                    |> Expect.equal [ Ok """{"title":"groceries","pinned":true}""", Ok "\"hi\"" ]
        , test "describe finds the type among descriptors" <|
            \_ ->
                let
                    descriptors =
                        Descriptors.union (Descriptors.fromDescriptors [ descriptorNote ] []) WellKnown.descriptors
                in
                [ Any.pack messageNote note
                , Any.pack WellKnown.timestamp (Time.millisToPosix 0)
                , Any.packWith "example.com" (noteAs "other.v1.Thing") note
                ]
                    |> List.map (Any.describe descriptors >> Maybe.map (\found -> ( Message.fullName found, List.map Field.jsonName (Message.fields found) )))
                    |> Expect.equal
                        [ Just ( "notes.v1.Note", [ "title", "pinned" ] )
                        , Just ( "google.protobuf.Timestamp", [ "seconds", "nanos" ] )
                        , Nothing
                        ]
        , test "== on Bytes finds any two equal, so an Any compares its binary as text" <|
            \_ ->
                ( Bytes.Encode.encode (Bytes.Encode.unsignedInt8 1) == Bytes.Encode.encode (Bytes.Encode.unsignedInt8 2)
                , Any.pack WellKnown.int32Value 1 == Any.pack WellKnown.int32Value 2
                , Any.pack WellKnown.int32Value 1 == Any.pack WellKnown.int32Value 1
                )
                    |> Expect.equal ( True, False, True )
        , test "an @type that is not a type URL fails" <|
            \_ ->
                [ """{"@type":"","value":""}"""
                , """{"@type":"1","value":"2"}"""
                , """{"@type":"notes.v1.Note","title":"groceries"}"""
                , """{"@type":"type.googleapis.com/","title":"groceries"}"""
                ]
                    |> List.filter (\json -> Result.toMaybe (read json) /= Nothing)
                    |> Expect.equal []
        , test "a well-formed type URL of a type the registry lacks fails" <|
            \_ ->
                [ """{"@type":"example.com/other.v1.Thing","name":"x"}"""
                , """{"@type":"/other.v1.Thing","name":"x"}"""
                ]
                    |> List.filterMap (read >> Result.toMaybe)
                    |> Expect.equal []
        , test "an object without @type fails, but for the empty Any" <|
            \_ ->
                ( ( read """{"title":"groceries"}""" |> Result.map written
                  , read """{"@type":"type.googleapis.com/google.protobuf.Duration"}""" |> Result.map written
                  )
                , read "{}" |> Result.map (\any -> ( Any.typeUrl any, written any ))
                )
                    |> Expect.equal
                        ( ( Err "Problem with the given value:\n\n{\n        \"title\": \"groceries\"\n    }\n\nExpecting an Any: an object with \"@type\""
                          , Err "Problem with the given value:\n\n{\n        \"@type\": \"type.googleapis.com/google.protobuf.Duration\"\n    }\n\nExpecting an Any of google.protobuf.Duration to hold \"value\""
                          )
                        , Ok ( "", "{}" )
                        )
        ]
