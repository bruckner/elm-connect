module Proto.AnyBinaryTest exposing (suite)

import Bytes.Encode
import Expect
import Json.Decode
import Json.Encode
import Proto.Any as Any exposing (Any, Problem(..))
import Proto.Binary
import Proto.Bytes
import Proto.Json
import Proto.Message as Message exposing (Message)
import Proto.Registry as Registry exposing (Registry)
import Proto.WellKnown as WellKnown
import Test exposing (Test, describe, test)


decodeTitleBytes : Proto.Binary.Decoder String
decodeTitleBytes =
    Proto.Binary.merge
        (\number wire value ->
            case number of
                1 ->
                    Proto.Binary.field Proto.Binary.string identity wire value

                _ ->
                    Proto.Binary.skip wire value
        )
        identity
        ""


encodeTitleBytes : String -> Bytes.Encode.Encoder
encodeTitleBytes t =
    Bytes.Encode.sequence [ Proto.Binary.implicit Proto.Binary.string 1 t ]


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
        |> Registry.union Registry.wellKnown


{-| An `Any` written as binary and read back.
-}
throughBinary : Any -> Maybe Any
throughBinary any =
    Proto.Binary.decode (Proto.Binary.messageDecoder Proto.Binary.any) (Proto.Binary.encode (Proto.Binary.messageEncoder Proto.Binary.any) any)


{-| An `Any` as read from binary, keeping no JSON: what a registry converts.
-}
bare : Any -> Any
bare any =
    throughBinary any |> Maybe.withDefault any


base64 : Any -> String
base64 any =
    Proto.Bytes.toBase64 (Proto.Binary.encode (Proto.Binary.messageEncoder Proto.Binary.any) any)


{-| An `Any` read from proto3 JSON through a registry.
-}
readWith : Registry -> String -> Result String Any
readWith reg text =
    Json.Decode.decodeString (Proto.Json.anyWith reg) text
        |> Result.mapError Json.Decode.errorToString


writtenWith : Registry -> Any -> Result Problem String
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
        , test "binary that is not the message is InvalidProto, another type a TypeMismatch" <|
            \_ ->
                ( Proto.Bytes.fromBase64 "CiJ0eXBlLmdvb2dsZWFwaXMuY29tL25vdGVzLnYxLlRpdGxlEgIKBQ=="
                    |> Maybe.andThen (Proto.Binary.decode (Proto.Binary.messageDecoder Proto.Binary.any))
                    |> Maybe.map (Any.tryUnpack messageTitle)
                , Any.tryUnpack WellKnown.int32Value (Any.pack messageTitle "hi")
                )
                    |> Expect.equal ( Just (Err InvalidProto), Err (TypeMismatch "notes.v1.Title") )
        , test "written as proto3 JSON through the registry's entry for its type" <|
            \_ ->
                [ writtenWith registry (bare (Any.pack messageTitle "hi"))
                , writtenWith registry (bare (Any.pack WellKnown.stringValue "hi"))
                , writtenWith registry (bare (Any.pack WellKnown.any (Any.pack WellKnown.boolValue True)))
                ]
                    |> Expect.equal
                        [ Ok """{"@type":"type.googleapis.com/notes.v1.Title","title":"hi"}"""
                        , Ok """{"@type":"type.googleapis.com/google.protobuf.StringValue","value":"hi"}"""
                        , Ok """{"@type":"type.googleapis.com/google.protobuf.Any","value":{"@type":"type.googleapis.com/google.protobuf.BoolValue","value":true}}"""
                        ]
        , test "a type the registry lacks is UnregisteredType naming its URL; inside another Any, UnwritableAny naming that one's" <|
            \_ ->
                [ writtenWith Registry.wellKnown (bare (Any.pack messageTitle "hi"))
                , writtenWith Registry.wellKnown (bare (Any.pack WellKnown.any (bare (Any.pack messageTitle "hi"))))
                ]
                    |> Expect.equal [ Err (UnregisteredType "type.googleapis.com/notes.v1.Title"), Err (UnwritableAny "type.googleapis.com/google.protobuf.Any") ]
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
                ( ( readWith Registry.wellKnown """{"@type":"type.googleapis.com/notes.v1.Title","title":"hi"}""" |> Result.toMaybe
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
                , Any.toJson Registry.wellKnown (bare (Any.pack messageTitle "hi"))
                )
                    |> Expect.equal ( Just "hi", Err (Any.UnregisteredType "type.googleapis.com/notes.v1.Title") )
        , test "packed, or read from JSON, it keeps its JSON and writes that back with no registry" <|
            \_ ->
                let
                    text =
                        """{"@type":"type.googleapis.com/notes.v1.Title","title":"hi","pinned":false}"""
                in
                ( writtenWith Registry.empty (Any.pack messageTitle "hi")
                , readWith registry text |> Result.toMaybe |> Maybe.map (writtenWith Registry.empty)
                , readWith registry text |> Result.toMaybe |> Maybe.map (\any -> ( Any.unpack messageTitle any, base64 any == base64 (Any.pack messageTitle "hi") ))
                )
                    |> Expect.equal
                        ( Ok """{"@type":"type.googleapis.com/notes.v1.Title","title":"hi"}"""
                        , Just (Ok text)
                        , Just ( Just "hi", True )
                        )
        , test "a packed Any holding one with no JSON keeps none, and converts through the registry" <|
            \_ ->
                ( writtenWith Registry.wellKnown (Any.pack WellKnown.any (bare (Any.pack messageTitle "hi")))
                , writtenWith registry (Any.pack WellKnown.any (bare (Any.pack messageTitle "hi")))
                )
                    |> Expect.equal
                        ( Err (UnwritableAny "type.googleapis.com/google.protobuf.Any")
                        , Ok """{"@type":"type.googleapis.com/google.protobuf.Any","value":{"@type":"type.googleapis.com/notes.v1.Title","title":"hi"}}"""
                        )
        , test "a lenient registry reads a type it lacks as JSON alone, which unpacks and is written back as JSON" <|
            \_ ->
                let
                    text =
                        """{"@type":"type.googleapis.com/notes.v1.Title","title":"hi","extra":1}"""

                    read =
                        readWith (Registry.lenient Registry.wellKnown) text |> Result.toMaybe
                in
                ( ( readWith Registry.wellKnown text |> Result.toMaybe
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
        , test "an Any held as JSON alone is written as binary as its type URL alone, and its JSON fails to unpack as InvalidProto" <|
            \_ ->
                let
                    read =
                        readWith (Registry.lenient Registry.empty) """{"@type":"type.googleapis.com/notes.v1.Title","title":7}""" |> Result.toMaybe
                in
                ( read |> Maybe.map base64
                , read |> Maybe.andThen throughBinary |> Maybe.map (\any -> ( Any.typeUrl any, Any.bytes any |> Maybe.map Proto.Bytes.toBase64 ))
                , read |> Maybe.map (Any.tryUnpack messageTitle)
                )
                    |> Expect.equal
                        ( Just "CiJ0eXBlLmdvb2dsZWFwaXMuY29tL25vdGVzLnYxLlRpdGxl"
                        , Just ( "type.googleapis.com/notes.v1.Title", Just "" )
                        , Just (Err InvalidProto)
                        )
        , test "a known type read through a lenient registry reads an Any inside it leniently" <|
            \_ ->
                let
                    text =
                        """{"@type":"type.googleapis.com/google.protobuf.Any","value":{"@type":"type.googleapis.com/notes.v1.Title","title":"hi"}}"""

                    inner =
                        Maybe.andThen (Any.unpack WellKnown.any)
                in
                ( readWith Registry.wellKnown text |> Result.toMaybe
                , readWith (Registry.lenient Registry.wellKnown) text
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
                , reads (Registry.unionAll [ registry, Registry.wellKnown, Registry.lenient Registry.empty ])
                , reads (Registry.lenient Registry.empty |> Registry.register messageTitle)
                ]
                    |> Expect.equal [ False, False, True, True, True, True, True ]
        , test "equal compares Anys held as JSON alone by type URL and JSON text" <|
            \_ ->
                let
                    read text =
                        readWith (Registry.lenient Registry.empty) text |> Result.withDefault (Any.pack messageTitle "")
                in
                ( Any.equal (read """{"@type":"type.googleapis.com/notes.v1.Title","title":"hi"}""") (read """{"@type":"type.googleapis.com/notes.v1.Title","title":"hi"}""")
                , Any.equal (read """{"@type":"type.googleapis.com/notes.v1.Title","title":"hi"}""") (read """{"@type":"type.googleapis.com/notes.v1.Title","title":"ho"}""")
                , Any.equal (read """{"@type":"type.googleapis.com/notes.v1.Title","title":"hi"}""") (Any.pack messageTitle "hi")
                )
                    |> Expect.equal ( True, False, False )
        , test "== sees the JSON an Any keeps; equal compares the type URL and the binary alone" <|
            \_ ->
                let
                    packed =
                        Any.pack messageTitle "hi"
                in
                ( ( packed == bare packed, Any.equal packed (bare packed) )
                , ( Any.equal packed (Any.pack messageTitle "ho")
                  , Any.equal packed (Any.packWith "example.com" messageTitle "hi")
                  )
                )
                    |> Expect.equal ( ( False, True ), ( False, False ) )
        ]
