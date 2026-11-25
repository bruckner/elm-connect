module Proto.Internal.Writer exposing
    ( Encoder
    , Field
    , Fields
    , boolMap
    , checkedFields
    , deeper
    , deferred
    , dict
    , member
    , object
    , optional
    , plainFields
    , refuse
    , repeated
    , run
    , succeed
    , total
    )

{-| The proto3 JSON encoder that generated code builds and `Proto.Json.encode`
runs: a finished value, a refusal, or a part that needs the registry an `Any`
converts through.

The type parameter is what the encoder can refuse with: `Proto.Error.Error`
for one built from a part that can be refused or needs the registry, and any
type for one that cannot, so that `Never` makes a total encoder the compiler
checks ([`total`](#total)).

A message's fields are given as runs in declaration order, each run either
plain JSON (`Maybe Value`, `Nothing` leaving a field out) or fields that can
be refused ([`Field`](#Field)), so the output keeps the declaration order
whichever fields can be refused. Combinators stay on finished values while
every part they are given is finished, so only a refusal or a deferred part
leaves that path. A refusal gathers the path to it, outermost first, on the
way out, and builds its error from that path only when it is run.

-}

import Dict exposing (Dict)
import Json.Decode
import Json.Encode exposing (Value)
import Proto.Error exposing (Error)
import Proto.Internal.Registry as Registry exposing (Registry)


{-| A proto3 JSON encoder that refuses with `x`.
-}
type Encoder x
    = Ready Value
    | Refused (List String) (List String -> x)
    | Deferred (Registry -> Result ( List String, List String -> x ) Value)


{-| A field that can be refused: left out, or written by its encoder.
-}
type Field x
    = Absent
    | Present (Encoder x)


{-| A run of a message's fields, in declaration order.
-}
type Fields x
    = PlainFields (List ( String, Maybe Value ))
    | CheckedFields (List ( String, Field x ))


{-| Run an encoder with the registry its `Any` values convert through.
-}
run : Registry -> Encoder Error -> Result Error Value
run registry encoder =
    case encoder of
        Ready value ->
            Ok value

        Refused path problem ->
            Err (problem path)

        Deferred write ->
            case write registry of
                Ok value ->
                    Ok value

                Err ( path, problem ) ->
                    Err (problem path)


{-| The JSON of an encoder that cannot refuse. Only a part that needs the
registry is deferred, and every such part can refuse, so the deferred case
runs with an empty registry for completeness.
-}
total : Encoder Never -> Value
total encoder =
    case encoder of
        Ready value ->
            value

        Refused path problem ->
            never (problem path)

        Deferred write ->
            case write (Registry.Registry Registry.Strict 0 Dict.empty) of
                Ok value ->
                    value

                Err ( path, problem ) ->
                    never (problem path)


{-| A finished value.
-}
succeed : Value -> Encoder x
succeed =
    Ready


{-| A value of the type named that proto3 JSON has no form for, and what is
wrong with it.
-}
refuse : String -> String -> Encoder Error
refuse typeName message =
    Refused [] (\path -> Proto.Error.BadValue { typeName = typeName, path = path, message = message })


{-| A part that needs the registry.
-}
deferred : (Registry -> Result Error Value) -> Encoder Error
deferred write =
    Deferred
        (\registry ->
            case write registry of
                Ok value ->
                    Ok value

                Err problem ->
                    Err ( [], \_ -> problem )
        )


runPart : Registry -> Encoder x -> Result ( List String, List String -> x ) Value
runPart registry encoder =
    case encoder of
        Ready value ->
            Ok value

        Refused path problem ->
            Err ( path, problem )

        Deferred write ->
            write registry


under : String -> ( List String, List String -> x ) -> ( List String, List String -> x )
under key ( path, problem ) =
    ( key :: path, problem )


{-| A oneof's set member.
-}
member : Encoder x -> Field x
member =
    Present


{-| A field one level deeper in the registry's count than its message, whose
depth is the registry's or 1, whichever is more, as a read starts it. Only a
deferred part converts an `Any`, so the others are given as they are.
-}
deeper : Field x -> Field x
deeper field =
    case field of
        Present (Deferred write) ->
            Present (Deferred (\registry -> write (Registry.atLeast (max 1 (Registry.depthOf registry) + 1) registry)))

        _ ->
            field



-- OBJECTS


{-| A run of fields as the plain helpers give them.
-}
plainFields : List ( String, Maybe Value ) -> Fields x
plainFields =
    PlainFields


{-| A run of fields that can be refused.
-}
checkedFields : List ( String, Field x ) -> Fields x
checkedFields =
    CheckedFields


{-| A message's JSON object from its runs of fields, in order. Its fields are
at depth 1 or deeper in the registry's count, as a read starts a message's,
so an `Any` it holds counts from there; an `Any` written alone, not held by
a message, counts from the registry's own depth, as a read of one does.
-}
object : List (Fields x) -> Encoder x
object runs =
    fastRuns runs [] False


fastRuns : List (Fields x) -> List ( String, Value ) -> Bool -> Encoder x
fastRuns runs done proto =
    case runs of
        [] ->
            Ready (objectOfReversed proto done)

        (PlainFields fields) :: rest ->
            fastPlain fields rest done proto

        (CheckedFields fields) :: rest ->
            fastChecked fields rest done proto


fastPlain : List ( String, Maybe Value ) -> List (Fields x) -> List ( String, Value ) -> Bool -> Encoder x
fastPlain fields rest done proto =
    case fields of
        [] ->
            fastRuns rest done proto

        ( key, Just value ) :: more ->
            fastPlain more rest (( key, value ) :: done) (proto || key == "__proto__")

        ( _, Nothing ) :: more ->
            fastPlain more rest done proto


fastChecked : List ( String, Field x ) -> List (Fields x) -> List ( String, Value ) -> Bool -> Encoder x
fastChecked fields rest done proto =
    case fields of
        [] ->
            fastRuns rest done proto

        ( key, field ) :: more ->
            case field of
                Absent ->
                    fastChecked more rest done proto

                Present (Ready value) ->
                    fastChecked more rest (( key, value ) :: done) (proto || key == "__proto__")

                Present (Refused path problem) ->
                    Refused (key :: path) problem

                Present (Deferred _) ->
                    Deferred (\registry -> slowChecked (Registry.atLeast 1 registry) fields rest done proto)


slowRuns : Registry -> List (Fields x) -> List ( String, Value ) -> Bool -> Result ( List String, List String -> x ) Value
slowRuns registry runs done proto =
    case runs of
        [] ->
            Ok (objectOfReversed proto done)

        (PlainFields fields) :: rest ->
            slowPlain registry fields rest done proto

        (CheckedFields fields) :: rest ->
            slowChecked registry fields rest done proto


slowPlain : Registry -> List ( String, Maybe Value ) -> List (Fields x) -> List ( String, Value ) -> Bool -> Result ( List String, List String -> x ) Value
slowPlain registry fields rest done proto =
    case fields of
        [] ->
            slowRuns registry rest done proto

        ( key, Just value ) :: more ->
            slowPlain registry more rest (( key, value ) :: done) (proto || key == "__proto__")

        ( _, Nothing ) :: more ->
            slowPlain registry more rest done proto


slowChecked : Registry -> List ( String, Field x ) -> List (Fields x) -> List ( String, Value ) -> Bool -> Result ( List String, List String -> x ) Value
slowChecked registry fields rest done proto =
    case fields of
        [] ->
            slowRuns registry rest done proto

        ( key, field ) :: more ->
            case field of
                Absent ->
                    slowChecked registry more rest done proto

                Present encoder ->
                    case runPart registry encoder of
                        Ok value ->
                            slowChecked registry more rest (( key, value ) :: done) (proto || key == "__proto__")

                        Err problem ->
                            Err (under key problem)


{-| An object of pairs each written by its encoder, as a map's entries are.
-}
pairs : List ( String, Encoder x ) -> Encoder x
pairs entries =
    fastPairs entries [] False


fastPairs : List ( String, Encoder x ) -> List ( String, Value ) -> Bool -> Encoder x
fastPairs entries done proto =
    case entries of
        [] ->
            Ready (objectOfReversed proto done)

        ( key, encoder ) :: rest ->
            case encoder of
                Ready value ->
                    fastPairs rest (( key, value ) :: done) (proto || key == "__proto__")

                Refused path problem ->
                    Refused (key :: path) problem

                Deferred _ ->
                    Deferred (\registry -> slowPairs registry entries done proto)


slowPairs : Registry -> List ( String, Encoder x ) -> List ( String, Value ) -> Bool -> Result ( List String, List String -> x ) Value
slowPairs registry entries done proto =
    case entries of
        [] ->
            Ok (objectOfReversed proto done)

        ( key, encoder ) :: rest ->
            case runPart registry encoder of
                Ok value ->
                    slowPairs registry rest (( key, value ) :: done) (proto || key == "__proto__")

                Err problem ->
                    Err (under key problem)



-- FIELDS


{-| A field with presence: left out when `Nothing`.
-}
optional : (a -> Encoder x) -> Maybe a -> Field x
optional encode value =
    case value of
        Just present ->
            Present (encode present)

        Nothing ->
            Absent


{-| A repeated field: left out when empty.
-}
repeated : (a -> Encoder x) -> List a -> Field x
repeated encode items =
    case items of
        [] ->
            Absent

        _ ->
            Present (repeatedFast encode items 0 [])


repeatedFast : (a -> Encoder x) -> List a -> Int -> List Value -> Encoder x
repeatedFast encode items index done =
    case items of
        [] ->
            Ready (Json.Encode.list identity (List.reverse done))

        item :: rest ->
            case encode item of
                Ready value ->
                    repeatedFast encode rest (index + 1) (value :: done)

                Refused path problem ->
                    Refused (String.fromInt index :: path) problem

                (Deferred _) as first ->
                    Deferred (\registry -> repeatedSlow registry encode first rest index done)


repeatedSlow : Registry -> (a -> Encoder x) -> Encoder x -> List a -> Int -> List Value -> Result ( List String, List String -> x ) Value
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
dict : (k -> String) -> (v -> Encoder x) -> Dict k v -> Field x
dict key encode entries =
    if Dict.isEmpty entries then
        Absent

    else
        Present (pairs (Dict.foldr (\k v done -> ( key k, encode v ) :: done) [] entries))


{-| A map field with `bool` keys: left out when empty.
-}
boolMap : (a -> Encoder x) -> List ( Bool, a ) -> Field x
boolMap encode entries =
    case entries of
        [] ->
            Absent

        _ ->
            Present
                (pairs
                    (List.map
                        (\( k, v ) ->
                            ( if k then
                                "true"

                              else
                                "false"
                            , encode v
                            )
                        )
                        entries
                    )
                )


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
