module Proto.AnyBinaryTest exposing (suite)

import Bytes.Encode
import Expect
import Json.Decode
import Json.Encode
import Proto.Any as Any exposing (Any)
import Proto.Binary
import Proto.Bytes
import Proto.Error exposing (Error(..), Reason(..))
import Proto.Json
import Proto.Message as Message exposing (Message)
import Proto.Registry as Registry exposing (Registry)
import Proto.WellKnown as WellKnown
import Test exposing (Test, describe, test)


decodeTitleBytes : Proto.Binary.Decoder String
decodeTitleBytes =
    Proto.Binary.merge "notes.v1.Title"
        (\number wire value ->
            case number of
                1 ->
                    Proto.Binary.field Proto.Binary.string identity wire value

                _ ->
                    Proto.Binary.skip wire value
        )
        identity
        ""


encodeTitleBytes : String -> Proto.Binary.Encoder
encodeTitleBytes t =
    Proto.Binary.sequence [ Proto.Binary.implicit Proto.Binary.string 1 t ]


encodeTitle : String -> Json.Encode.Value
encodeTitle t =
    Json.Encode.object [ ( "title", Json.Encode.string t ) ]


decodeTitle : Json.Decode.Decoder String
decodeTitle =
    Json.Decode.field "title" Json.Decode.string


{-| A message as generated code gives one.
-}
messageTitle : Message String
messageTitle =
    Message.init "notes.v1.Title" encodeTitle decodeTitle encodeTitleBytes decodeTitleBytes


{-| The registry generated code gives a package of
`notes.v1.Title`, with the well-known types.
-}
registry : Registry
registry =
    Registry.empty
        |> Registry.register messageTitle
        |> Registry.union WellKnown.registry


{-| An `Any` written as binary and read back.
-}
throughBinary : Any -> Maybe Any
throughBinary any =
    Proto.Binary.decode (Proto.Binary.messageDecoder Proto.Binary.any) (Proto.Binary.encode (Proto.Binary.messageEncoder Proto.Binary.any) any)
        |> Result.toMaybe


base64 : Any -> String
base64 any =
    Proto.Bytes.toBase64 (Proto.Binary.encode (Proto.Binary.messageEncoder Proto.Binary.any) any)


{-| An `Any` read from proto3 JSON through a registry.
-}
readWith : Registry -> String -> Result String Any
readWith reg text =
    Json.Decode.decodeString (Proto.Json.anyWith reg) text
        |> Result.mapError Json.Decode.errorToString


{-| An `Any` of `notes.v1.Title` whose binary stops inside its field 1.
-}
badTitle : Maybe Any
badTitle =
    Proto.Bytes.fromBase64 "CiJ0eXBlLmdvb2dsZWFwaXMuY29tL25vdGVzLnYxLlRpdGxlEgIKBQ=="
        |> Maybe.andThen (Proto.Binary.decode (Proto.Binary.messageDecoder Proto.Binary.any) >> Result.toMaybe)


truncatedTitle : Proto.Error.Binary
truncatedTitle =
    { typeName = "notes.v1.Title", reason = Truncated, path = [ ( "notes.v1.Title", 1 ) ], offset = 1 }


{-| Whether a result failed with `BadJson`.
-}
isBadJson : Result Error a -> Bool
isBadJson result =
    case result of
        Err (BadJson _) ->
            True

        _ ->
            False


writtenWith : Registry -> Any -> Result Error String
writtenWith reg any =
    Proto.Json.encodeAnyWith reg any |> Result.map (Json.Encode.encode 0)


suite : Test
suite =
    describe "Proto.Any holding binary"
        [ test "a packed message survives a binary round trip" <|
            \_ ->
                Any.pack messageTitle "hi"
                    |> throughBinary
                    |> Maybe.andThen (Any.unpack messageTitle)
                    |> Expect.equal (Just "hi")
        , test "bytes reads the message's binary" <|
            \_ ->
                Any.pack messageTitle "hi"
                    |> Any.bytes
                    |> Maybe.map Proto.Bytes.toBase64
                    |> Expect.equal (Just "CgJoaQ==")
        , test "binary that is not the message is its BadBinary, another type a TypeMismatch" <|
            \_ ->
                ( Maybe.map (Any.tryUnpack messageTitle) badTitle
                , Any.tryUnpack WellKnown.int32Value (Any.pack messageTitle "hi")
                )
                    |> Expect.equal
                        ( Just (Err (BadBinary truncatedTitle))
                        , Err (TypeMismatch { expected = "google.protobuf.Int32Value", actual = "notes.v1.Title" })
                        )
        , test "written as proto3 JSON through the registry's entry for its type" <|
            \_ ->
                [ writtenWith registry (Any.pack messageTitle "hi")
                , writtenWith registry (Any.pack WellKnown.stringValue "hi")
                , writtenWith registry (Any.pack WellKnown.any (Any.pack WellKnown.boolValue True))
                ]
                    |> Expect.equal
                        [ Ok """{"@type":"type.googleapis.com/notes.v1.Title","title":"hi"}"""
                        , Ok """{"@type":"type.googleapis.com/google.protobuf.StringValue","value":"hi"}"""
                        , Ok """{"@type":"type.googleapis.com/google.protobuf.Any","value":{"@type":"type.googleapis.com/google.protobuf.BoolValue","value":true}}"""
                        ]
        , test "a type the registry lacks is UnregisteredType naming its URL, at any depth" <|
            \_ ->
                [ writtenWith WellKnown.registry (Any.pack messageTitle "hi")
                , writtenWith WellKnown.registry (Any.pack WellKnown.any (Any.pack messageTitle "hi"))
                ]
                    |> Expect.equal [ Err (UnregisteredType "type.googleapis.com/notes.v1.Title"), Err (UnregisteredType "type.googleapis.com/notes.v1.Title") ]
        , test "binary that is not its message, inside another Any, is that message's BadBinary" <|
            \_ ->
                ( Maybe.map (writtenWith registry) badTitle
                , Maybe.map (Any.pack WellKnown.any >> writtenWith registry) badTitle
                )
                    |> Expect.equal ( Just (Err (BadBinary truncatedTitle)), Just (Err (BadBinary truncatedTitle)) )
        , test "read from proto3 JSON through the registry, as its binary" <|
            \_ ->
                [ """{"@type":"type.googleapis.com/google.protobuf.Timestamp","value":"2026-01-02T03:04:05Z"}"""
                , """{"@type":"type.googleapis.com/google.protobuf.StringValue","value":"hi"}"""
                , """{"@type":"type.googleapis.com/google.protobuf.Any","value":{"@type":"type.googleapis.com/google.protobuf.BoolValue","value":true}}"""
                , """{"@type":"type.googleapis.com/notes.v1.Title","title":"hi"}"""
                ]
                    |> List.map (readWith registry >> Result.map base64)
                    |> Expect.equal
                        [ Ok "Ci10eXBlLmdvb2dsZWFwaXMuY29tL2dvb2dsZS5wcm90b2J1Zi5UaW1lc3RhbXASBgil69zKBg=="
                        , Ok "Ci90eXBlLmdvb2dsZWFwaXMuY29tL2dvb2dsZS5wcm90b2J1Zi5TdHJpbmdWYWx1ZRIECgJoaQ=="
                        , Ok "Cid0eXBlLmdvb2dsZWFwaXMuY29tL2dvb2dsZS5wcm90b2J1Zi5BbnkSMwotdHlwZS5nb29nbGVhcGlzLmNvbS9nb29nbGUucHJvdG9idWYuQm9vbFZhbHVlEgIIAQ=="
                        , Ok (base64 (Any.pack messageTitle "hi"))
                        ]
        , test "reading a type the registry lacks, or JSON not its message, fails; {} is the empty Any" <|
            \_ ->
                ( ( readWith WellKnown.registry """{"@type":"type.googleapis.com/notes.v1.Title","title":"hi"}""" |> Result.toMaybe
                  , readWith registry """{"@type":"type.googleapis.com/notes.v1.Title","title":7}""" |> Result.toMaybe
                  )
                , readWith registry "{}" |> Result.map (\any -> ( Any.typeUrl any, writtenWith registry any ))
                )
                    |> Expect.equal ( ( Nothing, Nothing ), Ok ( "", Ok "{}" ) )
        , test "toJson converts through the registry, UnregisteredType for a type it lacks" <|
            \_ ->
                ( Any.toJson registry (Any.pack messageTitle "hi")
                    |> Result.toMaybe
                    |> Maybe.andThen (Json.Decode.decodeValue decodeTitle >> Result.toMaybe)
                , Any.toJson WellKnown.registry (Any.pack messageTitle "hi")
                )
                    |> Expect.equal ( Just "hi", Err (UnregisteredType "type.googleapis.com/notes.v1.Title") )
        , test "a lenient registry reads a type it lacks as JSON alone, which unpacks and is written back as JSON" <|
            \_ ->
                let
                    text =
                        """{"@type":"type.googleapis.com/notes.v1.Title","title":"hi","extra":1}"""

                    read =
                        readWith (Registry.lenient WellKnown.registry) text |> Result.toMaybe
                in
                ( ( readWith WellKnown.registry text |> Result.toMaybe
                  , read |> Maybe.map Any.bytes
                  , read |> Maybe.andThen (Any.unpack messageTitle)
                  )
                , ( read |> Maybe.map (writtenWith Registry.empty)
                  , read |> Maybe.map (Any.toJson Registry.empty >> Result.map (Json.Encode.encode 0))
                  , readWith (Registry.lenient registry) """{"@type":"type.googleapis.com/notes.v1.Title","title":7}""" |> Result.toMaybe
                  )
                )
                    |> Expect.equal
                        ( ( Nothing, Just Nothing, Just "hi" )
                        , ( Just (Ok text), Just (Ok """{"title":"hi","extra":1}"""), Nothing )
                        )
        , test "an Any held as JSON alone is written as binary as its type URL alone, and its JSON fails to unpack as its BadJson" <|
            \_ ->
                let
                    read =
                        readWith (Registry.lenient Registry.empty) """{"@type":"type.googleapis.com/notes.v1.Title","title":7}""" |> Result.toMaybe
                in
                ( read |> Maybe.map base64
                , read |> Maybe.andThen throughBinary |> Maybe.map (\any -> ( Any.typeUrl any, Any.bytes any |> Maybe.map Proto.Bytes.toBase64 ))
                , read |> Maybe.map (Any.tryUnpack messageTitle >> isBadJson)
                )
                    |> Expect.equal
                        ( Just "CiJ0eXBlLmdvb2dsZWFwaXMuY29tL25vdGVzLnYxLlRpdGxl"
                        , Just ( "type.googleapis.com/notes.v1.Title", Just "" )
                        , Just True
                        )
        , test "a known type read through a lenient registry reads an Any inside it leniently" <|
            \_ ->
                let
                    text =
                        """{"@type":"type.googleapis.com/google.protobuf.Any","value":{"@type":"type.googleapis.com/notes.v1.Title","title":"hi"}}"""

                    inner =
                        Maybe.andThen (Any.unpack WellKnown.any)
                in
                ( readWith WellKnown.registry text |> Result.toMaybe
                , readWith (Registry.lenient WellKnown.registry) text
                    |> Result.toMaybe
                    |> (\read -> ( Maybe.map Any.bytes (inner read) |> Maybe.map ((==) Nothing), inner read |> Maybe.andThen (Any.unpack messageTitle), Maybe.map (writtenWith Registry.empty) read ))
                )
                    |> Expect.equal ( Nothing, ( Just True, Just "hi", Just (Ok text) ) )
        , test "packing a message that holds an Any held as JSON alone holds the packed one as JSON alone too" <|
            \_ ->
                let
                    packed =
                        readWith (Registry.lenient Registry.empty) """{"@type":"type.googleapis.com/notes.v1.Title","title":"hi"}"""
                            |> Result.toMaybe
                            |> Maybe.map (Any.pack WellKnown.any)
                in
                ( packed |> Maybe.map Any.bytes
                , packed |> Maybe.andThen (Any.unpack WellKnown.any) |> Maybe.andThen (Any.unpack messageTitle)
                , packed |> Maybe.map (writtenWith Registry.empty)
                )
                    |> Expect.equal
                        ( Just Nothing
                        , Just "hi"
                        , Just (Ok """{"@type":"type.googleapis.com/google.protobuf.Any","value":{"@type":"type.googleapis.com/notes.v1.Title","title":"hi"}}""")
                        )
        , test "registries are strict until made lenient, and a union is lenient when any side is" <|
            \_ ->
                let
                    reads table =
                        readWith table """{"@type":"type.googleapis.com/x.Unknown","a":1}""" |> Result.toMaybe |> (/=) Nothing
                in
                [ reads Registry.empty
                , reads registry
                , reads (Registry.lenient Registry.empty)
                , reads (Registry.union registry (Registry.lenient Registry.empty))
                , reads (Registry.union (Registry.lenient Registry.empty) registry)
                , reads (Registry.unionAll [ registry, WellKnown.registry, Registry.lenient Registry.empty ])
                , reads (Registry.lenient Registry.empty |> Registry.register messageTitle)
                ]
                    |> Expect.equal [ False, False, True, True, True, True, True ]
        , test "== compares content: an Any read from JSON equals the same one read from binary or packed, and so does a message holding it" <|
            \_ ->
                let
                    packed =
                        Any.pack messageTitle "hi"

                    fromJson =
                        readWith registry """{"@type":"type.googleapis.com/notes.v1.Title","title":"hi","pinned":false}"""
                            |> Result.toMaybe

                    fromBinary =
                        throughBinary packed
                in
                ( ( Maybe.map2 (==) fromJson fromBinary, Maybe.map ((==) packed) fromJson )
                , Maybe.map2 (\json binary -> Any.pack WellKnown.any json == Any.pack WellKnown.any binary) fromJson fromBinary
                , Maybe.map ((==) (Any.pack messageTitle "ho")) fromJson
                )
                    |> Expect.equal ( ( Just True, Just True ), Just True, Just False )
        , test "an Any held as JSON alone never equals one holding binary; two compare by their JSON" <|
            \_ ->
                let
                    read text =
                        readWith (Registry.lenient Registry.empty) text |> Result.toMaybe

                    hi =
                        read """{"@type":"type.googleapis.com/notes.v1.Title","title":"hi"}"""
                in
                ( Maybe.map ((==) (Any.pack messageTitle "hi")) hi
                , Maybe.map2 (==) hi (read """{"@type":"type.googleapis.com/notes.v1.Title","title":"hi"}""")
                , Maybe.map2 (==) hi (read """{"@type":"type.googleapis.com/notes.v1.Title","title":"ho"}""")
                )
                    |> Expect.equal ( Just False, Just True, Just False )
        ]
