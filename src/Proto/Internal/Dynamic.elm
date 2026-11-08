module Proto.Internal.Dynamic exposing
    ( Dynamic
    , Table
    , Value(..)
    , compile
    , decodeBinary
    , decodeJson
    , encodeBinary
    , encodeJson
    , names
    , toBytes
    , toJson
    )

{-| A message of any type as data, read and written by walking its
descriptor rather than through generated codecs: proto3 JSON and protobuf
binary, the well-known types' JSON forms included. `Proto.Registry` builds a
registry from it, so that an `Any` converts between its two forms with
descriptors alone.

A message is its fields by number. A field without presence is kept
whatever its value and left out on writing at its default; a field with
presence (a message, a proto3 `optional` field, a oneof member) is kept when
set. Unknown fields are skipped when read. Each choice below follows the
generated codecs: an enum number the enum does not declare reads as its zero
value, a `Timestamp`'s JSON form holds milliseconds, a map's entries are
written in the order the generated `Dict` keeps them.

-}

import Bytes exposing (Bytes)
import Bytes.Decode
import Bytes.Encode as E exposing (Encoder)
import Dict exposing (Dict)
import Json.Decode as JD exposing (Decoder)
import Json.Encode as JE
import Proto.Binary as Binary exposing (Codec)
import Proto.Descriptors as Descriptors exposing (Descriptors)
import Proto.Duration
import Proto.Enum as Enum
import Proto.EnumValue as EnumValue
import Proto.Field as Field exposing (Cardinality(..), Kind(..), Scalar(..))
import Proto.Internal.Any as InternalAny
import Proto.Internal.Registry exposing (Registry)
import Proto.Json
import Proto.Message as Message
import Time



-- VALUES


{-| A message: its set fields, by number.
-}
type alias Dynamic =
    Dict Int Value


{-| One field's value. 32-bit integers are `Int`s, 64-bit ones decimal
text, `bytes` base64 text, an enum its number, a map's entries keyed by
`MapKey`.
-}
type Value
    = VInt Int
    | VWide String
    | VFloat Float
    | VBool Bool
    | VString String
    | VBytes String
    | VEnum Int
    | VMessage Dynamic
    | VList (List Value)
    | VMap (Dict MapKey Value)


{-| A map key in the generated `Dict`'s order: an integer key by its
number, a 64-bit or string key by its text, `False` before `True`.
-}
type alias MapKey =
    ( Int, String )



-- THE TABLE


{-| Each message's descriptor, indexed for the walk, by full name.
-}
type alias Table =
    Dict String Compiled


type alias Compiled =
    { name : String
    , fields : List Field.Descriptor
    , ascending : List Field.Descriptor
    , byNumber : Dict Int Field.Descriptor
    , plain : List Field.Descriptor
    , oneofs : List ( String, List Field.Descriptor )
    , siblings : Dict Int (List Int)
    }


{-| Index every message of the descriptors.
-}
compile : Descriptors -> Table
compile descriptors =
    Descriptors.messages descriptors
        |> List.map (\m -> ( Message.fullName m, compileMessage m ))
        |> Dict.fromList


compileMessage : Message.Descriptor -> Compiled
compileMessage m =
    let
        fields =
            Message.fields m

        oneofs =
            Message.oneofs m
                |> List.map (\o -> ( o, List.filter (\f -> Field.oneof f == Just o) fields ))
    in
    { name = Message.fullName m
    , fields = fields
    , ascending = List.sortBy Field.number fields
    , byNumber = Dict.fromList (List.map (\f -> ( Field.number f, f )) fields)
    , plain = List.filter (\f -> Field.oneof f == Nothing) fields
    , oneofs = oneofs
    , siblings =
        oneofs
            |> List.concatMap
                (\( _, members ) ->
                    List.map (\f -> ( Field.number f, List.map Field.number members )) members
                )
            |> Dict.fromList
    }


{-| The full names of the table's messages.
-}
names : Table -> List String
names =
    Dict.keys



-- CONVERTING


{-| A message's binary from its proto3 JSON, by full name.
-}
toBytes : Registry -> Table -> String -> JE.Value -> Maybe Bytes
toBytes registry table name json =
    JD.decodeValue (decodeJson registry table name) json
        |> Result.toMaybe
        |> Maybe.map (encodeBinary table name >> E.encode)


{-| A message's proto3 JSON from its binary, by full name.
-}
toJson : Registry -> Table -> String -> Bytes -> Maybe JE.Value
toJson registry table name bytes =
    Binary.decode (decodeBinary table name) bytes
        |> Maybe.andThen (encodeJson registry table name)



-- BINARY


{-| Read a message of this full name from protobuf binary.
-}
decodeBinary : Table -> String -> Binary.Decoder Dynamic
decodeBinary table name =
    mergeBinary table name Dict.empty


mergeBinary : Table -> String -> Dynamic -> Binary.Decoder Dynamic
mergeBinary table name start =
    case Dict.get name table of
        Just c ->
            Binary.merge (step table c) finish start

        Nothing ->
            Binary.merge (\_ _ _ -> Bytes.Decode.fail) finish start


{-| Lists are read onto their front; `finish` turns them the right way.
-}
finish : Dynamic -> Dynamic
finish =
    Dict.map
        (\_ v ->
            case v of
                VList vs ->
                    VList (List.reverse vs)

                _ ->
                    v
        )


step : Table -> Compiled -> Int -> Int -> Dynamic -> Bytes.Decode.Decoder ( Int, Dynamic )
step table c number wire acc =
    case Dict.get number c.byNumber of
        Nothing ->
            Binary.skip wire acc

        Just f ->
            let
                codec =
                    kindCodec table (Field.kind f)
            in
            case Field.cardinality f of
                CardinalityRepeated ->
                    Binary.repeated codec (\vs -> Dict.insert number (VList vs) acc) (listAt number acc) wire acc

                CardinalityMap keyScalar ->
                    Binary.mapEntry (scalarCodec keyScalar)
                        codec
                        (\key v -> Dict.insert number (VMap (Dict.insert (mapKey key) v (mapAt number acc))) acc)
                        wire
                        acc

                _ ->
                    case Field.kind f of
                        KindMessage _ ->
                            Binary.fieldInto codec (Dict.get number acc) (\v -> set c number v acc) wire acc

                        _ ->
                            Binary.field codec (\v -> set c number v acc) wire acc


set : Compiled -> Int -> Value -> Dynamic -> Dynamic
set c number v acc =
    let
        cleared =
            case Dict.get number c.siblings of
                Just members ->
                    List.foldl Dict.remove acc members

                Nothing ->
                    acc
    in
    Dict.insert number v cleared


listAt : Int -> Dynamic -> List Value
listAt number acc =
    case Dict.get number acc of
        Just (VList vs) ->
            vs

        _ ->
            []


mapAt : Int -> Dynamic -> Dict MapKey Value
mapAt number acc =
    case Dict.get number acc of
        Just (VMap d) ->
            d

        _ ->
            Dict.empty


mapKey : Value -> MapKey
mapKey v =
    case v of
        VInt i ->
            ( i, "" )

        VBool b ->
            ( if b then
                1

              else
                0
            , ""
            )

        VWide s ->
            ( 0, s )

        VString s ->
            ( 0, s )

        _ ->
            ( 0, "" )


keyValue : Scalar -> MapKey -> Value
keyValue scalar ( i, s ) =
    case scalar of
        ScalarBool ->
            VBool (i == 1)

        ScalarString ->
            VString s

        ScalarInt64 ->
            VWide s

        ScalarUint64 ->
            VWide s

        ScalarSint64 ->
            VWide s

        ScalarFixed64 ->
            VWide s

        ScalarSfixed64 ->
            VWide s

        _ ->
            VInt i


kindCodec : Table -> Kind -> Codec Value
kindCodec table kind =
    case kind of
        KindScalar s ->
            scalarCodec s

        KindEnum e ->
            enumCodec e

        KindMessage name ->
            messageCodec table name


messageCodec : Table -> String -> Codec Value
messageCodec table name =
    Binary.embedded (asMessage >> encodeBinary table name)
        (\v -> Binary.map VMessage (mergeBinary table name (asMessage v)))
        (VMessage Dict.empty)


enumCodec : Enum.Descriptor -> Codec Value
enumCodec e =
    let
        declared =
            List.map EnumValue.number (Enum.values e)
    in
    Binary.mapCodec VEnum
        asInt
        (Binary.enum identity
            (\n ->
                if List.member n declared then
                    n

                else
                    0
            )
        )


scalarCodec : Scalar -> Codec Value
scalarCodec scalar =
    case scalar of
        ScalarDouble ->
            Binary.mapCodec VFloat asFloat Binary.double

        ScalarFloat ->
            Binary.mapCodec VFloat asFloat Binary.float

        ScalarInt32 ->
            Binary.mapCodec VInt asInt Binary.int32

        ScalarUint32 ->
            Binary.mapCodec VInt asInt Binary.uint32

        ScalarSint32 ->
            Binary.mapCodec VInt asInt Binary.sint32

        ScalarFixed32 ->
            Binary.mapCodec VInt asInt Binary.fixed32

        ScalarSfixed32 ->
            Binary.mapCodec VInt asInt Binary.sfixed32

        ScalarInt64 ->
            Binary.mapCodec VWide asWide Binary.int64

        ScalarUint64 ->
            Binary.mapCodec VWide asWide Binary.uint64

        ScalarSint64 ->
            Binary.mapCodec VWide asWide Binary.sint64

        ScalarFixed64 ->
            Binary.mapCodec VWide asWide Binary.fixed64

        ScalarSfixed64 ->
            Binary.mapCodec VWide asWide Binary.sfixed64

        ScalarBool ->
            Binary.mapCodec VBool asBool Binary.bool

        ScalarString ->
            Binary.mapCodec VString asString Binary.string

        ScalarBytes ->
            Binary.mapCodec VBytes asBytes Binary.bytes


{-| Write a message of this full name as protobuf binary, its fields in
number order.
-}
encodeBinary : Table -> String -> Dynamic -> Encoder
encodeBinary table name dynamic =
    case Dict.get name table of
        Nothing ->
            E.sequence []

        Just c ->
            E.sequence (List.filterMap (writeField table dynamic) c.ascending)


writeField : Table -> Dynamic -> Field.Descriptor -> Maybe Encoder
writeField table dynamic f =
    Dict.get (Field.number f) dynamic
        |> Maybe.map
            (\v ->
                let
                    number =
                        Field.number f

                    codec =
                        kindCodec table (Field.kind f)
                in
                case ( Field.cardinality f, v ) of
                    ( CardinalityRepeated, VList vs ) ->
                        if Field.unpacked f then
                            Binary.listUnpacked codec number vs

                        else
                            Binary.list codec number vs

                    ( CardinalityMap keyScalar, VMap entries ) ->
                        let
                            keyCodec =
                                scalarCodec keyScalar
                        in
                        entries
                            |> Dict.toList
                            |> List.map
                                (\( key, item ) ->
                                    Binary.present Binary.bytesAsBytes
                                        number
                                        (E.encode
                                            (E.sequence
                                                [ Binary.implicit keyCodec 1 (keyValue keyScalar key)
                                                , Binary.implicit codec 2 item
                                                ]
                                            )
                                        )
                                )
                            |> E.sequence

                    _ ->
                        if hasPresence f then
                            Binary.present codec number v

                        else
                            Binary.implicit codec number v
            )


hasPresence : Field.Descriptor -> Bool
hasPresence f =
    Field.oneof f
        /= Nothing
        || Field.cardinality f
        == CardinalityOptional
        || (case Field.kind f of
                KindMessage _ ->
                    True

                _ ->
                    False
           )



-- JSON


{-| Read a message of this full name from proto3 JSON. An `Any` it holds
converts through the registry.
-}
decodeJson : Registry -> Table -> String -> Decoder Dynamic
decodeJson registry table name =
    case wellKnownDecoder registry name of
        Just decoder ->
            decoder

        Nothing ->
            case Dict.get name table of
                Just c ->
                    objectDecoder registry table c

                Nothing ->
                    JD.fail ("Expecting a message the descriptors have, but got " ++ name)


objectDecoder : Registry -> Table -> Compiled -> Decoder Dynamic
objectDecoder registry table c =
    let
        withPlain =
            List.foldl
                (\f acc -> JD.map2 (insertFound (Field.number f)) (plainField registry table f) acc)
                (JD.succeed Dict.empty)
                c.plain
    in
    List.foldl
        (\( oneofName, members ) acc ->
            JD.map2
                (\found dynamic ->
                    case found of
                        Just ( number, v ) ->
                            Dict.insert number v dynamic

                        Nothing ->
                            dynamic
                )
                (Proto.Json.members oneofName Nothing (List.map (oneofMember registry table) members))
                acc
        )
        withPlain
        c.oneofs


insertFound : Int -> Maybe Value -> Dynamic -> Dynamic
insertFound number found dynamic =
    case found of
        Just v ->
            Dict.insert number v dynamic

        Nothing ->
            dynamic


plainField : Registry -> Table -> Field.Descriptor -> Decoder (Maybe Value)
plainField registry table f =
    if isKind "google.protobuf.Value" f && isSingular f then
        Proto.Json.valueFieldEither (Field.jsonName f) (Field.name f) (JD.succeed identity)
            |> JD.map (Maybe.map (valueOfJson >> VMessage))

    else
        Proto.Json.fieldEither (Field.jsonName f) (Field.name f) Nothing (JD.map Just (fieldDecoder registry table f)) (JD.succeed identity)


oneofMember : Registry -> Table -> Field.Descriptor -> Proto.Json.Member (Maybe ( Int, Value ))
oneofMember registry table f =
    let
        number =
            Field.number f
    in
    if isKind "google.protobuf.Value" f then
        Proto.Json.valueMemberEither (Field.jsonName f) (Field.name f) (\json -> Just ( number, VMessage (valueOfJson json) ))

    else if isNullValue (Field.kind f) then
        Proto.Json.nullValueMemberEither (Field.jsonName f) (Field.name f) (Just ( number, VEnum 0 ))

    else
        Proto.Json.memberEither (Field.jsonName f) (Field.name f) (JD.map (\v -> Just ( number, v )) (kindDecoder registry table (Field.kind f)))


isSingular : Field.Descriptor -> Bool
isSingular f =
    case Field.cardinality f of
        CardinalityRepeated ->
            False

        CardinalityMap _ ->
            False

        _ ->
            True


isKind : String -> Field.Descriptor -> Bool
isKind name f =
    Field.kind f == KindMessage name


isNullValue : Kind -> Bool
isNullValue kind =
    case kind of
        KindEnum e ->
            Enum.typeName e == "google.protobuf.NullValue"

        _ ->
            False


fieldDecoder : Registry -> Table -> Field.Descriptor -> Decoder Value
fieldDecoder registry table f =
    let
        element =
            kindDecoder registry table (Field.kind f)
    in
    case Field.cardinality f of
        CardinalityRepeated ->
            JD.map VList (JD.list element)

        CardinalityMap keyScalar ->
            JD.map VMap (mapDecoder keyScalar element)

        _ ->
            element


mapDecoder : Scalar -> Decoder Value -> Decoder (Dict MapKey Value)
mapDecoder keyScalar element =
    let
        intKeys =
            JD.map (Dict.foldl (\k v -> Dict.insert ( k, "" ) v) Dict.empty)

        textKeys =
            JD.map (Dict.foldl (\k v -> Dict.insert ( 0, k ) v) Dict.empty)
    in
    case keyScalar of
        ScalarString ->
            textKeys (Proto.Json.stringDict element)

        ScalarBool ->
            JD.map
                (List.foldl
                    (\( k, v ) ->
                        Dict.insert
                            ( if k then
                                1

                              else
                                0
                            , ""
                            )
                            v
                    )
                    Dict.empty
                )
                (Proto.Json.boolMap element)

        ScalarUint32 ->
            intKeys (Proto.Json.uint32Dict element)

        ScalarFixed32 ->
            intKeys (Proto.Json.uint32Dict element)

        ScalarUint64 ->
            textKeys (Proto.Json.uint64Dict element)

        ScalarFixed64 ->
            textKeys (Proto.Json.uint64Dict element)

        ScalarInt64 ->
            textKeys (Proto.Json.int64Dict element)

        ScalarSint64 ->
            textKeys (Proto.Json.int64Dict element)

        ScalarSfixed64 ->
            textKeys (Proto.Json.int64Dict element)

        _ ->
            intKeys (Proto.Json.int32Dict element)


kindDecoder : Registry -> Table -> Kind -> Decoder Value
kindDecoder registry table kind =
    case kind of
        KindScalar s ->
            scalarDecoder s

        KindEnum e ->
            if isNullValue kind then
                JD.map (\() -> VEnum 0) Proto.Json.nullValue

            else
                JD.map VEnum
                    (Proto.Json.enum (Enum.typeName e)
                        0
                        (List.map (\v -> ( EnumValue.name v, EnumValue.number v, EnumValue.number v )) (Enum.values e))
                    )

        KindMessage name ->
            JD.map VMessage (JD.lazy (\() -> decodeJson registry table name))


scalarDecoder : Scalar -> Decoder Value
scalarDecoder scalar =
    case scalar of
        ScalarDouble ->
            JD.map VFloat Proto.Json.float

        ScalarFloat ->
            JD.map VFloat Proto.Json.float32

        ScalarInt32 ->
            JD.map VInt Proto.Json.int32

        ScalarSint32 ->
            JD.map VInt Proto.Json.int32

        ScalarSfixed32 ->
            JD.map VInt Proto.Json.int32

        ScalarUint32 ->
            JD.map VInt Proto.Json.uint32

        ScalarFixed32 ->
            JD.map VInt Proto.Json.uint32

        ScalarInt64 ->
            JD.map VWide Proto.Json.int64

        ScalarSint64 ->
            JD.map VWide Proto.Json.int64

        ScalarSfixed64 ->
            JD.map VWide Proto.Json.int64

        ScalarUint64 ->
            JD.map VWide Proto.Json.uint64

        ScalarFixed64 ->
            JD.map VWide Proto.Json.uint64

        ScalarBool ->
            JD.map VBool JD.bool

        ScalarString ->
            JD.map VString Proto.Json.string

        ScalarBytes ->
            JD.map VBytes Proto.Json.bytes


{-| The decoder of a well-known type's own JSON form, by full name.
-}
wellKnownDecoder : Registry -> String -> Maybe (Decoder Dynamic)
wellKnownDecoder registry name =
    case name of
        "google.protobuf.Any" ->
            Just
                (Proto.Json.anyWith registry
                    |> JD.map (\(InternalAny.Any url base64) -> Dict.fromList [ ( 1, VString url ), ( 2, VBytes base64 ) ])
                )

        "google.protobuf.Timestamp" ->
            Just
                (Proto.Json.timestamp
                    |> JD.map
                        (\posix ->
                            let
                                millis =
                                    Time.posixToMillis posix

                                seconds =
                                    floor (toFloat millis / 1000)
                            in
                            parts seconds ((millis - seconds * 1000) * 1000000)
                        )
                )

        "google.protobuf.Duration" ->
            Just (Proto.Json.duration |> JD.map (Proto.Duration.toParts >> (\p -> parts p.seconds p.nanos)))

        "google.protobuf.FieldMask" ->
            Just (Proto.Json.fieldMask |> JD.map (\paths -> Dict.singleton 1 (VList (List.map VString paths))))

        "google.protobuf.Empty" ->
            Just (Proto.Json.empty |> JD.map (\() -> Dict.empty))

        "google.protobuf.Struct" ->
            Just (Proto.Json.struct |> JD.map structOfJson)

        "google.protobuf.Value" ->
            Just (JD.map valueOfJson JD.value)

        "google.protobuf.ListValue" ->
            Just (Proto.Json.listValue |> JD.map listOfJson)

        _ ->
            wrapperScalar name
                |> Maybe.map (\s -> scalarDecoder s |> JD.map (Dict.singleton 1))


parts : Int -> Int -> Dynamic
parts seconds nanos =
    Dict.fromList [ ( 1, VWide (String.fromInt seconds) ), ( 2, VInt nanos ) ]


wrapperScalar : String -> Maybe Scalar
wrapperScalar name =
    case name of
        "google.protobuf.DoubleValue" ->
            Just ScalarDouble

        "google.protobuf.FloatValue" ->
            Just ScalarFloat

        "google.protobuf.Int64Value" ->
            Just ScalarInt64

        "google.protobuf.UInt64Value" ->
            Just ScalarUint64

        "google.protobuf.Int32Value" ->
            Just ScalarInt32

        "google.protobuf.UInt32Value" ->
            Just ScalarUint32

        "google.protobuf.BoolValue" ->
            Just ScalarBool

        "google.protobuf.StringValue" ->
            Just ScalarString

        "google.protobuf.BytesValue" ->
            Just ScalarBytes

        _ ->
            Nothing


type Json
    = JNull
    | JBool Bool
    | JNumber Float
    | JString String
    | JArray (List JE.Value)
    | JObject (Dict String JE.Value)


classify : Decoder Json
classify =
    JD.oneOf
        [ JD.null JNull
        , JD.map JBool JD.bool
        , JD.map JNumber JD.float
        , JD.map JString JD.string
        , JD.map JArray (JD.list JD.value)
        , JD.map JObject (JD.dict JD.value)
        ]


{-| A `google.protobuf.Value` from any JSON.
-}
valueOfJson : JE.Value -> Dynamic
valueOfJson json =
    case JD.decodeValue classify json of
        Ok (JBool b) ->
            Dict.singleton 4 (VBool b)

        Ok (JNumber x) ->
            Dict.singleton 2 (VFloat x)

        Ok (JString s) ->
            Dict.singleton 3 (VString s)

        Ok (JArray items) ->
            Dict.singleton 6 (VMessage (listOfJson items))

        Ok (JObject members) ->
            Dict.singleton 5 (VMessage (structOfJson members))

        _ ->
            Dict.singleton 1 (VEnum 0)


structOfJson : Dict String JE.Value -> Dynamic
structOfJson members =
    Dict.singleton 1 (VMap (Dict.foldl (\k v -> Dict.insert ( 0, k ) (VMessage (valueOfJson v))) Dict.empty members))


listOfJson : List JE.Value -> Dynamic
listOfJson items =
    Dict.singleton 1 (VList (List.map (valueOfJson >> VMessage) items))


{-| Write a message of this full name as proto3 JSON, leaving out each field
at its default: `Nothing` when an `Any` it holds cannot be written through
the registry.
-}
encodeJson : Registry -> Table -> String -> Dynamic -> Maybe JE.Value
encodeJson registry table name dynamic =
    case wellKnownEncoder registry name dynamic of
        Just written ->
            written

        Nothing ->
            case Dict.get name table of
                Just c ->
                    c.fields
                        |> traverse
                            (\f ->
                                case Dict.get (Field.number f) dynamic of
                                    Nothing ->
                                        Just ( Field.jsonName f, Nothing )

                                    Just v ->
                                        fieldJson registry table f v
                                            |> Maybe.map (Tuple.pair (Field.jsonName f))
                            )
                        |> Maybe.map Proto.Json.objectOfFields

                Nothing ->
                    Nothing


fieldJson : Registry -> Table -> Field.Descriptor -> Value -> Maybe (Maybe JE.Value)
fieldJson registry table f v =
    let
        element =
            kindJson registry table (Field.kind f)
    in
    case ( Field.cardinality f, v ) of
        ( CardinalityRepeated, VList [] ) ->
            Just Nothing

        ( CardinalityRepeated, VList vs ) ->
            traverse element vs |> Maybe.map (JE.list identity >> Just)

        ( CardinalityMap keyScalar, VMap entries ) ->
            if Dict.isEmpty entries then
                Just Nothing

            else
                Dict.toList entries
                    |> traverse (\( key, item ) -> element item |> Maybe.map (\json -> ( keyText keyScalar key, Just json )))
                    |> Maybe.map (Proto.Json.objectOfFields >> Just)

        _ ->
            if not (hasPresence f) && isDefault v then
                Just Nothing

            else
                element v |> Maybe.map Just


{-| A map key's JSON object key.
-}
keyText : Scalar -> MapKey -> String
keyText scalar key =
    case keyValue scalar key of
        VBool b ->
            if b then
                "true"

            else
                "false"

        VInt i ->
            String.fromInt i

        VWide s ->
            s

        VString s ->
            s

        _ ->
            ""


kindJson : Registry -> Table -> Kind -> Value -> Maybe JE.Value
kindJson registry table kind v =
    case kind of
        KindEnum e ->
            if isNullValue kind then
                Just JE.null

            else
                let
                    n =
                        asInt v
                in
                Enum.values e
                    |> List.filter (\ev -> EnumValue.number ev == n)
                    |> List.head
                    |> Maybe.map (EnumValue.name >> JE.string)
                    |> Maybe.withDefault (JE.int n)
                    |> Just

        KindMessage name ->
            encodeJson registry table name (asMessage v)

        KindScalar _ ->
            Just (scalarJson v)


scalarJson : Value -> JE.Value
scalarJson v =
    case v of
        VInt i ->
            JE.int i

        VWide s ->
            Proto.Json.encodeInt64 s

        VFloat x ->
            Proto.Json.encodeFloat x

        VBool b ->
            JE.bool b

        VString s ->
            JE.string s

        VBytes b ->
            Proto.Json.encodeBytes b

        VEnum n ->
            JE.int n

        _ ->
            JE.null


wellKnownEncoder : Registry -> String -> Dynamic -> Maybe (Maybe JE.Value)
wellKnownEncoder registry name dynamic =
    case name of
        "google.protobuf.Any" ->
            Just
                (Proto.Json.encodeAnyWith registry (InternalAny.Any (stringAt 1 dynamic) (bytesAt 2 dynamic))
                    |> Result.toMaybe
                )

        "google.protobuf.Timestamp" ->
            Just
                (Just
                    (Proto.Json.encodeTimestamp
                        (Time.millisToPosix (wideAt 1 dynamic * 1000 + floor (toFloat (intAt 2 dynamic) / 1.0e6)))
                    )
                )

        "google.protobuf.Duration" ->
            Just (Just (Proto.Json.encodeDuration (Proto.Duration.fromParts (wideAt 1 dynamic) (intAt 2 dynamic))))

        "google.protobuf.FieldMask" ->
            Just (Just (Proto.Json.encodeFieldMask (List.map asString (listAt 1 dynamic))))

        "google.protobuf.Empty" ->
            Just (Just (JE.object []))

        "google.protobuf.Struct" ->
            Just (Just (structJson dynamic))

        "google.protobuf.Value" ->
            Just (Just (valueJson dynamic))

        "google.protobuf.ListValue" ->
            Just (Just (listJson dynamic))

        _ ->
            wrapperScalar name
                |> Maybe.map
                    (\s ->
                        Dict.get 1 dynamic
                            |> Maybe.withDefault (scalarZero s)
                            |> scalarJson
                            |> Just
                    )


scalarZero : Scalar -> Value
scalarZero scalar =
    case scalar of
        ScalarDouble ->
            VFloat 0

        ScalarFloat ->
            VFloat 0

        ScalarInt64 ->
            VWide "0"

        ScalarUint64 ->
            VWide "0"

        ScalarBool ->
            VBool False

        ScalarString ->
            VString ""

        ScalarBytes ->
            VBytes ""

        _ ->
            VInt 0


{-| A `google.protobuf.Value` as JSON; one with no kind set is `null`.
-}
valueJson : Dynamic -> JE.Value
valueJson dynamic =
    case Dict.toList dynamic of
        ( 2, VFloat x ) :: _ ->
            JE.float x

        ( 3, VString s ) :: _ ->
            JE.string s

        ( 4, VBool b ) :: _ ->
            JE.bool b

        ( 5, VMessage struct ) :: _ ->
            structJson struct

        ( 6, VMessage list ) :: _ ->
            listJson list

        _ ->
            JE.null


structJson : Dynamic -> JE.Value
structJson dynamic =
    Proto.Json.encodeStruct
        (Dict.foldl (\( _, k ) v -> Dict.insert k (valueJson (asMessage v))) Dict.empty (mapAt 1 dynamic))


listJson : Dynamic -> JE.Value
listJson dynamic =
    JE.list (asMessage >> valueJson) (listAt 1 dynamic)



-- READING VALUES


isDefault : Value -> Bool
isDefault v =
    case v of
        VInt i ->
            i == 0

        VWide s ->
            s == "0"

        VFloat x ->
            not (isNaN x) && x == 0

        VBool b ->
            not b

        VString s ->
            String.isEmpty s

        VBytes s ->
            String.isEmpty s

        VEnum n ->
            n == 0

        _ ->
            False


asInt : Value -> Int
asInt v =
    case v of
        VInt i ->
            i

        VEnum i ->
            i

        _ ->
            0


asWide : Value -> String
asWide v =
    case v of
        VWide s ->
            s

        _ ->
            "0"


asFloat : Value -> Float
asFloat v =
    case v of
        VFloat x ->
            x

        _ ->
            0


asBool : Value -> Bool
asBool v =
    case v of
        VBool b ->
            b

        _ ->
            False


asString : Value -> String
asString v =
    case v of
        VString s ->
            s

        _ ->
            ""


asBytes : Value -> String
asBytes v =
    case v of
        VBytes s ->
            s

        _ ->
            ""


asMessage : Value -> Dynamic
asMessage v =
    case v of
        VMessage d ->
            d

        _ ->
            Dict.empty


stringAt : Int -> Dynamic -> String
stringAt number dynamic =
    Dict.get number dynamic |> Maybe.map asString |> Maybe.withDefault ""


bytesAt : Int -> Dynamic -> String
bytesAt number dynamic =
    Dict.get number dynamic |> Maybe.map asBytes |> Maybe.withDefault ""


intAt : Int -> Dynamic -> Int
intAt number dynamic =
    Dict.get number dynamic |> Maybe.map asInt |> Maybe.withDefault 0


wideAt : Int -> Dynamic -> Int
wideAt number dynamic =
    Dict.get number dynamic |> Maybe.map asWide |> Maybe.andThen String.toInt |> Maybe.withDefault 0


traverse : (a -> Maybe b) -> List a -> Maybe (List b)
traverse f items =
    traverseHelp f items []


traverseHelp : (a -> Maybe b) -> List a -> List b -> Maybe (List b)
traverseHelp f items done =
    case items of
        [] ->
            Just (List.reverse done)

        item :: rest ->
            case f item of
                Just b ->
                    traverseHelp f rest (b :: done)

                Nothing ->
                    Nothing
