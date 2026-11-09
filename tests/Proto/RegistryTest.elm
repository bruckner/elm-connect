module Proto.RegistryTest exposing (suite)

import Bytes exposing (Bytes)
import Bytes.Encode
import Dict
import Expect
import Json.Decode
import Json.Encode exposing (Value)
import Proto.Any as Any exposing (Any, Problem)
import Proto.Binary
import Proto.Bytes
import Proto.Duration as Duration
import Proto.Internal.Any
import Proto.Json
import Proto.Message as Message exposing (Message)
import Proto.Registry as Registry exposing (Registry)
import Proto.WellKnown as WellKnown
import Test exposing (Test, describe, test)
import Time


{-| A message holding one `Any` at field 1, named `held` in JSON, with its
codecs as generated code gives them: JSON codecs taking the
registry, binary codecs without.
-}
type alias Holder =
    { held : Maybe Any }


encodeHolderWith : Registry -> Holder -> Result Problem Value
encodeHolderWith types value =
    Proto.Json.tryObjectOfFields
        [ ( "held", Proto.Json.tryOptionalField (Proto.Json.encodeAnyWith types) value.held ) ]


decodeHolderWith : Registry -> Json.Decode.Decoder Holder
decodeHolderWith types =
    Json.Decode.succeed Holder
        |> Proto.Json.field "held" Nothing (Json.Decode.map Just (Proto.Json.anyWith types))


encodeHolderBytes : Holder -> Bytes.Encode.Encoder
encodeHolderBytes value =
    Bytes.Encode.sequence [ Proto.Binary.optional Proto.Binary.any 1 value.held ]


decodeHolderBytes : Proto.Binary.Decoder Holder
decodeHolderBytes =
    Proto.Binary.merge
        (\number wire value ->
            case number of
                1 ->
                    Proto.Binary.field Proto.Binary.any (\v -> { value | held = Just v }) wire value

                _ ->
                    Proto.Binary.skip wire value
        )
        identity
        { held = Nothing }


{-| The holder registered under `name`.
-}
holder : String -> Registry -> Registry
holder name =
    Registry.register (messageHolder name)


messageHolder : String -> Message Holder
messageHolder name =
    Message.initWith name encodeHolderWith decodeHolderWith encodeHolderBytes decodeHolderBytes


{-| A message holding no `Any`: a string at field 1, `{"text": …}` in JSON.
-}
leaf : String -> Registry -> Registry
leaf name =
    Registry.register
        (Message.init name
            (\t -> Json.Encode.object [ ( "text", Json.Encode.string t ) ])
            (Json.Decode.field "text" Json.Decode.string)
            (\t -> Bytes.Encode.sequence [ Proto.Binary.implicit Proto.Binary.string 1 t ])
            leafBytes
        )


leafBytes : Proto.Binary.Decoder String
leafBytes =
    Proto.Binary.merge
        (\number wire value ->
            if number == 1 then
                Proto.Binary.field Proto.Binary.string identity wire value

            else
                Proto.Binary.skip wire value
        )
        identity
        ""


messageLeaf : String -> Message String
messageLeaf name =
    Message.init name
        (\t -> Json.Encode.object [ ( "text", Json.Encode.string t ) ])
        (Json.Decode.field "text" Json.Decode.string)
        (\t -> Bytes.Encode.sequence [ Proto.Binary.implicit Proto.Binary.string 1 t ])
        leafBytes


{-| The proto3 JSON of a message's binary, by full name, through the
registry, as an `Any` of it converts.
-}
json : Registry -> String -> Bytes -> Maybe String
json registry name binary =
    Any.toJson registry (Proto.Internal.Any.Any ("type.googleapis.com/" ++ name) (Proto.Internal.Any.Binary (Proto.Internal.Any.held binary)))
        |> Result.toMaybe
        |> Maybe.map (Json.Encode.encode 0)


{-| The binary of a message's proto3 JSON object, by full name, through the
registry, as an `Any` of it converts.
-}
bytes : Registry -> String -> List ( String, Value ) -> Maybe String
bytes registry name fields =
    Json.Decode.decodeValue (Proto.Json.anyWith registry)
        (Json.Encode.object (( "@type", Json.Encode.string ("type.googleapis.com/" ++ name) ) :: fields))
        |> Result.toMaybe
        |> Maybe.andThen Any.bytes
        |> Maybe.map Proto.Bytes.toBase64


suite : Test
suite =
    describe "Proto.Registry"
        [ test "an entry converts both ways, by full name" <|
            \_ ->
                let
                    registry =
                        leaf "t.Leaf" Registry.empty

                    binary =
                        Proto.Binary.encode (\t -> Bytes.Encode.sequence [ Proto.Binary.implicit Proto.Binary.string 1 t ]) "hi"
                in
                ( json registry "t.Leaf" binary
                , bytes registry "t.Leaf" [ ( "text", Json.Encode.string "hi" ) ]
                )
                    |> Expect.equal ( Just """{"text":"hi"}""", Just (Proto.Bytes.toBase64 binary) )
        , test "a type the registry has no entry for converts in neither direction" <|
            \_ ->
                ( json (leaf "t.Leaf" Registry.empty) "t.Other" (Proto.Binary.encode (\_ -> Bytes.Encode.sequence []) ())
                , bytes Registry.empty "t.Leaf" []
                )
                    |> Expect.equal ( Nothing, Nothing )
        , test "a nested Any converts through the table in use, at every depth" <|
            \_ ->
                let
                    -- core.Core holds an Any of ext.Ext, which holds an Any
                    -- of ext2.Leaf; only the wide table knows ext2.Leaf.
                    core =
                        holder "core.Core" Registry.empty

                    ext =
                        holder "ext.Ext" Registry.empty

                    wide =
                        Registry.unionAll [ core, ext, leaf "ext2.Leaf" Registry.empty ]

                    packed =
                        Any.pack (messageHolder "core.Core")
                            { held = Just (Any.pack (messageHolder "ext.Ext") { held = Just (Any.pack (messageLeaf "ext2.Leaf") "deep") }) }

                    -- Read back from binary, so that it keeps no JSON.
                    bare =
                        Proto.Binary.encode (Proto.Binary.messageEncoder Proto.Binary.any) packed
                            |> Proto.Binary.decode (Proto.Binary.messageDecoder Proto.Binary.any)
                            |> Maybe.withDefault packed

                    written registry =
                        Proto.Json.encodeAnyWith registry bare |> Result.map (Json.Encode.encode 0)

                    expected =
                        """{"@type":"type.googleapis.com/core.Core","held":{"@type":"type.googleapis.com/ext.Ext","held":{"@type":"type.googleapis.com/ext2.Leaf","text":"deep"}}}"""
                in
                ( written wide
                , written (Registry.unionAll [ core, ext ])
                , Result.toMaybe (written wide)
                    |> Maybe.andThen (Json.Decode.decodeString (Proto.Json.anyWith wide) >> Result.toMaybe)
                    |> Maybe.map (Any.equal packed)
                )
                    |> Expect.equal ( Ok expected, Err (Any.UnwritableAny "type.googleapis.com/core.Core"), Just True )
        , test "a missing type is named by its URL, and binary that is not the message is InvalidProto" <|
            \_ ->
                ( Proto.Json.encodeAnyWith Registry.empty (Proto.Internal.Any.Any "type.googleapis.com/t.Leaf" (Proto.Internal.Any.Binary (Proto.Internal.Any.held <| Maybe.withDefault Proto.Bytes.empty (Proto.Bytes.fromBase64 "CgJoaQ=="))))
                , Any.toJson (leaf "t.Leaf" Registry.empty) (Proto.Internal.Any.Any "type.googleapis.com/t.Leaf" (Proto.Internal.Any.Binary (Proto.Internal.Any.held <| Maybe.withDefault Proto.Bytes.empty (Proto.Bytes.fromBase64 "/w=="))))
                , Json.Decode.decodeString (Proto.Json.anyWith Registry.empty) """{"@type":"example.com/t.Leaf","text":"hi"}"""
                    |> Result.mapError (Json.Decode.errorToString >> String.contains "\"example.com/t.Leaf\"")
                )
                    |> Expect.equal ( Err (Any.UnregisteredType "type.googleapis.com/t.Leaf"), Err Any.InvalidProto, Err True )
        , test "of two entries for one name, union keeps the left one's and unionAll the earlier one's" <|
            \_ ->
                let
                    binary =
                        Proto.Binary.encode (\t -> Bytes.Encode.sequence [ Proto.Binary.implicit Proto.Binary.string 1 t ]) "hi"

                    other =
                        Registry.register
                            (Message.init "t.Leaf"
                                (\_ -> Json.Encode.string "other")
                                (Json.Decode.succeed "")
                                (\_ -> Bytes.Encode.sequence [])
                                leafBytes
                            )
                            Registry.empty
                in
                [ json (Registry.union (leaf "t.Leaf" Registry.empty) other) "t.Leaf" binary
                , json (Registry.union other (leaf "t.Leaf" Registry.empty)) "t.Leaf" binary
                , json (Registry.unionAll [ other, leaf "t.Leaf" Registry.empty ]) "t.Leaf" binary
                , json (Registry.unionAll []) "t.Leaf" binary
                ]
                    |> Expect.equal [ Just """{"text":"hi"}""", Just "\"other\"", Just "\"other\"", Nothing ]
        , test "the well-known types convert with their own JSON forms" <|
            \_ ->
                [ Any.pack WellKnown.duration (Duration.fromMilliseconds 1500)
                , Any.pack WellKnown.timestamp (Time.millisToPosix 0)
                , Any.pack WellKnown.empty ()
                , Any.pack WellKnown.fieldMask [ "a.b", "c" ]
                , Any.pack WellKnown.struct (Dict.fromList [ ( "k", Json.Encode.int 1 ) ])
                , Any.pack WellKnown.int64Value "5"
                ]
                    |> List.map (Proto.Json.encodeAnyWith Registry.wellKnown >> Result.map (Json.Encode.encode 0))
                    |> Expect.equal
                        [ Ok """{"@type":"type.googleapis.com/google.protobuf.Duration","value":"1.500s"}"""
                        , Ok """{"@type":"type.googleapis.com/google.protobuf.Timestamp","value":"1970-01-01T00:00:00Z"}"""
                        , Ok """{"@type":"type.googleapis.com/google.protobuf.Empty","value":{}}"""
                        , Ok """{"@type":"type.googleapis.com/google.protobuf.FieldMask","value":"a.b,c"}"""
                        , Ok """{"@type":"type.googleapis.com/google.protobuf.Struct","value":{"k":1}}"""
                        , Ok """{"@type":"type.googleapis.com/google.protobuf.Int64Value","value":"5"}"""
                        ]
        ]
