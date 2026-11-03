module Proto.AnyTest exposing (suite)

import Bytes.Encode
import Expect
import Json.Decode
import Json.Encode
import Proto.Any as Any exposing (Any, Problem(..))
import Proto.Codec exposing (Json)
import Proto.Descriptors as Descriptors
import Proto.Duration as Duration
import Proto.Field as Field exposing (Cardinality(..), Kind(..), Scalar(..))
import Proto.Json
import Proto.Message as Message exposing (Message)
import Proto.WellKnown as WellKnown
import Test exposing (Test, describe, test)
import Time


type alias Note =
    { title : String, pinned : Bool }


{-| A message as generated code under `codec=json` gives one.
-}
messageNote : Message Json Note
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
noteAs : String -> Message Json Note
noteAs name =
    Message.initJson name
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


note : Note
note =
    { title = "groceries", pinned = True }


written : Any Json -> String
written any =
    Json.Encode.encode 0 (Proto.Json.encodeAny any)


read : String -> Result String (Any Json)
read text =
    Json.Decode.decodeString Proto.Json.any text
        |> Result.mapError Json.Decode.errorToString


{-| Through JSON and back.
-}
roundTrip : Any Json -> Result String (Any Json)
roundTrip any =
    read (written any)


{-| A problem reduced to a word.
-}
word : Result Problem a -> Result String a
word =
    Result.mapError
        (\problem ->
            case problem of
                TypeMismatch name ->
                    "type " ++ name

                InvalidProto ->
                    "proto"

                InvalidJson _ ->
                    "json"

                UnregisteredType name ->
                    "unregistered " ++ name
        )


suite : Test
suite =
    describe "Proto.Any"
        [ test "a message is its own object plus @type" <|
            \_ ->
                written (Any.packJson messageNote note)
                    |> Expect.equal """{"@type":"type.googleapis.com/notes.v1.Note","title":"groceries","pinned":true}"""
        , test "a message unpacks after a round trip through JSON" <|
            \_ ->
                roundTrip (Any.packJson messageNote note)
                    |> Result.map (Any.unpackJson messageNote)
                    |> Expect.equal (Ok (Just note))
        , test "a well-known type with a JSON form of its own is under value" <|
            \_ ->
                [ Any.packJson WellKnown.duration (Duration.fromMilliseconds 1500)
                , Any.packJson WellKnown.empty ()
                , Any.packJson WellKnown.stringValue "hi"
                ]
                    |> List.map written
                    |> Expect.equal
                        [ """{"@type":"type.googleapis.com/google.protobuf.Duration","value":"1.500s"}"""
                        , """{"@type":"type.googleapis.com/google.protobuf.Empty","value":{}}"""
                        , """{"@type":"type.googleapis.com/google.protobuf.StringValue","value":"hi"}"""
                        ]
        , test "a well-known type unpacks after a round trip through JSON" <|
            \_ ->
                roundTrip (Any.packJson WellKnown.duration (Duration.fromMilliseconds 1500))
                    |> Result.map (Any.unpackJson WellKnown.duration >> Maybe.map Duration.toMilliseconds)
                    |> Expect.equal (Ok (Just 1500))
        , test "an Any packs inside an Any" <|
            \_ ->
                let
                    packed =
                        Any.packJson WellKnown.any (Any.packJson messageNote note)
                in
                ( written packed
                , roundTrip packed
                    |> Result.map (Any.unpackJson WellKnown.any >> Maybe.andThen (Any.unpackJson messageNote))
                )
                    |> Expect.equal
                        ( """{"@type":"type.googleapis.com/google.protobuf.Any","value":{"@type":"type.googleapis.com/notes.v1.Note","title":"groceries","pinned":true}}"""
                        , Ok (Just note)
                        )
        , test "the type URL, the type name and is" <|
            \_ ->
                let
                    packed =
                        Any.packJsonWith "example.com/types" messageNote note
                in
                ( ( Any.typeUrl packed, Any.typeName packed )
                , ( Any.is messageNote packed, Any.is WellKnown.duration packed )
                , Any.typeUrl (Any.packJsonWith "example.com/" messageNote note)
                )
                    |> Expect.equal
                        ( ( "example.com/types/notes.v1.Note", "notes.v1.Note" )
                        , ( True, False )
                        , "example.com/notes.v1.Note"
                        )
        , test "unpacking another type is a TypeMismatch naming it, an undecodable one InvalidJson" <|
            \_ ->
                ( Any.tryUnpackJson WellKnown.duration (Any.packJson messageNote note) |> word
                , read """{"@type":"type.googleapis.com/notes.v1.Note","title":7}"""
                    |> Result.map (Any.tryUnpackJson messageNote >> word)
                , Any.unpackJson WellKnown.duration (Any.packJson messageNote note)
                )
                    |> Expect.equal ( Err "type notes.v1.Note", Ok (Err "json"), Nothing )
        , test "json reads the message's JSON" <|
            \_ ->
                [ Any.packJson messageNote note, Any.packJson WellKnown.stringValue "hi" ]
                    |> List.map (Any.json >> Json.Encode.encode 0)
                    |> Expect.equal [ """{"title":"groceries","pinned":true}""", "\"hi\"" ]
        , test "describe finds the type among descriptors" <|
            \_ ->
                let
                    descriptors =
                        Descriptors.union (Descriptors.fromDescriptors [ descriptorNote ] []) Descriptors.wellKnown
                in
                [ Any.packJson messageNote note
                , Any.packJson WellKnown.timestamp (Time.millisToPosix 0)
                , Any.packJsonWith "example.com" (noteAs "other.v1.Thing") note
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
                , Any.pack WellKnown.int32ValueProto 1 == Any.pack WellKnown.int32ValueProto 2
                , Any.pack WellKnown.int32ValueProto 1 == Any.pack WellKnown.int32ValueProto 1
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
        , test "a well-formed type URL of an unknown type is kept" <|
            \_ ->
                [ """{"@type":"example.com/other.v1.Thing","name":"x"}"""
                , """{"@type":"/other.v1.Thing","name":"x"}"""
                ]
                    |> List.map (read >> Result.map (\any -> ( Any.typeUrl any, Any.typeName any )))
                    |> Expect.equal
                        [ Ok ( "example.com/other.v1.Thing", "other.v1.Thing" )
                        , Ok ( "/other.v1.Thing", "other.v1.Thing" )
                        ]
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
