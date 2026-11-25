module Proto.Internal.JsonRead exposing
    ( IntegerProblem(..)
    , Width(..)
    , atMost
    , canonicalInteger
    , enumWith
    , isArray
    , isObject
    , isScalarText
    , leadingCount
    , narrowInteger
    , nestedListValue
    , nestedStruct
    , nestedValue
    , notAnObject
    , quote
    , scientific
    , trailingCount
    , wideInteger
    , widthRange
    )

{-| What the proto3 JSON decoders of `Proto.Json.Decode` share with those
generated code calls in `Proto.Json`.
-}

import Array exposing (Array)
import Dict
import Json.Decode exposing (Decoder)
import Json.Encode exposing (Value)
import Proto.Internal.Depth as Depth
import Proto.Internal.Percent as Percent
import Proto.Internal.ValueJson as ValueJson
import Proto.Value


{-| Whether a JSON value is an object, in constant time: JavaScript's `in`
finds `hasOwnProperty` in every object and array, which inherit it, and in no
other JSON value, and arrays are told apart. Listing the object's keys would
take time in their number.
-}
isObject : Value -> Bool
isObject json =
    case Json.Decode.decodeValue (Json.Decode.field "hasOwnProperty" (Json.Decode.succeed ())) json of
        Ok () ->
            not (isArray json)

        Err _ ->
            False


{-| Whether a JSON value is an array, in constant time: decoding its elements
stops at the first, which `fail` rejects, and an empty array decodes.
-}
isArray : Value -> Bool
isArray json =
    case Json.Decode.decodeValue (Json.Decode.list (Json.Decode.fail "")) json of
        Ok _ ->
            True

        Err (Json.Decode.Index _ _) ->
            True

        Err _ ->
            False


{-| The failure of a message decoder given JSON that is not an object, as
elm/json words it.
-}
notAnObject : Decoder a
notAnObject =
    Json.Decode.fail "Expecting an OBJECT"


quote : String -> String
quote text =
    "\"" ++ text ++ "\""


{-| `enum` and `enumOrZero`, which differ in what an unknown name reads as.
-}
enumWith : (String -> Decoder a) -> a -> List ( String, Int, a ) -> Decoder a
enumWith unknownName zero values =
    let
        lookup matches =
            values
                |> List.filter matches
                |> List.head
                |> Maybe.map (\( _, _, constructor ) -> constructor)
    in
    Json.Decode.oneOf
        [ Json.Decode.map Ok Json.Decode.string
        , Json.Decode.map Err Json.Decode.int
        ]
        |> Json.Decode.andThen
            (\form ->
                case form of
                    Ok text ->
                        case lookup (\( name, _, _ ) -> name == text) of
                            Just constructor ->
                                Json.Decode.succeed constructor

                            Nothing ->
                                unknownName text

                    Err int ->
                        lookup (\( _, number, _ ) -> number == int)
                            |> Maybe.withDefault zero
                            |> Json.Decode.succeed
            )


{-| Whether `text` holds no UTF-16 surrogate without its pair.
-}
isScalarText : String -> Bool
isScalarText =
    Percent.wellFormed


{-| A 32-bit integer written as text, as [`int64`](#int64) reads a string,
within `low` to `high`.
-}
narrowInteger : Int -> Int -> String -> Result IntegerProblem Int
narrowInteger low high text =
    canonicalInteger text
        |> Result.andThen
            (\decimal ->
                case String.toInt decimal of
                    Just int ->
                        if int >= low && int <= high then
                            Ok int

                        else
                            Err OutOfRange

                    Nothing ->
                        Err NotDecimal
            )


{-| The 64-bit integer types' two ranges.
-}
type Width
    = Signed
    | Unsigned


widthRange : Width -> String
widthRange width =
    case width of
        Signed ->
            "(-9223372036854775808 to 9223372036854775807)"

        Unsigned ->
            "(0 to 18446744073709551615)"


{-| Why text is not an integer of a type.
-}
type IntegerProblem
    = NotDecimal
    | NotInteger
    | OutOfRange


{-| The canonical decimal form of a 64-bit integer written as text, within
the range of `width`. The digits are compared with the bound's as text, by
length and then digit by digit, since an `Int` is exact only to 2^53.
-}
wideInteger : Width -> String -> Result IntegerProblem String
wideInteger width text =
    canonicalInteger text
        |> Result.andThen
            (\decimal ->
                let
                    inRange =
                        case ( width, String.startsWith "-" decimal ) of
                            ( Signed, True ) ->
                                atMost "9223372036854775808" (String.dropLeft 1 decimal)

                            ( Signed, False ) ->
                                atMost "9223372036854775807" decimal

                            ( Unsigned, True ) ->
                                False

                            ( Unsigned, False ) ->
                                atMost "18446744073709551615" decimal
                in
                if inRange then
                    Ok decimal

                else
                    Err OutOfRange
            )


{-| Whether the digits of a canonical natural number (no leading zeros) are at
most `bound`'s.
-}
atMost : String -> String -> Bool
atMost bound digits =
    String.length digits
        < String.length bound
        || (String.length digits == String.length bound && digits <= bound)


{-| The canonical decimal form of an integer written as text in decimal or
exponent notation (`"-1.5e3"` is `"-1500"`), found by moving the decimal point
rather than through a `Float`, which would round past 2^53. One of more than
20 digits, past every 64-bit integer, is `OutOfRange` without being written
out, so an exponent cannot ask for a string of any length.
-}
canonicalInteger : String -> Result IntegerProblem String
canonicalInteger text =
    let
        ( sign, unsigned ) =
            if String.startsWith "-" text then
                ( "-", String.dropLeft 1 text )

            else
                ( "", text )
    in
    case scientific unsigned of
        Nothing ->
            Err NotDecimal

        Just { digits, point } ->
            let
                leading =
                    leadingCount '0' digits

                significant =
                    String.dropLeft leading digits

                -- The point counted from the first significant digit.
                shifted =
                    point - leading

                kept =
                    String.dropRight (trailingCount '0' significant) significant
            in
            if String.isEmpty kept then
                Ok "0"

            else if String.length kept > shifted then
                Err NotInteger

            else if shifted > 20 then
                Err OutOfRange

            else
                Ok (sign ++ kept ++ String.repeat (shifted - String.length kept) "0")


{-| An unsigned number in decimal or exponent notation (`1`, `1.5`, `15e-1`,
`1.5E+0`) as its digits and the position of the decimal point among them,
which may lie outside them.
-}
scientific : String -> Maybe { digits : String, point : Int }
scientific text =
    let
        -- A low surrogate without its high half is read with the unit
        -- before it, a digit perhaps, as one character two units long.
        allDigits part =
            not (String.isEmpty part) && String.all (\char -> Char.isDigit char && String.length (String.fromChar char) == 1) part

        exponentOf part =
            if allDigits (String.dropLeft 1 part) && (String.startsWith "+" part || String.startsWith "-" part) then
                String.toInt part

            else if allDigits part then
                String.toInt part

            else
                Nothing

        ( mantissa, exponent ) =
            case String.split "e" (String.toLower text) of
                [ whole ] ->
                    ( whole, Just 0 )

                [ whole, power ] ->
                    ( whole, exponentOf power )

                _ ->
                    ( "", Nothing )

        parts =
            case String.split "." mantissa of
                [ whole ] ->
                    Just ( whole, "" )

                [ whole, fraction ] ->
                    if allDigits fraction then
                        Just ( whole, fraction )

                    else
                        Nothing

                _ ->
                    Nothing
    in
    case ( parts, exponent ) of
        ( Just ( whole, fraction ), Just power ) ->
            if allDigits whole then
                Just { digits = whole ++ fraction, point = String.length whole + power }

            else
                Nothing

        _ ->
            Nothing


{-| How many times `char` repeats at the start of `text`, in one pass.
-}
leadingCount : Char -> String -> Int
leadingCount char text =
    String.foldl
        (\c ( count, counting ) ->
            if counting && c == char then
                ( count + 1, True )

            else
                ( count, False )
        )
        ( 0, True )
        text
        |> Tuple.first


{-| How many times `char` repeats at the end of `text`, in one pass.
-}
trailingCount : Char -> String -> Int
trailingCount char text =
    String.foldr
        (\c ( count, counting ) ->
            if counting && c == char then
                ( count + 1, True )

            else
                ( count, False )
        )
        ( 0, True )
        text
        |> Tuple.first


{-| A `google.protobuf.Struct` read at a nesting depth: the object is one
level deeper.
-}
nestedStruct : Int -> Decoder (Dict.Dict String Proto.Value.Value)
nestedStruct depth =
    if depth < Depth.limit then
        ValueJson.read (Json.Decode.dict (valueNode (depth + 1))) notAnObjectOrTooDeep

    else
        notAnObjectOrTooDeep


{-| The failure of a `Struct` that did not read: elm/json's for JSON that is
not an object, and the depth limit's for an object, since an object fails
only by nesting too deeply.
-}
notAnObjectOrTooDeep : Decoder a
notAnObjectOrTooDeep =
    Json.Decode.dict (Json.Decode.succeed ()) |> Json.Decode.andThen (\_ -> Depth.tooDeep)


{-| A `google.protobuf.ListValue` read at a nesting depth: the array is one
level deeper.
-}
nestedListValue : Int -> Decoder (List Proto.Value.Value)
nestedListValue depth =
    if depth < Depth.limit then
        ValueJson.read (Json.Decode.list (valueNode (depth + 1))) notAListOrTooDeep

    else
        notAListOrTooDeep


{-| The failure of a `ListValue` that did not read, as
`notAnObjectOrTooDeep` is a `Struct`'s.
-}
notAListOrTooDeep : Decoder a
notAListOrTooDeep =
    Json.Decode.list (Json.Decode.succeed ()) |> Json.Decode.andThen (\_ -> Depth.tooDeep)


{-| A `google.protobuf.Value` read at a nesting depth: its arrays and objects
are a level deeper each.
-}
nestedValue : Int -> Decoder Proto.Value.Value
nestedValue depth =
    ValueJson.read (valueNode depth) Depth.tooDeep


{-| `Proto.Value`'s table of decoders by depth, built here too, so that a
program reading these types through generated code holds one table.
-}
valueNode : Int -> Decoder Proto.Value.Value
valueNode depth =
    Array.get depth valueDecoders |> Maybe.withDefault Depth.tooDeep


valueDecoders : Array (Decoder Proto.Value.Value)
valueDecoders =
    Array.initialize (Depth.limit + 1) (ValueJson.level valueKinds valueNode)


valueKinds : ValueJson.Kinds Proto.Value.Value
valueKinds =
    { null = Proto.Value.ValueNull
    , bool = Proto.Value.ValueBool
    , number = Proto.Value.ValueNumber
    , string = Proto.Value.ValueString
    , list = Proto.Value.ValueList
    , object = Proto.Value.ValueStruct
    }
