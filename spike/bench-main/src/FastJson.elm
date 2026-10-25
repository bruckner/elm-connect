module FastJson exposing (decodeListNotesResponse, decodeNote, decodeNoteMapN)

{-| An estimate, not a prototype: what the note decoders would cost if
generated code checked a message's JSON for being an object once, rather
than every field checking it again, as `Proto.Json.field` must today. The
results are those of `Notes.V1.decodeNote` on every input the bench gives
(a `null` or a missing key reads as the default, a key under both spellings
fails, a value that is not an object fails), but nothing here is tested
beyond that.
-}

import Dict
import Json.Decode as D exposing (Decoder)
import Notes.V1 exposing (ListNotesResponse, Note)
import Proto.Json


{-| Run `decoder` on an object, failing as `Proto.Json` does on anything
else; the fields inside need not check again.
-}
message : Decoder a -> Decoder a
message decoder =
    D.value
        |> D.andThen
            (\json ->
                if isObject json then
                    decoder

                else
                    D.fail "Expecting an OBJECT"
            )


isObject : D.Value -> Bool
isObject json =
    case D.decodeValue (D.field "hasOwnProperty" (D.succeed ())) json of
        Ok () ->
            case D.decodeValue (D.list (D.fail "")) json of
                Ok _ ->
                    False

                Err (D.Index _ _) ->
                    False

                Err _ ->
                    True

        Err _ ->
            False


probe : String -> D.Value -> Maybe D.Value
probe name json =
    case D.decodeValue (D.field name D.value) json of
        Ok raw ->
            Just raw

        Err _ ->
            Nothing


isNull : D.Value -> Bool
isNull raw =
    case D.decodeValue (D.null ()) raw of
        Ok () ->
            True

        Err _ ->
            False


{-| A field of an object `message` has checked: one probe, the null check
when found, then the field's decoder.
-}
at : String -> a -> Decoder a -> Decoder a
at name default decoder =
    D.value
        |> D.andThen
            (\json ->
                case probe name json of
                    Nothing ->
                        D.succeed default

                    Just raw ->
                        if isNull raw then
                            D.succeed default

                        else
                            D.field name decoder
            )


atEither : String -> String -> a -> Decoder a -> Decoder a
atEither jsonName protoName default decoder =
    D.value
        |> D.andThen
            (\json ->
                case ( probe jsonName json, probe protoName json ) of
                    ( Nothing, Nothing ) ->
                        D.succeed default

                    ( Just raw, Nothing ) ->
                        if isNull raw then
                            D.succeed default

                        else
                            D.field jsonName decoder

                    ( Nothing, Just raw ) ->
                        if isNull raw then
                            D.succeed default

                        else
                            D.field protoName decoder

                    ( Just _, Just _ ) ->
                        D.fail ("Expecting \"" ++ jsonName ++ "\" or \"" ++ protoName ++ "\", but got both")
            )


field : String -> a -> Decoder a -> Decoder (a -> b) -> Decoder b
field name default decoder =
    D.map2 (|>) (at name default decoder)


fieldEither : String -> String -> a -> Decoder a -> Decoder (a -> b) -> Decoder b
fieldEither jsonName protoName default decoder =
    D.map2 (|>) (atEither jsonName protoName default decoder)


decodeNote : Decoder Note
decodeNote =
    message
        (D.succeed Note
            |> field "name" "" D.string
            |> field "title" "" D.string
            |> field "body" "" D.string
            |> field "tags" [] (D.list D.string)
            |> field "visibility" Notes.V1.VisibilityUnspecified Notes.V1.decodeVisibility
            |> fieldEither "createTime" "create_time" Nothing (D.map Just Proto.Json.timestamp)
            |> fieldEither "updateTime" "update_time" Nothing (D.map Just Proto.Json.timestamp)
            |> field "ttl" Nothing (D.map Just Proto.Json.duration)
            |> field "metadata" Dict.empty (D.dict D.string)
            |> field "extra" Nothing (D.map Just Proto.Json.struct)
            |> Proto.Json.oneof Notes.V1.decodeNoteKind
            |> field "attachment" Nothing (D.map Just Proto.Json.any)
            |> field "revision" Nothing (D.map Just Proto.Json.int64)
        )


{-| The same fields read with `map8`/`map5` rather than a `|>` pipeline: one
decoder node per eight fields in place of one `map2` per field.
-}
decodeNoteMapN : Decoder Note
decodeNoteMapN =
    message
        (D.map2 (\f g -> g f)
            (D.map8 Note
                (at "name" "" D.string)
                (at "title" "" D.string)
                (at "body" "" D.string)
                (at "tags" [] (D.list D.string))
                (at "visibility" Notes.V1.VisibilityUnspecified Notes.V1.decodeVisibility)
                (atEither "createTime" "create_time" Nothing (D.map Just Proto.Json.timestamp))
                (atEither "updateTime" "update_time" Nothing (D.map Just Proto.Json.timestamp))
                (at "ttl" Nothing (D.map Just Proto.Json.duration))
            )
            (D.map5 (\metadata extra kind attachment revision f -> f metadata extra kind attachment revision)
                (at "metadata" Dict.empty (D.dict D.string))
                (at "extra" Nothing (D.map Just Proto.Json.struct))
                Notes.V1.decodeNoteKind
                (at "attachment" Nothing (D.map Just Proto.Json.any))
                (at "revision" Nothing (D.map Just Proto.Json.int64))
            )
        )


decodeListNotesResponse : Decoder ListNotesResponse
decodeListNotesResponse =
    message
        (D.succeed ListNotesResponse
            |> field "notes" [] (D.list decodeNote)
            |> fieldEither "nextPageToken" "next_page_token" "" D.string
        )
