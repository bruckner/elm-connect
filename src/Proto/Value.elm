module Proto.Value exposing
    ( Value(..)
    , toJson, fromJson
    , decoderAt
    )

{-| `google.protobuf.Value`, `Struct` and `ListValue` as Elm data: any JSON,
held so that `==` compares it exactly, as the rest of a generated message is
compared.

    Proto.Value.StructValue
        (Dict.fromList
            [ ( "name", Proto.Value.StringValue "Ada" )
            , ( "tags", Proto.Value.ListValue [ Proto.Value.StringValue "a" ] )
            ]
        )

A `Struct` field holds a `Dict String Value`, a `ListValue` field a
`List Value`.

@docs Value
@docs toJson, fromJson


# For generated code

@docs decoderAt

-}

import Array exposing (Array)
import Dict exposing (Dict)
import Json.Decode
import Json.Encode


{-| One JSON value. A number is a `Float`, as protobuf holds it.
-}
type Value
    = NullValue
    | NumberValue Float
    | StringValue String
    | BoolValue Bool
    | StructValue (Dict String Value)
    | ListValue (List Value)


{-| The value as JSON, for a port or a decoder of the application's own.
An object's members come out in key order. A number that is not finite
(which only protobuf binary or the application can give) comes out as
`null`, as JavaScript writes it.
-}
toJson : Value -> Json.Encode.Value
toJson value =
    case value of
        NullValue ->
            Json.Encode.null

        NumberValue n ->
            Json.Encode.float n

        StringValue s ->
            Json.Encode.string s

        BoolValue b ->
            Json.Encode.bool b

        StructValue members ->
            objectOf (Dict.toList members)

        ListValue items ->
            Json.Encode.list toJson items


{-| A JSON object from its members. `Json.Encode.object` assigns each to a
JavaScript object, and assigning `__proto__` sets its prototype instead, so an
object with that key is built as text and parsed, which keeps it.
-}
objectOf : List ( String, Value ) -> Json.Encode.Value
objectOf pairs =
    if List.any (\( key, _ ) -> key == "__proto__") pairs then
        pairs
            |> List.map (\( key, value ) -> Json.Encode.encode 0 (Json.Encode.string key) ++ ":" ++ Json.Encode.encode 0 (toJson value))
            |> String.join ","
            |> (\body -> "{" ++ body ++ "}")
            |> Json.Decode.decodeString Json.Decode.value
            |> Result.withDefault (Json.Encode.object (List.map (Tuple.mapSecond toJson) pairs))

    else
        Json.Encode.object (List.map (Tuple.mapSecond toJson) pairs)


{-| JSON as a value, nested at most 100 arrays and objects deep, as protobuf's
readers limit nesting; deeper JSON fails with "Expecting messages nested at
most 100 deep".
-}
fromJson : Json.Decode.Value -> Result Json.Decode.Error Value
fromJson =
    Json.Decode.decodeValue (decoderAt 0)


{-| The JSON decoder of a value read at nesting depth `depth`: its arrays and
objects are one level deeper, and fail past 100. Generated code passes the
depth of the message holding the field; `decoderAt 0` reads one on its own.
-}
decoderAt : Int -> Json.Decode.Decoder Value
decoderAt depth =
    case Array.get depth decoders of
        Just decoder ->
            decoder

        Nothing ->
            tooDeep


decoders : Array (Json.Decode.Decoder Value)
decoders =
    Array.initialize (limit + 1) build


build : Int -> Json.Decode.Decoder Value
build depth =
    let
        child =
            Json.Decode.lazy (\_ -> decoderAt (depth + 1))

        containers =
            if depth < limit then
                [ Json.Decode.map ListValue (Json.Decode.list child)
                , Json.Decode.map StructValue (Json.Decode.dict child)
                ]

            else
                [ tooDeep ]
    in
    Json.Decode.oneOf
        ([ Json.Decode.map NumberValue Json.Decode.float
         , Json.Decode.map StringValue Json.Decode.string
         , Json.Decode.map BoolValue Json.Decode.bool
         , Json.Decode.null NullValue
         ]
            ++ containers
        )


limit : Int
limit =
    100


tooDeep : Json.Decode.Decoder a
tooDeep =
    Json.Decode.fail "Expecting messages nested at most 100 deep"
