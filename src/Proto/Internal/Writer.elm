module Proto.Internal.Writer exposing
    ( Encoder
    , absent
    , boolMap
    , deeper
    , deferred
    , dict
    , field
    , object
    , optional
    , ready
    , refuse
    , repeated
    , run
    , total
    )

{-| The proto3 JSON encoder that generated code builds and `Proto.Json.encode`
runs: a finished value, a field left out, a refusal, or a part that needs the
registry an `Any` converts through.

The type parameter is what the encoder can refuse with: `Proto.Error.Error`
for one built from a part that can be refused or needs the registry, and any
type for one that cannot, so that `Never` makes a total encoder the compiler
checks ([`total`](#total)).

Combinators stay on finished values while every part they are given is
finished, so a message holding nothing that needs the registry is
built as plain `Json.Encode.Value` code with one tag per part, and only a
refusal or a deferred part leaves that path. A refusal gathers the path to it,
outermost first, on the way out, apart from the refusal itself, which a
combinator cannot look into; [`run`](#run) puts the path into the error.

-}

import Dict exposing (Dict)
import Json.Decode
import Json.Encode exposing (Value)
import Proto.Error exposing (Error(..))
import Proto.Internal.Registry as Registry exposing (Registry)


{-| A proto3 JSON encoder that refuses with `x`.
-}
type Encoder x
    = Ready Value
    | Absent
    | Failed (List String) x
    | Deferred (Registry -> Result ( List String, x ) Value)


{-| Run an encoder with the registry its `Any` values convert through.
-}
run : Registry -> Encoder Error -> Result Error Value
run registry encoder =
    case encoder of
        Ready value ->
            Ok value

        Absent ->
            Ok Json.Encode.null

        Failed path problem ->
            Err (at path problem)

        Deferred write ->
            Result.mapError (\( path, problem ) -> at path problem) (write registry)


{-| The JSON of an encoder that cannot refuse. Only a part that needs the
registry is deferred, and every such part can refuse, so the deferred case
runs with an empty registry for completeness.
-}
total : Encoder Never -> Value
total encoder =
    case encoder of
        Ready value ->
            value

        Absent ->
            Json.Encode.null

        Failed _ problem ->
            never problem

        Deferred write ->
            case write (Registry.Registry Registry.Strict 0 Dict.empty) of
                Ok value ->
                    value

                Err ( _, problem ) ->
                    never problem


{-| A refusal's error with the path to it in front of its own.
-}
at : List String -> Error -> Error
at path problem =
    case ( path, problem ) of
        ( [], _ ) ->
            problem

        ( _, NotWritable unwritable ) ->
            NotWritable { unwritable | path = path ++ unwritable.path }

        _ ->
            problem


runField : Registry -> Encoder x -> Result ( List String, x ) (Maybe Value)
runField registry encoder =
    case encoder of
        Ready value ->
            Ok (Just value)

        Absent ->
            Ok Nothing

        Failed path problem ->
            Err ( path, problem )

        Deferred write ->
            Result.map Just (write registry)


runPart : Registry -> Encoder x -> Result ( List String, x ) Value
runPart registry encoder =
    case encoder of
        Ready value ->
            Ok value

        Absent ->
            Ok Json.Encode.null

        Failed path problem ->
            Err ( path, problem )

        Deferred write ->
            write registry


{-| A finished value.
-}
ready : Value -> Encoder x
ready =
    Ready


{-| A field left out.
-}
absent : Encoder x
absent =
    Absent


{-| A value of the type named that proto3 JSON has no form for.
-}
refuse : String -> Encoder Error
refuse typeName =
    Failed [] (NotWritable { typeName = typeName, path = [] })


{-| A part that needs the registry.
-}
deferred : (Registry -> Result Error Value) -> Encoder Error
deferred write =
    Deferred (\registry -> Result.mapError (\problem -> ( [], problem )) (write registry))


{-| A part one level deeper in the registry's count, which an `Any` it
holds converts from. Only a deferred part converts an `Any`, so the others
are given as they are.
-}
deeper : Encoder x -> Encoder x
deeper encoder =
    case encoder of
        Deferred write ->
            Deferred (\registry -> write (Registry.atLeast (Registry.depthOf registry + 1) registry))

        _ ->
            encoder


{-| A field written by the plain helpers: left out when `Nothing`.
-}
field : Maybe Value -> Encoder x
field value =
    case value of
        Just json ->
            Ready json

        Nothing ->
            Absent


under : String -> ( List String, x ) -> ( List String, x )
under key ( path, problem ) =
    ( key :: path, problem )


{-| A message's object: the fields that cannot fail, as the plain helpers
give them, then those that can.
-}
object : List ( String, Maybe Value ) -> List ( String, Encoder x ) -> Encoder x
object plain checked =
    plainPairs plain checked [] False


plainPairs : List ( String, Maybe Value ) -> List ( String, Encoder x ) -> List ( String, Value ) -> Bool -> Encoder x
plainPairs plain checked done proto =
    case plain of
        ( key, Just value ) :: rest ->
            plainPairs rest checked (( key, value ) :: done) (proto || key == "__proto__")

        ( _, Nothing ) :: rest ->
            plainPairs rest checked done proto

        [] ->
            checkedPairs checked done proto


checkedPairs : List ( String, Encoder x ) -> List ( String, Value ) -> Bool -> Encoder x
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

                Failed path problem ->
                    Failed (key :: path) problem

                Deferred _ ->
                    Deferred (\registry -> slowPairs registry checked done proto)


slowPairs : Registry -> List ( String, Encoder x ) -> List ( String, Value ) -> Bool -> Result ( List String, x ) Value
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
optional : (a -> Encoder x) -> Maybe a -> Encoder x
optional encode value =
    case value of
        Just present ->
            encode present

        Nothing ->
            Absent


{-| A repeated field: left out when empty.
-}
repeated : (a -> Encoder x) -> List a -> Encoder x
repeated encode items =
    case items of
        [] ->
            Absent

        _ ->
            repeatedFast encode items 0 []


repeatedFast : (a -> Encoder x) -> List a -> Int -> List Value -> Encoder x
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

                Failed path problem ->
                    Failed (String.fromInt index :: path) problem

                (Deferred _) as first ->
                    Deferred (\registry -> repeatedSlow registry encode first rest index done)


repeatedSlow : Registry -> (a -> Encoder x) -> Encoder x -> List a -> Int -> List Value -> Result ( List String, x ) Value
repeatedSlow registry encode current rest index done =
    case runPart registry current of
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
dict : (k -> String) -> (v -> Encoder x) -> Dict k v -> Encoder x
dict key encode entries =
    if Dict.isEmpty entries then
        Absent

    else
        checkedPairs (Dict.foldr (\k v pairs -> ( key k, encode v ) :: pairs) [] entries) [] False


{-| A map field with `bool` keys: left out when empty.
-}
boolMap : (a -> Encoder x) -> List ( Bool, a ) -> Encoder x
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
