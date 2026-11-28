module WrittenTextTest exposing (suite)

{-| The JSON text the notes example's generated encoders write, character for
character: fields in declaration order, then the oneof's member. The
expectations are the text the encoders wrote before they could refuse a
value, when every field was plain code.
-}

import Expect
import Json.Decode
import Json.Encode
import Notes.V1
import Proto.Error
import Proto.Json.Encode
import Proto.Registry
import Test exposing (Test, describe, test)


full : String
full =
    "{\"name\":\"notes/1\",\"title\":\"T\",\"body\":\"B\",\"tags\":[\"a\",\"b\"],\"visibility\":\"VISIBILITY_PUBLIC\",\"createTime\":\"2024-01-02T03:04:05Z\",\"updateTime\":\"2024-01-02T03:04:06.123456789Z\",\"ttl\":\"1.500s\",\"metadata\":{\"k\":\"v\",\"a\":\"b\"},\"extra\":{\"z\":1,\"a\":[true,null,\"s\",{\"n\":2.5}]},\"link\":\"https://x\",\"attachment\":{\"@type\":\"type.googleapis.com/notes.v1.GetNoteRequest\",\"name\":\"notes/2\"},\"revision\":\"7\"}"


fullNoAny : String
fullNoAny =
    "{\"name\":\"notes/1\",\"title\":\"T\",\"tags\":[\"a\"],\"createTime\":\"2024-01-02T03:04:05Z\",\"text\":\"hello\",\"extra\":{},\"revision\":\"0\"}"


{-| Decode `input` and write it again, as text.
-}
rewritten : (Proto.Registry.Registry -> Json.Decode.Decoder a) -> (a -> Proto.Json.Encode.Encoder Proto.Error.Error) -> String -> Result String String
rewritten decode encode input =
    Json.Decode.decodeString (decode Notes.V1.registry) input
        |> Result.mapError Json.Decode.errorToString
        |> Result.andThen (encode >> Proto.Json.Encode.encodeWith Notes.V1.registry >> Result.mapError Proto.Error.toString)
        |> Result.map (Json.Encode.encode 0)


{-| Decode `input` and write it again with the encoder that cannot refuse.
-}
rewrittenTotal : Json.Decode.Decoder a -> (a -> Proto.Json.Encode.Encoder Never) -> String -> Result String String
rewrittenTotal decode encode input =
    Json.Decode.decodeString decode input
        |> Result.mapError Json.Decode.errorToString
        |> Result.map (encode >> Proto.Json.Encode.encodeTotal >> Json.Encode.encode 0)


suite : Test
suite =
    describe "the text the notes encoders write keeps the field order"
        [ test "a note with every field" <|
            \_ -> rewritten Notes.V1.decodeNoteWith Notes.V1.encodeNote full |> Expect.equal (Ok "{\"name\":\"notes/1\",\"title\":\"T\",\"body\":\"B\",\"tags\":[\"a\",\"b\"],\"visibility\":\"VISIBILITY_PUBLIC\",\"createTime\":\"2024-01-02T03:04:05Z\",\"updateTime\":\"2024-01-02T03:04:06.123456789Z\",\"ttl\":\"1.500s\",\"metadata\":{\"a\":\"b\",\"k\":\"v\"},\"extra\":{\"a\":[true,null,\"s\",{\"n\":2.5}],\"z\":1},\"attachment\":{\"@type\":\"type.googleapis.com/notes.v1.GetNoteRequest\",\"name\":\"notes/2\"},\"revision\":\"7\",\"link\":\"https://x\"}")
        , test "a note with a oneof member before a later field" <|
            \_ -> rewritten Notes.V1.decodeNoteWith Notes.V1.encodeNote fullNoAny |> Expect.equal (Ok "{\"name\":\"notes/1\",\"title\":\"T\",\"tags\":[\"a\"],\"createTime\":\"2024-01-02T03:04:05Z\",\"extra\":{},\"revision\":\"0\",\"text\":\"hello\"}")
        , test "an empty note" <|
            \_ -> rewritten Notes.V1.decodeNoteWith Notes.V1.encodeNote "{}" |> Expect.equal (Ok "{}")
        , test "a list of notes" <|
            \_ ->
                rewritten Notes.V1.decodeListNotesResponseWith Notes.V1.encodeListNotesResponse ("{\"notes\":[" ++ full ++ "," ++ fullNoAny ++ ",{}],\"nextPageToken\":\"p\"}")
                    |> Expect.equal (Ok "{\"notes\":[{\"name\":\"notes/1\",\"title\":\"T\",\"body\":\"B\",\"tags\":[\"a\",\"b\"],\"visibility\":\"VISIBILITY_PUBLIC\",\"createTime\":\"2024-01-02T03:04:05Z\",\"updateTime\":\"2024-01-02T03:04:06.123456789Z\",\"ttl\":\"1.500s\",\"metadata\":{\"a\":\"b\",\"k\":\"v\"},\"extra\":{\"a\":[true,null,\"s\",{\"n\":2.5}],\"z\":1},\"attachment\":{\"@type\":\"type.googleapis.com/notes.v1.GetNoteRequest\",\"name\":\"notes/2\"},\"revision\":\"7\",\"link\":\"https://x\"},{\"name\":\"notes/1\",\"title\":\"T\",\"tags\":[\"a\"],\"createTime\":\"2024-01-02T03:04:05Z\",\"extra\":{},\"revision\":\"0\",\"text\":\"hello\"},{}],\"nextPageToken\":\"p\"}")
        , test "an update with a mask" <|
            \_ ->
                rewritten Notes.V1.decodeUpdateNoteRequestWith Notes.V1.encodeUpdateNoteRequest ("{\"note\":" ++ fullNoAny ++ ",\"updateMask\":\"title,createTime\"}")
                    |> Expect.equal (Ok "{\"note\":{\"name\":\"notes/1\",\"title\":\"T\",\"tags\":[\"a\"],\"createTime\":\"2024-01-02T03:04:05Z\",\"extra\":{},\"revision\":\"0\",\"text\":\"hello\"},\"updateMask\":\"title,createTime\"}")
        , test "a request that cannot refuse" <|
            \_ ->
                rewrittenTotal Notes.V1.decodeListNotesRequest Notes.V1.encodeListNotesRequest "{\"pageSize\":3,\"pageToken\":\"t\",\"filter\":\"f\",\"visibility\":\"VISIBILITY_PRIVATE\"}"
                    |> Expect.equal (Ok "{\"pageSize\":3,\"pageToken\":\"t\",\"filter\":\"f\",\"visibility\":\"VISIBILITY_PRIVATE\"}")
        ]
