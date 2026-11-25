module Snippets.Report exposing (decodeReport)

{-| docs/calling.md's report of a body that did not decode: where the failure
is and what was expected, never the value.
-}

-- region report

import Json.Decode
import Proto.Error
import Rpc
import Rpc.Error


decodeReport : Rpc.Error -> Maybe String
decodeReport error =
    case Rpc.Error.protoError error of
        Just (Proto.Error.BadJson problem) ->
            Just (located "json" problem)

        Just (Proto.Error.BadValue value) ->
            -- A request value with no JSON form: its path can hold a map's keys.
            Just ("no JSON form: " ++ value.typeName)

        Just other ->
            -- A binary report, a type URL or a type mismatch: no value.
            Just (Proto.Error.toString other)

        Nothing ->
            Nothing


located : String -> Json.Decode.Error -> String
located path problem =
    case problem of
        Json.Decode.Field name inner ->
            located (path ++ "." ++ name) inner

        Json.Decode.Index index inner ->
            located (path ++ "[" ++ String.fromInt index ++ "]") inner

        Json.Decode.OneOf ways ->
            String.join "; or " (List.map (located path) ways)

        Json.Decode.Failure text _ ->
            path ++ ": " ++ text



-- endregion report
