module Proto.Internal.Writer exposing
    ( Encoder
    , absent
    , boolMap
    , deeper
    , deferred
    , dict
    , field
    , from
    , limit
    , object
    , optional
    , ready
    , refuse
    , repeated
    , run
    , tooDeep
    )

{-| The proto3 JSON encoder that generated code builds and `Proto.Json.encode`
runs: a finished value, a field left out, a refusal, or a part that needs the
registry an `Any` converts through, or the depth a message on a cycle is
written at.

Combinators stay on finished values while every part they are given is
finished, so a message holding nothing that needs the registry or a depth is
built as plain `Json.Encode.Value` code with one tag per part, and only a
refusal or a deferred part leaves that path. A refusal names its type and
gathers the path to it on the way out; a deferred part is run once, top down,
by [`run`](#run), with the registry.

-}

import Dict exposing (Dict)
import Json.Decode
import Json.Encode exposing (Value)
import Proto.Error exposing (Error(..))
import Proto.Internal.Registry as Registry exposing (Registry)


{-| A proto3 JSON encoder.
-}
type Encoder
    = Ready Value
    | Absent
    | Failed Error
    | Deferred (Registry -> Result Error Value)


{-| Run an encoder with the registry its `Any` values convert through.
-}
run : Registry -> Encoder -> Result Error Value
run registry encoder =
    case encoder of
        Ready value ->
            Ok value

        Absent ->
            Ok Json.Encode.null

        Failed problem ->
            Err problem

        Deferred write ->
            write registry


runField : Registry -> Encoder -> Result Error (Maybe Value)
runField registry encoder =
    case encoder of
        Ready value ->
            Ok (Just value)

        Absent ->
            Ok Nothing

        Failed problem ->
            Err problem

        Deferred write ->
            Result.map Just (write registry)


{-| A finished value.
-}
ready : Value -> Encoder
ready =
    Ready


{-| A field left out.
-}
absent : Encoder
absent =
    Absent


{-| A value of the type named that proto3 JSON has no form for.
-}
refuse : String -> Encoder
refuse typeName =
    Failed (NotWritable { typeName = typeName, path = [], reason = Proto.Error.NoJsonForm })


{-| A part that needs the registry.
-}
deferred : (Registry -> Result Error Value) -> Encoder
deferred =
    Deferred


{-| A field written by the plain helpers: left out when `Nothing`.
-}
field : Maybe Value -> Encoder
field value =
    case value of
        Just json ->
            Ready json

        Nothing ->
            Absent


{-| The deepest a write nests: messages on a cycle, `Any` values and the
arrays and objects of a `Value`, as the reads count them.
-}
limit : Int
limit =
    100


under : String -> Error -> Error
under key problem =
    case problem of
        NotWritable unwritable ->
            NotWritable { unwritable | path = key :: unwritable.path }

        _ ->
            problem


{-| A message's object: the fields that cannot fail, as the plain helpers
give them, then those that can.
-}
object : List ( String, Maybe Value ) -> List ( String, Encoder ) -> Encoder
object plain checked =
    plainPairs plain checked [] False


plainPairs : List ( String, Maybe Value ) -> List ( String, Encoder ) -> List ( String, Value ) -> Bool -> Encoder
plainPairs plain checked done proto =
    case plain of
        ( key, Just value ) :: rest ->
            plainPairs rest checked (( key, value ) :: done) (proto || key == "__proto__")

        ( _, Nothing ) :: rest ->
            plainPairs rest checked done proto

        [] ->
            checkedPairs checked done proto


checkedPairs : List ( String, Encoder ) -> List ( String, Value ) -> Bool -> Encoder
checkedPairs checked done proto =
    case checked of
        [] ->
            Ready (objectOfReversed proto done)

        ( key, encoder ) :: rest ->
            case encoder of
                Ready value ->
                    checkedPairs rest (( key, value ) :: done) (proto || key == "__proto__")

                Absent ->
                    checkedPairs rest done proto

                Failed problem ->
                    Failed (under key problem)

                Deferred _ ->
                    Deferred (\registry -> slowPairs registry checked done proto)


slowPairs : Registry -> List ( String, Encoder ) -> List ( String, Value ) -> Bool -> Result Error Value
slowPairs registry checked done proto =
    case checked of
        [] ->
            Ok (objectOfReversed proto done)

        ( key, encoder ) :: rest ->
            case runField registry encoder of
                Ok (Just value) ->
                    slowPairs registry rest (( key, value ) :: done) (proto || key == "__proto__")

                Ok Nothing ->
                    slowPairs registry rest done proto

                Err problem ->
                    Err (under key problem)


{-| A field with presence: left out when `Nothing`.
-}
optional : (a -> Encoder) -> Maybe a -> Encoder
optional encode value =
    case value of
        Just present ->
            encode present

        Nothing ->
            Absent


{-| A repeated field: left out when empty.
-}
repeated : (a -> Encoder) -> List a -> Encoder
repeated encode items =
    case items of
        [] ->
            Absent

        _ ->
            repeatedFast encode items 0 []


repeatedFast : (a -> Encoder) -> List a -> Int -> List Value -> Encoder
repeatedFast encode items index done =
    case items of
        [] ->
            Ready (Json.Encode.list identity (List.reverse done))

        item :: rest ->
            case encode item of
                Ready value ->
                    repeatedFast encode rest (index + 1) (value :: done)

                Absent ->
                    repeatedFast encode rest (index + 1) (Json.Encode.null :: done)

                Failed problem ->
                    Failed (under (String.fromInt index) problem)

                (Deferred _) as first ->
                    Deferred (\registry -> repeatedSlow registry encode first rest index done)


repeatedSlow : Registry -> (a -> Encoder) -> Encoder -> List a -> Int -> List Value -> Result Error Value
repeatedSlow registry encode current rest index done =
    case run registry current of
        Ok value ->
            case rest of
                [] ->
                    Ok (Json.Encode.list identity (List.reverse (value :: done)))

                next :: more ->
                    repeatedSlow registry encode (encode next) more (index + 1) (value :: done)

        Err problem ->
            Err (under (String.fromInt index) problem)


{-| A map field: left out when empty, keyed as given.
-}
dict : (k -> String) -> (v -> Encoder) -> Dict k v -> Encoder
dict key encode entries =
    if Dict.isEmpty entries then
        Absent

    else
        checkedPairs (Dict.foldr (\k v pairs -> ( key k, encode v ) :: pairs) [] entries) [] False


{-| A map field with `bool` keys: left out when empty.
-}
boolMap : (a -> Encoder) -> List ( Bool, a ) -> Encoder
boolMap encode pairs =
    case pairs of
        [] ->
            Absent

        _ ->
            checkedPairs
                (List.map
                    (\( k, v ) ->
                        ( if k then
                            "true"

                          else
                            "false"
                        , encode v
                        )
                    )
                    pairs
                )
                []
                False


{-| A value one level deeper on a cycle of messages, the message named: it
is built and written only when run, so a value nested past the limit is
refused there, before its deeper levels are built.
-}
deeper : String -> (a -> Encoder) -> a -> Encoder
deeper typeName encode value =
    Deferred
        (\registry ->
            let
                depth =
                    Registry.depthOf registry
            in
            if depth + 2 > limit then
                Err (NotWritable { typeName = typeName, path = [], reason = Proto.Error.NestedTooDeep })

            else
                run (Registry.atLeast (depth + 1) registry) (encode value)
        )


{-| A message on a cycle, from its encoder at a level: the level is one
deeper than the registry it is run with, and the encoder passes it down,
refusing past the limit, so it is counted while the value is built.
-}
from : (Int -> a -> Encoder) -> a -> Encoder
from encodeAt value =
    Deferred (\registry -> run registry (encodeAt (Registry.depthOf registry + 1) value))


{-| A message of the type named nested past the limit.
-}
tooDeep : String -> Encoder
tooDeep typeName =
    Failed (NotWritable { typeName = typeName, path = [], reason = Proto.Error.NestedTooDeep })


{-| An object from its pairs in reverse, told whether a key is `__proto__`,
which `Json.Encode.object` would turn into the object's prototype: an object
with it is built as text and parsed.
-}
objectOfReversed : Bool -> List ( String, Value ) -> Value
objectOfReversed proto reversed =
    if proto then
        List.reverse reversed
            |> List.map (\( key, value ) -> Json.Encode.encode 0 (Json.Encode.string key) ++ ":" ++ Json.Encode.encode 0 value)
            |> String.join ","
            |> (\body -> "{" ++ body ++ "}")
            |> Json.Decode.decodeString Json.Decode.value
            |> Result.withDefault (Json.Encode.object (List.reverse reversed))

    else
        Json.Encode.object (List.reverse reversed)
