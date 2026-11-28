module Proto.Internal.FieldMask exposing (fromJsonPath, roundTrips, toText)

{-| A `google.protobuf.FieldMask`'s proto3 JSON text, which `Proto.Json.Encode`
writes, `Proto.Json.Decode` reads and `Proto.Route` prints into a path or
query.
-}


{-| The paths, written with proto field names (`"author.email_address"`):
each field name in lowerCamelCase, the paths joined by commas.
-}
toText : List String -> String
toText paths =
    paths
        |> List.map (mapSegments camelCase)
        |> String.join ","


{-| A path of the JSON text as proto field names.
-}
fromJsonPath : String -> String
fromJsonPath =
    mapSegments snakeCase


{-| Whether a path's lowerCamelCase form reads back as the path itself.
-}
roundTrips : String -> Bool
roundTrips path =
    List.all (\segment -> snakeCase (camelCase segment) == segment) (String.split "." path)


mapSegments : (String -> String) -> String -> String
mapSegments convert path =
    String.split "." path
        |> List.map convert
        |> String.join "."


camelCase : String -> String
camelCase name =
    case String.split "_" name of
        first :: rest ->
            first ++ String.concat (List.map capitalize rest)

        [] ->
            name


capitalize : String -> String
capitalize word =
    String.toUpper (String.left 1 word) ++ String.dropLeft 1 word


{-| Each ASCII capital of `name` as `_` and its small letter. Read from the
start: `String.toList` reads from the end, and on text starting with a low
surrogate without its high half never returns.
-}
snakeCase : String -> String
snakeCase name =
    String.foldl
        (\char written ->
            if Char.isUpper char then
                Char.toLower char :: '_' :: written

            else
                char :: written
        )
        []
        name
        |> List.reverse
        |> String.fromList
