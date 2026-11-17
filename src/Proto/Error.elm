module Proto.Error exposing
    ( Error(..)
    , Binary, Reason(..)
    , toString, toStringWithoutValues
    )

{-| Why a message could not be read, written or unpacked: one type for the
`Proto` modules' failures, as `Json.Decode.Error` is elm/json's.

An operation that can fail only one way gives that way's own type, as
[`Proto.Binary.decode`](Proto-Binary#decode) gives a [`Binary`](#Binary);
one that can fail several ways gives an `Error`, and a `Binary` lifts into
one as `BadBinary`.

@docs Error


# Protobuf binary

@docs Binary, Reason


# Describing

@docs toString, toStringWithoutValues

-}

import Json.Decode


{-| Why a message could not be read, written or unpacked:

  - `BadBinary`: protobuf binary that is not the message it was read as
    ([`Binary`](#Binary)).
  - `BadJson`: proto3 JSON that is not the message it was read as, with
    elm/json's error, whose path locates the failure.
  - `TypeMismatch`: a `google.protobuf.Any` unpacked as another type than
    the one it holds: `expected` is the full name of the type the program
    unpacked it as, `actual` the full name of the type the `Any` holds, its
    type URL without the prefix, as [`Proto.Any.typeName`](Proto-Any#typeName)
    gives it.
  - `UnregisteredType`: a `google.protobuf.Any` of a type, its URL here,
    that the registry it was converted through has no entry for. Register
    the type.

-}
type Error
    = BadBinary Binary
    | BadJson Json.Decode.Error
    | TypeMismatch { expected : String, actual : String }
    | UnregisteredType String


{-| Why protobuf binary is not the message it was read as:

  - `typeName`: the full name of the message the program decoded, the
    outermost one, such as `notes.v1.Note`; the message the failing field
    belongs to is the last entry of `path`.
  - `reason`: what was wrong ([`Reason`](#Reason)).
  - `path`: the fields the failure is in, outermost first, each as the full
    name of the message it belongs to and its field number:
    `[ ( "notes.v1.Note", 3 ), ( "notes.v1.Revision", 1 ) ]` is field 1 of
    the `Revision` in field 3 of the `Note`. Empty when the failure is in
    no field, as a field key cut short at the top level is. A program that
    keeps descriptors names each field with
    [`Proto.Message.fieldNumbered`](Proto-Message#fieldNumbered).
  - `offset`: the first byte, counted from the start of the input, that
    could not be read.

-}
type alias Binary =
    { typeName : String
    , reason : Reason
    , path : List ( String, Int )
    , offset : Int
    }


{-| What was wrong with protobuf binary:

  - `Truncated`: the input ends in the middle of a field.
  - `LengthOverrun`: a field runs past the end of the message, packed field
    or map entry it is in, though the input goes on.
  - `InvalidTag`: a field number 0.
  - `InvalidWireType`: a wire type, given here, that proto3 does not use: a
    group (3 or 4), or 6 or 7, which are none.
  - `MalformedVarint`: a varint longer than ten bytes.
  - `IntOutOfRange`: a 64-bit integer, held as an `Int`, outside ±(2^53 − 1),
    which an `Int` holds exactly.
  - `InvalidUtf8`: a `string` field whose bytes are not UTF-8.
  - `Unlocated`: the decoder failed, but could not say where or why. This
    is a bug in elm-connect: please report it, with the input.

-}
type Reason
    = Truncated
    | LengthOverrun
    | InvalidTag
    | InvalidWireType Int
    | MalformedVarint
    | IntOutOfRange
    | InvalidUtf8
    | Unlocated


{-| A description of an error, for a person reading a log, as
`Json.Decode.errorToString` gives one:

    Proto.Error.toString
        (Proto.Error.BadBinary
            { typeName = "notes.v1.Note"
            , reason = Proto.Error.InvalidUtf8
            , path = [ ( "notes.v1.Note", 3 ), ( "notes.v1.Revision", 1 ) ]
            , offset = 36
            }
        )
    --> "Not a notes.v1.Note in protobuf binary: a string is not UTF-8, at byte 36, in field 1 of notes.v1.Revision in field 3 of notes.v1.Note."

-}
toString : Error -> String
toString error =
    case error of
        BadBinary binary ->
            "Not a "
                ++ binary.typeName
                ++ " in protobuf binary: "
                ++ reasonText binary.reason
                ++ ", at byte "
                ++ String.fromInt binary.offset
                ++ pathText binary.path
                ++ "."

        BadJson jsonError ->
            Json.Decode.errorToString jsonError

        TypeMismatch { expected, actual } ->
            "An Any holding " ++ actual ++ " was unpacked as " ++ expected ++ "."

        UnregisteredType typeUrl ->
            "An Any holding " ++ typeUrl ++ " was converted through a registry that has no entry for its type."


{-| A description of an error that never quotes the value that failed: for
JSON, where the failure is and what was expected, as elm/json's path names
it; the rest as [`toString`](#toString) gives them, which quote no value.
For a log or a report that must not carry the data it was decoding:

    -- {"tokens": {"accessToken": 7}}, read as a message with a string there
    "at json.tokens.accessToken: Expecting a STRING"

A failure of the runtime's own decoders that names what it got (`Expecting
an integer, but got "x"`) is cut before what it got. A `oneOf` that failed
every way lists each way, joined with `; or`.

-}
toStringWithoutValues : Error -> String
toStringWithoutValues error =
    case error of
        BadJson jsonError ->
            jsonWithoutValues "json" jsonError

        _ ->
            toString error


jsonWithoutValues : String -> Json.Decode.Error -> String
jsonWithoutValues path error =
    case error of
        Json.Decode.Field name inner ->
            jsonWithoutValues (path ++ fieldAccess name) inner

        Json.Decode.Index index inner ->
            jsonWithoutValues (path ++ "[" ++ String.fromInt index ++ "]") inner

        Json.Decode.OneOf [] ->
            "at " ++ path ++ ": no way to decode it"

        Json.Decode.OneOf [ only ] ->
            jsonWithoutValues path only

        Json.Decode.OneOf ways ->
            ways
                |> List.map (jsonWithoutValues path)
                |> String.join "; or "

        Json.Decode.Failure text _ ->
            "at " ++ path ++ ": " ++ withoutGot text


{-| elm/json's way of writing a field in a path: `.name` for a name that is
a letter then letters, digits and underscores, `['name']` otherwise.
-}
fieldAccess : String -> String
fieldAccess name =
    case String.uncons name of
        Just ( first, rest ) ->
            if Char.isAlpha first && String.all (\c -> Char.isAlphaNum c || c == '_') rest then
                "." ++ name

            else
                "['" ++ name ++ "']"

        Nothing ->
            "['']"


{-| A failure's text without the value it says it got.
-}
withoutGot : String -> String
withoutGot text =
    case String.indexes " but got" text of
        at :: _ ->
            String.left at text
                |> (\kept ->
                        if String.endsWith "," kept then
                            String.dropRight 1 kept

                        else
                            kept
                   )

        [] ->
            text


reasonText : Reason -> String
reasonText reason =
    case reason of
        Truncated ->
            "the input ends in the middle of a field"

        LengthOverrun ->
            "a field runs past the end of the message, packed field or map entry it is in"

        InvalidTag ->
            "a field number is 0"

        InvalidWireType wire ->
            "a field has wire type " ++ String.fromInt wire ++ ", which proto3 does not use"

        MalformedVarint ->
            "a varint is longer than ten bytes"

        IntOutOfRange ->
            "a 64-bit integer is outside what an Int holds exactly"

        InvalidUtf8 ->
            "a string is not UTF-8"

        Unlocated ->
            "the decoder failed where it could not say why, a bug in elm-connect"


{-| The fields a failure is in, innermost first, as a reader follows them
down: `, in field 1 of b.B in field 3 of a.A`.
-}
pathText : List ( String, Int ) -> String
pathText path =
    case path of
        [] ->
            ""

        _ ->
            ", in "
                ++ (List.reverse path
                        |> List.map (\( name, number ) -> "field " ++ String.fromInt number ++ " of " ++ name)
                        |> String.join " in "
                   )
