module Snippets.UpdateMask exposing (changedPaths, updateMask, validMask)

{-| The README's "Update masks": a field mask from two values of a message,
and a check of a mask's paths, both by walking the message's descriptor.
-}

-- region update-mask

import Json.Decode
import Json.Encode exposing (Value)
import Proto.Field as Field exposing (Cardinality(..), Kind(..))
import Proto.Message as Message exposing (Message)
import Proto.Registry as Registry exposing (Registry)



-- region update-mask-use


{-| The `google.protobuf.FieldMask` of what changed from `before` to
`after`, for an update request such as `UpdateNoteRequest`.
-}
updateMask : Registry -> Message a -> a -> a -> List String
updateMask registry message before after =
    changedPaths registry
        (Message.toDescriptor message)
        (Message.encode message before)
        (Message.encode message after)



-- endregion update-mask-use


{-| The paths of the fields whose JSON differs, by proto name. A singular
message field set on both sides is walked into, its type found in the
registry, so its changed fields are named rather than all of it. Repeated
fields, maps, oneof members and the well-known types are leaves: a mask names
them whole.
-}
changedPaths : Registry -> Message.Descriptor -> Value -> Value -> List String
changedPaths registry descriptor before after =
    Message.fields descriptor
        |> List.concatMap
            (\field ->
                let
                    old =
                        at (Field.jsonName field) before

                    new =
                        at (Field.jsonName field) after
                in
                if same old new then
                    []

                else
                    case ( walkable registry field, old, new ) of
                        ( Just nested, Just oldValue, Just newValue ) ->
                            if isObject oldValue && isObject newValue then
                                changedPaths registry nested oldValue newValue
                                    |> List.map (\path -> Field.name field ++ "." ++ path)

                            else
                                [ Field.name field ]

                        _ ->
                            [ Field.name field ]
            )


{-| Whether every path of a mask names a field: each segment a field of the
message the segment before it names, and every segment but the last a
singular message field.
-}
validMask : Registry -> Message.Descriptor -> List String -> Bool
validMask registry descriptor paths =
    List.all (String.split "." >> validPath registry descriptor) paths


validPath : Registry -> Message.Descriptor -> List String -> Bool
validPath registry descriptor segments =
    case segments of
        [] ->
            False

        name :: rest ->
            case List.filter (\field -> Field.name field == name) (Message.fields descriptor) of
                [ field ] ->
                    case ( rest, walkable registry field ) of
                        ( [], _ ) ->
                            True

                        ( _, Just nested ) ->
                            validPath registry nested rest

                        ( _, Nothing ) ->
                            False

                _ ->
                    False


{-| The message a field holds one of, if a mask may name its fields: a
singular message field outside any oneof, of a type the registry has that is
not a well-known type (whose JSON is not an object of its fields).
-}
walkable : Registry -> Field.Descriptor -> Maybe Message.Descriptor
walkable registry field =
    case ( Field.cardinality field, Field.kind field, Field.oneof field ) of
        ( CardinalitySingular, KindMessage typeName, Nothing ) ->
            if String.startsWith "google.protobuf." typeName then
                Nothing

            else
                Registry.message typeName registry

        _ ->
            Nothing


at : String -> Value -> Maybe Value
at key json =
    Json.Decode.decodeValue (Json.Decode.field key Json.Decode.value) json
        |> Result.toMaybe


{-| Whether two pieces of JSON are the same. Generated encoders write a
message's keys in one order, so their text is enough.
-}
same : Maybe Value -> Maybe Value -> Bool
same old new =
    Maybe.map (Json.Encode.encode 0) old == Maybe.map (Json.Encode.encode 0) new


isObject : Value -> Bool
isObject json =
    case Json.Decode.decodeValue (Json.Decode.dict Json.Decode.value) json of
        Ok _ ->
            True

        Err _ ->
            False



-- endregion update-mask
