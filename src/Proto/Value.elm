module Proto.Value exposing
    ( Value(..)
    , toJson, fromJson, decoder, nestedDecoder
    )

{-| `google.protobuf.Value`, `Struct` and `ListValue` as Elm data. A
`Struct` field holds a `Dict String Value`, a `ListValue` field a
`List Value`, and a `Value` field a `Maybe Value`, `Nothing` when it is
absent:

    Dict.fromList
        [ ( "name", ValueString "Ada" )
        , ( "tags", ValueList [ ValueString "a", ValueString "b" ] )
        ]

`==` compares two values by what they hold: an object's key order never
matters, `1` and `1.0` are equal, and so are `-0` and `0`.

@docs Value


# JSON

@docs toJson, fromJson, decoder, nestedDecoder

-}

import Array exposing (Array)
import Dict exposing (Dict)
import Json.Decode exposing (Decoder)
import Json.Encode
import Proto.Internal.Depth as Depth
import Proto.Internal.ValueJson as ValueJson


{-| One JSON value: JSON's six kinds. A number is a `Float`, as protobuf
holds it.

A number that is not finite can only come from protobuf binary or from the
application. It is kept: protobuf binary writes it back as it came, and a
proto3 JSON write, which has no form for it, refuses it
([`Proto.Json.Encode.encode`](Proto-Json-Encode#encode)); [`toJson`](#toJson) writes `null`.

-}
type Value
    = ValueNull
    | ValueBool Bool
    | ValueNumber Float
    | ValueString String
    | ValueStruct (Dict String Value)
    | ValueList (List Value)


{-| The value as elm/json's JSON, for a port or a decoder of the application's
own. An object's members come out in key order, and a number that is not
finite comes out as `null`, as JavaScript writes it.
-}
toJson : Value -> Json.Encode.Value
toJson value =
    case value of
        ValueNull ->
            Json.Encode.null

        ValueBool b ->
            Json.Encode.bool b

        ValueNumber n ->
            Json.Encode.float n

        ValueString s ->
            Json.Encode.string s

        ValueStruct members ->
            objectOf (Dict.toList members)

        ValueList items ->
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


{-| A value from elm/json's JSON, such as a port hands over. `Nothing` for
something that is not JSON (a function, `undefined`) and for arrays and
objects nested more than 100 deep, which is as deeply as protobuf's readers
nest. A number that is not finite is kept, as `toJson` documents.

For the reason a read failed, decode with [`decoder`](#decoder).

-}
fromJson : Json.Decode.Value -> Maybe Value
fromJson json =
    Json.Decode.decodeValue decoder json |> Result.toMaybe


{-| Decode any JSON, its arrays and objects nested at most 100 deep. Deeper
JSON fails with "Expecting messages nested at most 100 deep", the failure of
messages nested too deeply, since the levels of both count against one limit.
It is the only failure, as any JSON is a `Value`, and it does not say where
inside the value the limit was passed.

    Json.Decode.decodeString decoder """{"a":[1,"x",null]}"""
    -- Ok (ValueStruct (Dict.fromList [ ( "a", ValueList [ ValueNumber 1, ValueString "x", ValueNull ] ) ]))

-}
decoder : Decoder Value
decoder =
    nestedDecoder 0


{-| [`decoder`](#decoder) for a value held `depth` levels deep: generated code
reads a `Value` inside a recursive message with it, so that the message's
levels and the value's arrays and objects count against one limit. Each array
or object is one level deeper than the value holding it; at the limit an
array or object fails.
-}
nestedDecoder : Int -> Decoder Value
nestedDecoder depth =
    ValueJson.read (nodeDecoder depth) Depth.tooDeep


nodeDecoder : Int -> Decoder Value
nodeDecoder depth =
    Array.get depth decoders |> Maybe.withDefault Depth.tooDeep


{-| The decoders by depth, from 0 to the limit, built once: an array's or
object's members are read with the next depth's, so a read never goes deeper
than the table and fails past the limit instead of overflowing the stack.
-}
decoders : Array (Decoder Value)
decoders =
    Array.initialize (Depth.limit + 1) (ValueJson.level kinds nodeDecoder)


kinds : ValueJson.Kinds Value
kinds =
    { null = ValueNull
    , bool = ValueBool
    , number = ValueNumber
    , string = ValueString
    , list = ValueList
    , object = ValueStruct
    }
