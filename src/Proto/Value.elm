module Proto.Value exposing
    ( Value(..)
    , toJson, fromJson
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

@docs toJson, fromJson

-}

import Array exposing (Array)
import Dict exposing (Dict)
import Json.Decode
import Json.Encode
import Proto.Internal.ValueJson as ValueJson


{-| One JSON value: JSON's six kinds. A number is a `Float`, as protobuf
holds it.

A number that is not finite can only come from protobuf binary or from the
application. It is kept: protobuf binary writes it back as it came, and
proto3 JSON, which has no form for it, writes `null`.

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

For the reason a read failed, decode with
[`Proto.Json.value`](Proto-Json#value).

-}
fromJson : Json.Decode.Value -> Maybe Value
fromJson json =
    Json.Decode.decodeValue (decoderAt 0) json |> Result.toMaybe


decoderAt : Int -> Json.Decode.Decoder Value
decoderAt depth =
    Array.get depth decoders |> Maybe.withDefault ValueJson.tooDeep


decoders : Array (Json.Decode.Decoder Value)
decoders =
    Array.initialize (ValueJson.limit + 1) (ValueJson.level kinds decoderAt)


kinds : ValueJson.Kinds Value
kinds =
    ValueJson.Kinds ValueNull ValueBool ValueNumber ValueString ValueStruct ValueList
