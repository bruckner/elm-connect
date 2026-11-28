module Proto.Json.Encode exposing
    ( Encoder, encode, encodeWith, encodeTotal, succeed
    , Field, Fields, object, checkedObject, fields, checkedFields
    , repeated, checkedRepeated, dict, checkedDict, boolMap, checkedBoolMap
    , implicit, implicitDouble, implicitBytes, optional, member, deeper
    , totalOptional, totalRepeated
    , timestamp, duration, fieldMask, struct, listValue, value, any
    , int64, int64AsInt, double, bytes, bytesAsBytes, empty, nullValue
    )

{-| Proto3 JSON encoders, the counterpart of `Json.Encode` for messages. A
generated message's encoder, such as `Notes.V1.encodeNote : Note -> Encoder
x`, describes the message's JSON, and a runner below writes it. The decoders
are in [`Proto.Json.Decode`](Proto-Json-Decode).

Some names match elm/json's (`encode`, `object`, `dict`): every reference is
qualified, as `Proto.Json.Encode.object`, and these write proto3 JSON's forms.


# Running an encoder

[`encode`](#encode) writes an encoder's JSON, or refuses a value proto3 JSON
has no form for (a `Timestamp` outside years 1 to 9999, a `FieldMask` path
with no lowerCamelCase form, a number in a `Value` that is not finite) with
[`BadValue`](Proto-Error#Error). A message holding an `Any` is written with
[`encodeWith`](#encodeWith) and the registry the `Any` converts through.

    Proto.Json.Encode.encode (Notes.V1.encodeNote note)
    -- Ok <the JSON>, or Err (BadValue { typeName = "google.protobuf.Timestamp", path = [ "createTime" ], message = "the time is outside years 1 to 9999" })

The encoder of a message that holds nothing a write can refuse works for any
`x`, so [`encodeTotal`](#encodeTotal) writes it with no `Result`:

    Proto.Json.Encode.encodeTotal (Notes.V1.encodeGetNoteRequest request)

@docs Encoder, encode, encodeWith, encodeTotal, succeed

The sections below are what generated code calls. An application rarely
needs them, apart from [`succeed`](#succeed) for JSON it writes by hand.


# Fields

A generated encoder writes a message's JSON object from its fields, leaving
out every field at its proto3 default, as protobuf's own JSON writers do: a
field without presence at its zero value, a field with presence (`Maybe`)
when `Nothing`, a repeated or map field when empty. A parser reads a missing
field as its default, so nothing is lost.

An encoder's name says whether it can refuse:

  - The bare name cannot refuse and gives plain JSON: a
    `Json.Encode.Value`, or for a field a `Maybe Json.Encode.Value`,
    `Nothing` to leave the field out (`object`, `repeated`, `implicit`).
  - Where a name exists in both forms, the one that can refuse, taking or
    giving an `Encoder x` or a [`Field x`](#Field), is prefixed `checked`
    (`checkedObject`, `checkedRepeated`).
  - A name that exists only in the checked form has no prefix
    (`optional`, `member`, and the well-known types' `timestamp`, `any` and
    the rest, each an `Encoder Proto.Error.Error`).
  - A `total` encoder gives plain JSON from a message encoder that cannot
    refuse, an `Encoder Never` (`totalOptional`).

A message whose fields cannot refuse is written with
[`object`](#object):

    encodeNote : Note -> Proto.Json.Encode.Encoder x
    encodeNote value =
        Proto.Json.Encode.succeed
            (Proto.Json.Encode.object
                [ ( "title", Proto.Json.Encode.implicit "" Json.Encode.string value.title )
                , ( "score", Proto.Json.Encode.implicitDouble value.score )
                , ( "author", Proto.Json.Encode.totalOptional encodeAuthor value.author )
                , ( "tags", Proto.Json.Encode.repeated Json.Encode.string value.tags )
                ]
            )

A message holding a value a write can refuse (an `Any`, a `Timestamp`,
`Duration`, `FieldMask`, `Struct`, `ListValue` or `Value`, or a message that
holds one) is written with [`checkedObject`](#checkedObject) from its fields
in declaration order, in runs: those that cannot refuse in a
[`fields`](#fields) run, those that can in a
[`checkedFields`](#checkedFields) run.

    encodeEvent : Event -> Proto.Json.Encode.Encoder Proto.Error.Error
    encodeEvent value =
        Proto.Json.Encode.checkedObject
            [ Proto.Json.Encode.fields [ ( "title", Proto.Json.Encode.implicit "" Json.Encode.string value.title ) ]
            , Proto.Json.Encode.checkedFields
                [ ( "at", Proto.Json.Encode.optional Proto.Json.Encode.timestamp value.at )
                , ( "payload", Proto.Json.Encode.optional Proto.Json.Encode.any value.payload )
                ]
            ]

@docs Field, Fields, object, checkedObject, fields, checkedFields


## Repeated and map fields

@docs repeated, checkedRepeated, dict, checkedDict, boolMap, checkedBoolMap


## Other fields

@docs implicit, implicitDouble, implicitBytes, optional, member, deeper


## Total fields

A field holding a message that holds nothing a write can refuse unwraps that
message's encoder with [`encodeTotal`](#encodeTotal): an optional or repeated
one through these, a map through [`dict`](#dict).

    Proto.Json.Encode.dict identity (\entry -> Proto.Json.Encode.encodeTotal (encodeAuthor entry)) value.byName

@docs totalOptional, totalRepeated


# Well-known types

These can refuse a value proto3 JSON has no form for, or need the registry.
`Empty` and `NullValue` cannot, so theirs are with the values below.

@docs timestamp, duration, fieldMask, struct, listValue, value, any


# Values

A scalar whose proto3 JSON is elm/json's is written with elm/json:
`Json.Encode.string`, `Json.Encode.int` for a 32-bit integer and
`Json.Encode.bool`. A 64-bit integer is held as its decimal string by
default, or as an `Int` with the `int64=int` option or `[jstype =
JS_NUMBER]`; a `bytes` field as its base64 text by default, or as elm/bytes'
`Bytes` with the `bytes=bytes` option. A `float` field uses
[`double`](#double).

@docs int64, int64AsInt, double, bytes, bytesAsBytes, empty, nullValue

-}

import Bytes exposing (Bytes)
import Dict
import Json.Decode
import Json.Encode
import Proto.Bytes
import Proto.Duration exposing (Duration)
import Proto.Error exposing (Error)
import Proto.Int64
import Proto.Internal.Any as InternalAny exposing (Any)
import Proto.Internal.Duration as InternalDuration
import Proto.Internal.FieldMask as FieldMask
import Proto.Internal.Registry as InternalRegistry
import Proto.Internal.Timestamp as InternalTimestamp
import Proto.Registry exposing (Registry)
import Proto.Timestamp exposing (Timestamp)
import Proto.Value



-- ENCODERS
--
-- An encoder is a finished value, a refusal, or a part that needs the
-- registry an `Any` converts through. Its type parameter is what it can
-- refuse with: `Proto.Error.Error` for one built from a part that can be
-- refused or needs the registry, and any type for one that cannot, so that
-- `Never` makes a total encoder the compiler checks (`encodeTotal`).
--
-- A message's fields are given as runs in declaration order, each run either
-- plain JSON (`Maybe Value`, `Nothing` leaving a field out) or fields that
-- can be refused (`Field`), so the output keeps the declaration order
-- whichever fields can be refused. Combinators stay on finished values while
-- every part they are given is finished, so only a refusal or a deferred
-- part leaves that path. A refusal gathers the path to it, outermost first,
-- on the way out, and builds its error from that path only when it is run.


{-| A proto3 JSON encoder: what a generated `encodeNote : Note -> Encoder x`
gives, written by [`encode`](#encode). It is opaque.

`x` is what it can refuse with. The encoder of a message that holds nothing a
write can refuse works for any `x`, and [`encodeTotal`](#encodeTotal) writes it
with `x` as `Never`; the others are `Encoder Proto.Error.Error`.

-}
type Encoder x
    = Ready Json.Encode.Value
    | Refused (List String) (List String -> x)
    | Deferred (Registry -> Result ( List String, List String -> x ) Json.Encode.Value)


{-| Write an encoder's JSON, or refuse the first value it holds that proto3
JSON has no form for, with [`BadValue`](Proto-Error#Error). An `Any` is
converted through an empty, strict registry, so one that holds a message fails
with [`UnregisteredType`](Proto-Error#Error): write a message holding one with
[`encodeWith`](#encodeWith).

A value is not refused for its depth. One the program builds deeper than the
JavaScript stack allows throws while it is written, as it would through
`Json.Encode`; the calling guide's "Nesting depth" says where.

-}
encode : Encoder Error -> Result Error Json.Encode.Value
encode =
    encodeWith (InternalRegistry.Registry InternalRegistry.Strict 0 Dict.empty)


{-| [`encode`](#encode), converting each `Any` through the registry, as
[`Proto.Any.toJson`](Proto-Any#toJson) does. An `Any` nested more than 100
levels deep, counting `Any`s and the messages that nest around them, is
refused with [`TooDeep`](Proto-Error#Reason), as a read refuses it.
-}
encodeWith : Registry -> Encoder Error -> Result Error Json.Encode.Value
encodeWith registry encoder =
    case encoder of
        Ready json ->
            Ok json

        Refused path problem ->
            Err (problem path)

        Deferred write ->
            case write registry of
                Ok json ->
                    Ok json

                Err ( path, problem ) ->
                    Err (problem path)


{-| The JSON of an encoder that cannot refuse, such as a generated
`encodeNote : Note -> Encoder x` of a message that holds nothing a write can
refuse:

    Json.Encode.encode 0 (encodeTotal (Notes.V1.encodeGetNoteRequest request))

The compiler rejects an encoder that can refuse, so this never fails.

-}
encodeTotal : Encoder Never -> Json.Encode.Value
encodeTotal encoder =
    case encoder of
        Ready json ->
            json

        Refused path problem ->
            never (problem path)

        Deferred write ->
            case write (InternalRegistry.Registry InternalRegistry.Strict 0 Dict.empty) of
                Ok json ->
                    json

                Err ( path, problem ) ->
                    never (problem path)


{-| An encoder of JSON already written, which it gives as it is: for a value
written by hand, such as a [`Proto.Message`](Proto-Message)'s.

    Proto.Json.Encode.succeed << Json.Encode.string

-}
succeed : Json.Encode.Value -> Encoder x
succeed =
    Ready


{-| A message's JSON object, from its runs of fields in declaration order,
for a message holding a field that can be refused. One whose fields cannot
is written with [`object`](#object).
-}
checkedObject : List (Fields x) -> Encoder x
checkedObject runs =
    fastRuns runs [] False


{-| A run of a message's fields, plain or ones that can be refused.
-}
type Fields x
    = PlainFields (List ( String, Maybe Json.Encode.Value ))
    | CheckedFields (List ( String, Field x ))


{-| A run of fields that cannot be refused, as the bare-named field encoders
give them: `Nothing` leaves a field out.
-}
fields : List ( String, Maybe Json.Encode.Value ) -> Fields x
fields =
    PlainFields


{-| A run of fields that can be refused.
-}
checkedFields : List ( String, Field x ) -> Fields x
checkedFields =
    CheckedFields


{-| A field that can be refused, left out or written by its value's encoder.
-}
type Field x
    = Absent
    | Present (Encoder x)


{-| A field with presence: left out when `Nothing`.

It has no counterpart that cannot refuse: such a field is
`Maybe.map encoder value.field`, as generated code writes it.

-}
optional : (a -> Encoder x) -> Maybe a -> Field x
optional write held =
    case held of
        Just present ->
            Present (write present)

        Nothing ->
            Absent


{-| A repeated field that can be refused: left out when empty. One that cannot
is written with [`repeated`](#repeated).
-}
checkedRepeated : (a -> Encoder x) -> List a -> Field x
checkedRepeated write items =
    case items of
        [] ->
            Absent

        _ ->
            Present (repeatedFast write items 0 [])


{-| A map field that can be refused: left out when empty. One that cannot is
written with [`dict`](#dict).
-}
checkedDict : (k -> String) -> (v -> Encoder x) -> Dict.Dict k v -> Field x
checkedDict key write entries =
    if Dict.isEmpty entries then
        Absent

    else
        Present (writePairs (Dict.foldr (\k v done -> ( key k, write v ) :: done) [] entries))


{-| A map field with `bool` keys that can be refused: left out when empty. One
that cannot is written with [`boolMap`](#boolMap).
-}
checkedBoolMap : (a -> Encoder x) -> List ( Bool, a ) -> Field x
checkedBoolMap write entries =
    case entries of
        [] ->
            Absent

        _ ->
            Present
                (writePairs
                    (List.map
                        (\( k, v ) ->
                            ( if k then
                                "true"

                              else
                                "false"
                            , write v
                            )
                        )
                        entries
                    )
                )


{-| A oneof's set member, always written.
-}
member : Encoder x -> Field x
member =
    Present


{-| A field of a message that nests, holding a message that nests, written one
level deeper than its message, so that converting an `Any` it holds to JSON
counts the messages around it as a read does. Generated code uses it only on
fields that reach an `Any`, once per field; a field holding no `Any` is written
as it is, with no count.

    ( "replies", deeper (repeated encodeEnvelope_ value.replies) )

-}
deeper : Field x -> Field x
deeper field =
    case field of
        Present (Deferred write) ->
            Present (Deferred (\registry -> write (InternalRegistry.atLeast (max 1 (InternalRegistry.depthOf registry) + 1) registry)))

        _ ->
            field


{-| A value of the type named that proto3 JSON has no form for, and what is
wrong with it.
-}
refuse : String -> String -> Encoder Error
refuse typeName text =
    Refused [] (\path -> Proto.Error.BadValue { typeName = typeName, path = path, message = text })


{-| A part that needs the registry.
-}
deferred : (Registry -> Result Error Json.Encode.Value) -> Encoder Error
deferred write =
    Deferred
        (\registry ->
            case write registry of
                Ok json ->
                    Ok json

                Err problem ->
                    Err ( [], \_ -> problem )
        )


runPart : Registry -> Encoder x -> Result ( List String, List String -> x ) Json.Encode.Value
runPart registry encoder =
    case encoder of
        Ready json ->
            Ok json

        Refused path problem ->
            Err ( path, problem )

        Deferred write ->
            write registry


under : String -> ( List String, List String -> x ) -> ( List String, List String -> x )
under key ( path, problem ) =
    ( key :: path, problem )


fastRuns : List (Fields x) -> List ( String, Json.Encode.Value ) -> Bool -> Encoder x
fastRuns runs done proto =
    case runs of
        [] ->
            Ready (objectOfReversed proto done)

        (PlainFields run) :: rest ->
            fastPlain run rest done proto

        (CheckedFields run) :: rest ->
            fastChecked run rest done proto


fastPlain : List ( String, Maybe Json.Encode.Value ) -> List (Fields x) -> List ( String, Json.Encode.Value ) -> Bool -> Encoder x
fastPlain run rest done proto =
    case run of
        [] ->
            fastRuns rest done proto

        ( key, Just json ) :: more ->
            fastPlain more rest (( key, json ) :: done) (proto || key == "__proto__")

        ( _, Nothing ) :: more ->
            fastPlain more rest done proto


fastChecked : List ( String, Field x ) -> List (Fields x) -> List ( String, Json.Encode.Value ) -> Bool -> Encoder x
fastChecked run rest done proto =
    case run of
        [] ->
            fastRuns rest done proto

        ( key, field ) :: more ->
            case field of
                Absent ->
                    fastChecked more rest done proto

                Present (Ready json) ->
                    fastChecked more rest (( key, json ) :: done) (proto || key == "__proto__")

                Present (Refused path problem) ->
                    Refused (key :: path) problem

                Present (Deferred _) ->
                    Deferred (\registry -> slowChecked (InternalRegistry.atLeast 1 registry) run rest done proto)


slowRuns : Registry -> List (Fields x) -> List ( String, Json.Encode.Value ) -> Bool -> Result ( List String, List String -> x ) Json.Encode.Value
slowRuns registry runs done proto =
    case runs of
        [] ->
            Ok (objectOfReversed proto done)

        (PlainFields run) :: rest ->
            slowPlain registry run rest done proto

        (CheckedFields run) :: rest ->
            slowChecked registry run rest done proto


slowPlain : Registry -> List ( String, Maybe Json.Encode.Value ) -> List (Fields x) -> List ( String, Json.Encode.Value ) -> Bool -> Result ( List String, List String -> x ) Json.Encode.Value
slowPlain registry run rest done proto =
    case run of
        [] ->
            slowRuns registry rest done proto

        ( key, Just json ) :: more ->
            slowPlain registry more rest (( key, json ) :: done) (proto || key == "__proto__")

        ( _, Nothing ) :: more ->
            slowPlain registry more rest done proto


slowChecked : Registry -> List ( String, Field x ) -> List (Fields x) -> List ( String, Json.Encode.Value ) -> Bool -> Result ( List String, List String -> x ) Json.Encode.Value
slowChecked registry run rest done proto =
    case run of
        [] ->
            slowRuns registry rest done proto

        ( key, field ) :: more ->
            case field of
                Absent ->
                    slowChecked registry more rest done proto

                Present encoder ->
                    case runPart registry encoder of
                        Ok json ->
                            slowChecked registry more rest (( key, json ) :: done) (proto || key == "__proto__")

                        Err problem ->
                            Err (under key problem)


{-| An object of pairs each written by its encoder, as a map's entries are.
-}
writePairs : List ( String, Encoder x ) -> Encoder x
writePairs entries =
    fastPairs entries [] False


fastPairs : List ( String, Encoder x ) -> List ( String, Json.Encode.Value ) -> Bool -> Encoder x
fastPairs entries done proto =
    case entries of
        [] ->
            Ready (objectOfReversed proto done)

        ( key, encoder ) :: rest ->
            case encoder of
                Ready json ->
                    fastPairs rest (( key, json ) :: done) (proto || key == "__proto__")

                Refused path problem ->
                    Refused (key :: path) problem

                Deferred _ ->
                    Deferred (\registry -> slowPairs registry entries done proto)


slowPairs : Registry -> List ( String, Encoder x ) -> List ( String, Json.Encode.Value ) -> Bool -> Result ( List String, List String -> x ) Json.Encode.Value
slowPairs registry entries done proto =
    case entries of
        [] ->
            Ok (objectOfReversed proto done)

        ( key, encoder ) :: rest ->
            case runPart registry encoder of
                Ok json ->
                    slowPairs registry rest (( key, json ) :: done) (proto || key == "__proto__")

                Err problem ->
                    Err (under key problem)


repeatedFast : (a -> Encoder x) -> List a -> Int -> List Json.Encode.Value -> Encoder x
repeatedFast write items index done =
    case items of
        [] ->
            Ready (Json.Encode.list identity (List.reverse done))

        item :: rest ->
            case write item of
                Ready json ->
                    repeatedFast write rest (index + 1) (json :: done)

                Refused path problem ->
                    Refused (String.fromInt index :: path) problem

                (Deferred _) as first ->
                    Deferred (\registry -> repeatedSlow registry write first rest index done)


repeatedSlow : Registry -> (a -> Encoder x) -> Encoder x -> List a -> Int -> List Json.Encode.Value -> Result ( List String, List String -> x ) Json.Encode.Value
repeatedSlow registry write current rest index done =
    case runPart registry current of
        Ok json ->
            case rest of
                [] ->
                    Ok (Json.Encode.list identity (List.reverse (json :: done)))

                next :: more ->
                    repeatedSlow registry write (write next) more (index + 1) (json :: done)

        Err problem ->
            Err (under (String.fromInt index) problem)


{-| A `google.protobuf.Timestamp`, refused when it is not valid
([`Proto.Timestamp.isValid`](Proto-Timestamp#isValid)): outside years 1 to
9999, or with nanoseconds outside 0 to 999,999,999, which only a timestamp
read from protobuf binary can be.
-}
timestamp : Timestamp -> Encoder Error
timestamp held =
    case Proto.Timestamp.toString held of
        Just text ->
            succeed (Json.Encode.string text)

        Nothing ->
            refuse "google.protobuf.Timestamp" (InternalTimestamp.whyInvalid held)


{-| A `google.protobuf.Duration`, refused when it is not valid
([`Proto.Duration.isValid`](Proto-Duration#isValid)): past protobuf's range,
or with nanoseconds of a second or more or of the other sign than the
seconds, which only a duration read from protobuf binary can be.
-}
duration : Duration -> Encoder Error
duration held =
    case Proto.Duration.toString held of
        Just text ->
            succeed (Json.Encode.string text)

        Nothing ->
            refuse "google.protobuf.Duration" (InternalDuration.whyInvalid held)


{-| A `google.protobuf.FieldMask`, refused when a path's lowerCamelCase form
reads back as another path.
-}
fieldMask : List String -> Encoder Error
fieldMask paths =
    if List.all FieldMask.roundTrips paths then
        succeed (encodeFieldMask paths)

    else
        refuse "google.protobuf.FieldMask" "a path's JSON form does not read back as the same path"


{-| A `google.protobuf.Struct`, refused when it holds a number that is NaN or
infinite.
-}
struct : Dict.Dict String Proto.Value.Value -> Encoder Error
struct members =
    checkedValue "google.protobuf.Struct" (Proto.Value.ValueStruct members) (\() -> encodeStruct members)


{-| A `google.protobuf.ListValue`, refused as [`struct`](#struct) is.
-}
listValue : List Proto.Value.Value -> Encoder Error
listValue items =
    checkedValue "google.protobuf.ListValue" (Proto.Value.ValueList items) (\() -> encodeListValue items)


{-| A `google.protobuf.Value`, refused as [`struct`](#struct) is.
-}
value : Proto.Value.Value -> Encoder Error
value held =
    checkedValue "google.protobuf.Value" held (\() -> encodeValue held)


checkedValue : String -> Proto.Value.Value -> (() -> Json.Encode.Value) -> Encoder Error
checkedValue typeName held write =
    if finite held then
        succeed (write ())

    else
        refuse typeName "a number is NaN or infinite"


{-| Whether every number the value holds is finite. It walks the whole value,
however deeply it nests.
-}
finite : Proto.Value.Value -> Bool
finite held =
    case held of
        Proto.Value.ValueNumber number ->
            not (isNaN number || isInfinite number)

        Proto.Value.ValueStruct structMembers ->
            Dict.foldl (\_ item ok -> ok && finite item) True structMembers

        Proto.Value.ValueList items ->
            List.all finite items

        _ ->
            True


{-| A `google.protobuf.Any` held by a message: the message's own JSON object
with `"@type"` added, or `{"@type": …, "value": …}` for a well-known type with
a JSON form of its own, its message's JSON converted from the binary by the
registry the encoder is run with ([`Proto.Any.toJson`](Proto-Any#toJson)),
counting on from its message's depth as a read does; written alone, as a
method's request, it counts from the registry's own depth, as
[`Proto.Json.Decode.any`](Proto-Json-Decode#any) reads one. The empty
`Any`, with no type URL, is `{}`. As protobuf's own JSON writers do, it fails for a type the
registry has no entry for, with [`UnregisteredType`](Proto-Error#Error) naming
its type URL, and for a binary that is not that message, with its
[`BadBinary`](Proto-Error#Error); an `Any` the message holds fails the same
ways, at any depth, named by its own type. An `Any` held as JSON alone, which
a [lenient](Proto-Registry#lenient) registry reads, is written as that JSON:
read through the registry's entry for its type first, and refused as
`UnregisteredType` by a strict registry without one.
-}
any : Any -> Encoder Error
any ((InternalAny.Any url _) as held) =
    if String.isEmpty url then
        succeed (Json.Encode.object [])

    else
        deferred (\registry -> anyJson registry held)


{-| A message's JSON object: each field that has a value, under its JSON name.
A field given `Nothing` is left out. A message holding a field that can be
refused is written with [`checkedObject`](#checkedObject).

    object
        [ ( "title", Just (Json.Encode.string "Hi") )
        , ( "author", Nothing )
        ]
    -- {"title":"Hi"}

-}
object : List ( String, Maybe Json.Encode.Value ) -> Json.Encode.Value
object pairs =
    presentPairs pairs [] False


{-| The pairs of the fields that have a value, gathered in reverse in one
pass, noting whether a key is `__proto__`, and made an object.
-}
presentPairs : List ( String, Maybe Json.Encode.Value ) -> List ( String, Json.Encode.Value ) -> Bool -> Json.Encode.Value
presentPairs pairs done proto =
    case pairs of
        [] ->
            objectOfReversed proto done

        ( key, Just json ) :: rest ->
            presentPairs rest (( key, json ) :: done) (proto || key == "__proto__")

        ( _, Nothing ) :: rest ->
            presentPairs rest done proto


{-| [`objectOf`](#objectOf) of pairs given in reverse, told whether a key is
`__proto__`.
-}
objectOfReversed : Bool -> List ( String, Json.Encode.Value ) -> Json.Encode.Value
objectOfReversed proto reversed =
    if proto then
        objectOf (List.reverse reversed)

    else
        Json.Encode.object (List.reverse reversed)


{-| A JSON object from its pairs, keys kept in order. `Json.Encode.object`
assigns each pair to a JavaScript object, and assigning `__proto__` sets the
object's prototype rather than a property, so that key would be lost from the
output while `JSON.parse` reads it as a property. An object with it is built
as text and parsed, which keeps it.
-}
objectOf : List ( String, Json.Encode.Value ) -> Json.Encode.Value
objectOf pairs =
    if List.any (\( key, _ ) -> key == "__proto__") pairs then
        pairs
            |> List.map
                (\( key, json ) ->
                    Json.Encode.encode 0 (Json.Encode.string key)
                        ++ ":"
                        ++ Json.Encode.encode 0 json
                )
            |> String.join ","
            |> (\body -> "{" ++ body ++ "}")
            |> Json.Decode.decodeString Json.Decode.value
            |> Result.withDefault (Json.Encode.object pairs)

    else
        Json.Encode.object pairs


{-| A field without presence: `Nothing` when it holds its proto3 default, the
first argument, else its JSON. For a string, a number held as an `Int`, a
64-bit integer held as its decimal string, a `Bool`, bytes held as base64 or an
enum; a `Float` uses [`implicitDouble`](#implicitDouble), and bytes held as
`Bytes` [`implicitBytes`](#implicitBytes).

    implicit "" Json.Encode.string "" -- Nothing

    implicit 0 Json.Encode.int 3 -- Just 3

-}
implicit : a -> (a -> Json.Encode.Value) -> a -> Maybe Json.Encode.Value
implicit zero write held =
    if held == zero then
        Nothing

    else
        Just (write held)


{-| A `bytes` field held as `Bytes`, without presence: `Nothing` when it holds
no bytes, else its JSON as [`bytesAsBytes`](#bytesAsBytes) writes
it. Not [`implicit`](#implicit), which compares with `==`, and `==` finds any
two `Bytes` equal.
-}
implicitBytes : Bytes -> Maybe Json.Encode.Value
implicitBytes held =
    if Bytes.width held == 0 then
        Nothing

    else
        Just (bytesAsBytes held)


{-| A `double` or `float` field without presence: `Nothing` at `0`, else its
JSON as [`double`](#double) writes it. `-0`, NaN and the infinities
are not the default and are written; `-0` as `0`, since JavaScript's JSON
writer has no negative zero, and a server reads `+0` either way.
-}
implicitDouble : Float -> Maybe Json.Encode.Value
implicitDouble number =
    if number == 0 && 1 / number > 0 then
        Nothing

    else
        Just (double number)


{-| A repeated field: `Nothing` when empty, else a JSON array of its elements.
-}
repeated : (a -> Json.Encode.Value) -> List a -> Maybe Json.Encode.Value
repeated write values =
    if List.isEmpty values then
        Nothing

    else
        Just (Json.Encode.list write values)


{-| A map field: `Nothing` when empty, else a JSON object, keyed as
`Json.Encode.dict` keys it. A key of `__proto__` is kept as an ordinary key.
-}
dict : (k -> String) -> (v -> Json.Encode.Value) -> Dict.Dict k v -> Maybe Json.Encode.Value
dict key write entries =
    if Dict.isEmpty entries then
        Nothing

    else
        entries
            |> Dict.toList
            |> List.map (\( k, v ) -> ( key k, write v ))
            |> objectOf
            |> Just


{-| A map field with `bool` keys, held as an association list: `Nothing` when
empty, else a JSON object keyed `"true"` and `"false"`. When a key appears
twice, the later pair is the one a parser keeps.
-}
boolMap : (a -> Json.Encode.Value) -> List ( Bool, a ) -> Maybe Json.Encode.Value
boolMap write pairs =
    if List.isEmpty pairs then
        Nothing

    else
        Just (encodeBoolMap write pairs)


{-| A field with presence of a message that holds nothing a write can refuse:
`Nothing` when `Nothing`, else its encoder's JSON ([`encodeTotal`](#encodeTotal)).
-}
totalOptional : (a -> Encoder Never) -> Maybe a -> Maybe Json.Encode.Value
totalOptional write held =
    case held of
        Just present ->
            Just (encodeTotal (write present))

        Nothing ->
            Nothing


{-| [`repeated`](#repeated) of a message that holds nothing a write
can refuse.
-}
totalRepeated : (a -> Encoder Never) -> List a -> Maybe Json.Encode.Value
totalRepeated write values =
    if List.isEmpty values then
        Nothing

    else
        Just (Json.Encode.list (\item -> encodeTotal (write item)) values)


{-| A map with `bool` keys, held as an association list, as a JSON object
keyed `"true"` and `"false"`.
-}
encodeBoolMap : (a -> Json.Encode.Value) -> List ( Bool, a ) -> Json.Encode.Value
encodeBoolMap write pairs =
    pairs
        |> List.map
            (\( key, entry ) ->
                ( if key then
                    "true"

                  else
                    "false"
                , write entry
                )
            )
        |> Json.Encode.object


{-| Encode a 64-bit integer, held as its decimal string, as proto3 JSON does:
as a JSON string.
-}
int64 : String -> Json.Encode.Value
int64 =
    Json.Encode.string


{-| Encode a 64-bit integer held as an `Int` as proto3 JSON writes one: its
decimal string, as a JSON string.

    int64AsInt 42 -- "42"

-}
int64AsInt : Int -> Json.Encode.Value
int64AsInt int =
    Json.Encode.string (Proto.Int64.fromInt int)


{-| Encode a `double` or `float`: a finite value as a JSON number, NaN and the
infinities as the strings proto3 JSON uses for them.
-}
double : Float -> Json.Encode.Value
double number =
    if isNaN number then
        Json.Encode.string "NaN"

    else if isInfinite number then
        if number > 0 then
            Json.Encode.string "Infinity"

        else
            Json.Encode.string "-Infinity"

    else
        Json.Encode.float number


{-| Encode `bytes`, held as a base64 string, as that string, unchecked.
-}
bytes : String -> Json.Encode.Value
bytes =
    Json.Encode.string


{-| Encode `bytes` held as `Bytes` as base64 text: the standard alphabet, with
`=` padding, as proto3 JSON writes it.
-}
bytesAsBytes : Bytes -> Json.Encode.Value
bytesAsBytes data =
    Json.Encode.string (Proto.Bytes.toBase64 data)


{-| Encode a `google.protobuf.FieldMask` from its paths, written with proto
field names (`"author.email_address"`): each field name in lowerCamelCase, the
paths joined by commas.
-}
encodeFieldMask : List String -> Json.Encode.Value
encodeFieldMask paths =
    Json.Encode.string (FieldMask.toText paths)


{-| Encode a `google.protobuf.Empty` as `{}`.
-}
empty : () -> Json.Encode.Value
empty () =
    Json.Encode.object []


{-| Encode the enum `google.protobuf.NullValue` as proto3 JSON writes it,
`null`.
-}
nullValue : () -> Json.Encode.Value
nullValue () =
    Json.Encode.null


{-| Encode a `google.protobuf.Struct` from its members, as a JSON object.
-}
encodeStruct : Dict.Dict String Proto.Value.Value -> Json.Encode.Value
encodeStruct members =
    Proto.Value.toJson (Proto.Value.ValueStruct members)


{-| Encode a `google.protobuf.ListValue` from its elements, as a JSON array.
-}
encodeListValue : List Proto.Value.Value -> Json.Encode.Value
encodeListValue =
    Json.Encode.list Proto.Value.toJson


{-| Encode a `google.protobuf.Value` as its JSON.
-}
encodeValue : Proto.Value.Value -> Json.Encode.Value
encodeValue =
    Proto.Value.toJson


{-| An `Any`'s proto3 JSON: the message's own JSON object with `"@type"`
added, or `{"@type": …, "value": …}` for a well-known type with a JSON form of
its own; `{}` for the empty `Any`.
-}
anyJson : Registry -> Any -> Result Error Json.Encode.Value
anyJson registry ((InternalAny.Any url _) as held) =
    if String.isEmpty url then
        Ok (Json.Encode.object [])

    else
        InternalRegistry.anyToJson registry held
            |> Result.map (anyObject url)


{-| An `Any`'s JSON object, from its type URL and its message's JSON.
-}
anyObject : String -> Json.Encode.Value -> Json.Encode.Value
anyObject url json =
    let
        typed =
            ( "@type", Json.Encode.string url )
    in
    if String.isEmpty url then
        Json.Encode.object []

    else if InternalAny.hasJsonForm url then
        Json.Encode.object [ typed, ( "value", json ) ]

    else
        case Json.Decode.decodeValue (Json.Decode.keyValuePairs Json.Decode.value) json of
            Ok pairs ->
                Json.Encode.object (typed :: pairs)

            Err _ ->
                -- Only a hand-built record writes a message as other
                -- than an object; this keeps its JSON whole.
                Json.Encode.object [ typed, ( "value", json ) ]
