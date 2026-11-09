module Proto.RegistryTest exposing (suite)

import Bytes exposing (Bytes)
import Bytes.Decode
import Bytes.Encode
import Expect
import Json.Decode
import Json.Encode
import Proto.Registry as Registry exposing (Registry)
import Test exposing (Test, describe, test)


{-| A codec that writes a JSON string as its UTF-8 bytes, behind `prefix`.
-}
withString : String -> String -> Registry -> Registry
withString typeName prefix =
    Registry.withBinary typeName Json.Decode.string (\json -> Bytes.Encode.string (prefix ++ json))


text : Maybe Bytes -> Maybe String
text =
    Maybe.andThen (\bytes -> Bytes.Decode.decode (Bytes.Decode.string (Bytes.width bytes)) bytes)


suite : Test
suite =
    describe "Proto.Registry"
        [ test "a message's JSON as binary, by full name" <|
            \_ ->
                let
                    registry =
                        withString "notes.v1.Note" "" Registry.empty
                in
                ( Registry.toBinary "notes.v1.Note" (Json.Encode.string "hi") registry |> text
                , Registry.toBinary "notes.v1.Other" (Json.Encode.string "hi") registry |> text
                )
                    |> Expect.equal ( Just "hi", Nothing )
        , test "JSON that is not the message's has no binary" <|
            \_ ->
                withString "notes.v1.Note" "" Registry.empty
                    |> Registry.toBinary "notes.v1.Note" (Json.Encode.int 1)
                    |> Expect.equal Nothing
        , test "the empty registry has nothing" <|
            \_ ->
                Registry.toBinary "notes.v1.Note" (Json.Encode.string "hi") Registry.empty
                    |> Expect.equal Nothing
        , test "of two codecs for one name, the later is kept" <|
            \_ ->
                Registry.empty
                    |> withString "notes.v1.Note" "first:"
                    |> withString "notes.v1.Note" "second:"
                    |> Registry.toBinary "notes.v1.Note" (Json.Encode.string "hi")
                    |> text
                    |> Expect.equal (Just "second:hi")
        , test "a union keeps the left one's" <|
            \_ ->
                Registry.union
                    (withString "notes.v1.Note" "left:" Registry.empty)
                    (Registry.empty |> withString "notes.v1.Note" "right:" |> withString "notes.v1.Tag" "right:")
                    |> (\registry ->
                            ( Registry.toBinary "notes.v1.Note" (Json.Encode.string "hi") registry |> text
                            , Registry.toBinary "notes.v1.Tag" (Json.Encode.string "hi") registry |> text
                            )
                       )
                    |> Expect.equal ( Just "left:hi", Just "right:hi" )
        ]
