module Proto.ErrorTest exposing (suite)

{-| `Proto.Error.toString`, and the one failure no input reaches: the two
binary readers disagreeing, which only a bug in them could cause.
-}

import Expect
import Json.Decode
import Proto.Binary as B
import Proto.Error as Error exposing (Error(..), Reason(..))
import Proto.Internal.Binary
import Test exposing (Test, describe, test)


suite : Test
suite =
    describe "Proto.Error"
        [ test "a binary failure names the message, the reason, the byte and the fields, innermost first" <|
            \_ ->
                Error.toString (BadBinary { typeName = "notes.v1.Note", reason = InvalidUtf8, path = [ ( "notes.v1.Note", 3 ), ( "notes.v1.Revision", 1 ) ], offset = 36 })
                    |> Expect.equal "Not a notes.v1.Note in protobuf binary: a string is not UTF-8, at byte 36, in field 1 of notes.v1.Revision in field 3 of notes.v1.Note."
        , test "a failure in no field leaves the fields out" <|
            \_ ->
                Error.toString (BadBinary { typeName = "a.B", reason = InvalidWireType 7, path = [], offset = 0 })
                    |> Expect.equal "Not a a.B in protobuf binary: a field has wire type 7, which proto3 does not use, at byte 0."
        , test "every reason has its own text" <|
            \_ ->
                [ Truncated, LengthOverrun, InvalidTag, InvalidWireType 3, MalformedVarint, IntOutOfRange, InvalidUtf8, Unlocated, MissingRequired 1 ]
                    |> List.map (\reason -> Error.toString (BadBinary { typeName = "a.B", reason = reason, path = [], offset = 0 }))
                    |> unique
                    |> List.length
                    |> Expect.equal 9
        , test "JSON is elm/json's text" <|
            \_ ->
                case Json.Decode.decodeString Json.Decode.int "true" of
                    Err problem ->
                        Error.toString (BadJson problem) |> Expect.equal (Json.Decode.errorToString problem)

                    Ok _ ->
                        Expect.fail "decoded"
        , test "a type mismatch and an unregistered type name both types" <|
            \_ ->
                ( Error.toString (TypeMismatch { expected = "a.B", actual = "c.D" })
                , Error.toString (UnregisteredType "type.googleapis.com/c.D")
                )
                    |> Expect.equal
                        ( "An Any holding c.D was unpacked as a.B."
                        , "An Any holding type.googleapis.com/c.D was converted through a registry that has no entry for its type."
                        )
        , test "binary that cannot reach the readers is Unlocated" <|
            \_ ->
                Proto.Internal.Binary.runBase64 (B.messageDecoder B.empty) "!"
                    |> Expect.equal (Err { typeName = "google.protobuf.Empty", reason = Unlocated, path = [], offset = 0 })
        ]


unique : List String -> List String
unique =
    List.foldr
        (\x acc ->
            if List.member x acc then
                acc

            else
                x :: acc
        )
        []
