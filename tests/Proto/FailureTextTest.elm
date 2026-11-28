module Proto.FailureTextTest exposing (suite)

{-| Every failure text the `Proto` JSON decoders write says what was expected
and never what was found; the rejected value is in elm/json's `Failure`
beside the text, where `Proto.Error.toString` prints it.
-}

import Expect
import Json.Decode exposing (Decoder)
import Proto.Error
import Proto.Json.Decode
import Proto.Registry
import Proto.WellKnown
import Test exposing (Test, describe, test)


{-| A failing input for one failure site: the decoder, the JSON, the text the
decoder writes, and the rejected value that text must leave out.
-}
type alias Row =
    { decoder : Decoder ()
    , json : String
    , text : String
    , rejected : String
    }


row : Decoder a -> String -> String -> String -> Row
row decoder json text rejected =
    { decoder = Json.Decode.map (\_ -> ()) decoder, json = json, text = text, rejected = rejected }


rows : List Row
rows =
    [ row (Proto.Json.Decode.enum "Status" 0 [ ( "OK", 0, 0 ) ]) "\"PAUSED\"" "Expecting a value of enum \"Status\"" "PAUSED"
    , row (Proto.Json.Decode.int64Dict Json.Decode.int) "{\"7\":1,\"007\":2}" "Expecting distinct map keys" "007"
    , row (Proto.Json.Decode.int32Dict Json.Decode.int) "{\"3000000000\":1}" "Expecting an int32 map key (-2147483648 to 2147483647)" "3000000000"
    , row (Proto.Json.Decode.int64Dict Json.Decode.int) "{\"abc\":1}" "Expecting an int64 map key (-9223372036854775808 to 9223372036854775807)" "abc"
    , row (Proto.Json.Decode.boolMap Json.Decode.int) "{\"True\":1}" "Expecting a bool map key (\"true\" or \"false\")" "True"
    , row Proto.Json.Decode.int32 "3000000000" "Expecting an int32 (-2147483648 to 2147483647)" "3000000000"
    , row Proto.Json.Decode.int32 "\"+5\"" "Expecting an integer" "+5"
    , row Proto.Json.Decode.int32 "1.5" "Expecting an integer" "1.5"
    , row Proto.Json.Decode.int64 "\"1.5e0\"" "Expecting an integer" "1.5e0"
    , row Proto.Json.Decode.int64 "\"9300000000000000000\"" "Expecting an int64 (-9223372036854775808 to 9223372036854775807)" "9300000000000000000"
    , row Proto.Json.Decode.int64 "\"0x1F\"" "Expecting a decimal integer" "0x1F"
    , row Proto.Json.Decode.int64AsInt "\"0x1F\"" "Expecting a decimal integer" "0x1F"
    , row Proto.Json.Decode.uint64AsInt "-3" "Expecting a uint64 (0 or more)" "-3"
    , row Proto.Json.Decode.int64AsInt "\"9007199254740992\"" "Expecting an integer from -9007199254740991 to 9007199254740991, the 64-bit integers an Elm Int holds exactly" "9007199254740992"
    , row Proto.Json.Decode.int64AsInt "\"1.5\"" "Expecting an integer" "1.5"
    , row Proto.Json.Decode.double "\"1.5x\"" "Expecting a number" "1.5x"
    , row Proto.Json.Decode.bytes "\"a\"" "Expecting base64 (standard or URL-safe, padding optional)" "\"a\""
    , row Proto.Json.Decode.bytesAsBytes "\"a\"" "Expecting base64 (standard or URL-safe, padding optional)" "\"a\""
    , row Proto.Json.Decode.timestamp "\"noon\"" "Expecting an RFC 3339 timestamp" "noon"
    , row Proto.Json.Decode.duration "\"soon\"" "Expecting a duration such as \"1.5s\"" "soon"
    , row Proto.Json.Decode.fieldMask "\"a_b\"" "Expecting a FieldMask of lowerCamelCase paths" "a_b"
    , row (Proto.Json.Decode.any Proto.Registry.empty) "{\"@type\":\"secret\"}" "Expecting an Any whose \"@type\" is a type URL, such as \"type.googleapis.com/notes.v1.Note\"" "secret"
    , row (Proto.Json.Decode.any Proto.Registry.empty) "{\"@type\":\"type.googleapis.com/secret.Thing\"}" "Expecting an Any of a type the registry has" "secret.Thing"
    , row (Proto.Json.Decode.any Proto.WellKnown.registry) "{\"@type\":\"type.googleapis.com/google.protobuf.Duration\",\"value\":\"secret\"}" "Expecting a duration such as \"1.5s\"" "secret"
    ]


{-| The text of the failure, wherever in the JSON it is.
-}
failureText : Json.Decode.Error -> String
failureText error =
    case error of
        Json.Decode.Field _ inner ->
            failureText inner

        Json.Decode.Index _ inner ->
            failureText inner

        Json.Decode.OneOf errors ->
            List.map failureText errors |> String.join " | "

        Json.Decode.Failure text _ ->
            text


suite : Test
suite =
    describe "failure texts"
        (List.indexedMap
            (\index r ->
                test (String.fromInt index ++ ": " ++ r.text) <|
                    \_ ->
                        case Json.Decode.decodeString r.decoder r.json of
                            Ok _ ->
                                Expect.fail ("decoded " ++ r.json)

                            Err error ->
                                ( failureText error
                                , String.contains r.rejected (failureText error)
                                , List.length (String.indexes r.rejected (Proto.Error.toString (Proto.Error.BadJson error)))
                                )
                                    |> Expect.equal ( r.text, False, 1 )
            )
            rows
        )
